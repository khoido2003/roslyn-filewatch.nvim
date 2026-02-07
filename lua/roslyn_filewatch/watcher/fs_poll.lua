---@class roslyn_filewatch.fs_poll
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, deps: roslyn_filewatch.FsPollDeps): uv_fs_poll_t|nil, string|nil

---@class roslyn_filewatch.FsPollDeps
---@field scan_tree fun(root: string, out_map: table<string, roslyn_filewatch.SnapshotEntry>)
---@field scan_tree_async fun(root: string, callback: fun(out_map: table<string, roslyn_filewatch.SnapshotEntry>), on_progress?: fun(scanned: number))|nil
---@field is_scanning fun(root: string): boolean|nil Check if async scan is in progress
---@field partial_scan fun(dirs: string[], existing_map: table<string, roslyn_filewatch.SnapshotEntry>, root: string)|nil
---@field partial_scan_async fun(dirs: string[], existing_map: table<string, roslyn_filewatch.SnapshotEntry>, root: string, callback: fun(updated_map: table<string, roslyn_filewatch.SnapshotEntry>))|nil Async version of partial_scan
---@field get_dirty_dirs fun(client_id: number): string[]|nil
---@field should_full_scan fun(client_id: number): boolean|nil
---@field identity_from_stat fun(st: roslyn_filewatch.SnapshotEntry|nil): string|nil
---@field same_file_info fun(a: roslyn_filewatch.SnapshotEntry|nil, b: roslyn_filewatch.SnapshotEntry|nil): boolean
---@field queue_events fun(client_id: number, evs: roslyn_filewatch.FileChange[])
---@field notify fun(msg: string, level?: number)
---@field notify_roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])
---@field close_deleted_buffers? fun(path: string) -- DEPRECATED: no longer used
---@field restart_watcher fun(reason?: string, delay_ms?: number, disable_fs_event?: boolean)
---@field last_events table<number, number>
---@field poll_interval number
---@field poller_restart_threshold number
---@field activity_quiet_period number|nil Seconds of quiet before allowing full scan (default 5)
---@field check_sln_changed fun(client_id: number, root: string): boolean|nil Check if solution file changed since last poll
---@field on_sln_changed fun(client_id: number, sln_path: string)|nil Called when solution file change is detected

local uv = vim.uv or vim.loop

-- Lazy load regeneration detector to avoid circular dependencies
local regen_detector = nil
local function get_regen_detector()
  if regen_detector == nil then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.regen_detector")
    if ok then
      regen_detector = mod
    else
      regen_detector = false -- Mark as failed to avoid repeated attempts
    end
  end
  return regen_detector or nil
end

local M = {}

--- Per-client trailing timer tracking for proper cleanup
---@type table<number, uv_timer_t>
local trailing_timers = {}

--- Safely stop and close a timer
---@param timer uv_timer_t|nil
local function safe_close_timer(timer)
  if not timer then
    return
  end
  pcall(function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end)
end

--- Stop and clean up trailing timer for a client
---@param client_id number
function M.stop(client_id)
  local timer = trailing_timers[client_id]
  if timer then
    safe_close_timer(timer)
    trailing_timers[client_id] = nil
  end
end

--- Start a fs_poll watcher for `client` at `root`.
---@param client vim.lsp.Client LSP client
---@param root string Root directory path
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Shared snapshots table
---@param deps roslyn_filewatch.FsPollDeps Dependencies
---@return uv_fs_poll_t|nil poller The poll handle, or nil on error
---@return string|nil error Error message if failed
function M.start(client, root, snapshots, deps)
  if not deps then
    return nil, "missing deps"
  end
  if not deps.scan_tree then
    return nil, "missing scan_tree"
  end

  local poll_interval = deps.poll_interval or 3000
  local poller_restart_threshold = deps.poller_restart_threshold or 2

  local poller = uv.new_fs_poll()
  if not poller then
    return nil, "failed to create fs_poll"
  end

  -- Timer for trailing check (throttling safety)
  -- Clean up any existing timer for this client first
  M.stop(client.id)
  local trailing_timer = uv.new_timer()
  trailing_timers[client.id] = trailing_timer

  local ok, start_err = pcall(function()
    poller:start(root, poll_interval, function(errp, prev, curr)
      if errp then
        if deps.notify then
          pcall(deps.notify, "Poller error: " .. tostring(errp), vim.log.levels.ERROR)
        end
        return
      end

      -- Detect root metadata changes
      if
        prev
        and curr
        and (prev.mtime and curr.mtime)
        and (prev.mtime.sec ~= curr.mtime.sec or prev.mtime.nsec ~= curr.mtime.nsec)
      then
        if deps.notify then
          pcall(deps.notify, "Poller detected root metadata change; restarting watcher", vim.log.levels.DEBUG)
        end
        if deps.restart_watcher then
          pcall(deps.restart_watcher, "root_metadata_change")
        end
        return
      end

      -- Store last_event BEFORE updating it, so threshold comparison works
      local last_event_time = (deps.last_events and deps.last_events[client.id]) or 0

      -- ============================================
      -- ACTIVITY-BASED THROTTLING
      -- Skip expensive scans during heavy file activity
      -- Unity regeneration can last 5-30 seconds, so we need
      -- a longer quiet period before triggering scans
      -- ============================================
      local current_time = os.time()
      local time_since_last_event = current_time - last_event_time
      local activity_quiet_period = deps.activity_quiet_period or 5 -- Default 5 seconds

      -- Also skip if an async scan is already in progress
      if deps.is_scanning and deps.is_scanning(root) then
        return
      end

      -- Skip if currently in regeneration mode (Unity/Godot regenerating files)
      local regen = get_regen_detector()
      if regen and regen.is_regenerating(client.id) then
        if deps.notify then
          pcall(deps.notify, "Skipping poll - regeneration in progress", vim.log.levels.DEBUG)
        end
        return
      end

      -- Forward declaration for use in trailing_timer callback
      local perform_scan

      -- If we just processed events recently, skip this cycle to let things settle
      -- This is critical for Unity regeneration which produces many events
      if time_since_last_event < activity_quiet_period then
        -- High activity detected - skip this poll cycle
        -- Schedule a trailing check to ensure we don't miss the final state
        if trailing_timer and not trailing_timer:is_active() then
          local trailing_ms = math.ceil((activity_quiet_period - time_since_last_event) * 1000) + 200
          trailing_timer:start(trailing_ms, 0, function()
            -- perform_scan is now available via forward declaration
            if perform_scan then
              vim.schedule(perform_scan)
            end
          end)
        end
        return
      end

      -- Stop trailing timer if running (we are running a normal scan now)
      if trailing_timer and trailing_timer:is_active() then
        trailing_timer:stop()
      end

      perform_scan = function()
        -- Incremental scanning: check if we need full scan or partial scan
        local do_full_scan = true
        local dirty_dir_list = nil
        local sln_changed = false

        -- Check if solution file (.slnx/.sln/.slnf) has changed
        -- This triggers a full rescan when Unity adds new projects to the solution
        if deps.check_sln_changed then
          sln_changed = deps.check_sln_changed(client.id, root) or false
          if sln_changed then
            if deps.notify then
              pcall(deps.notify, "Solution file changed, triggering full rescan", vim.log.levels.DEBUG)
            end
            -- Force full scan - clear snapshot to ensure all new project directories get scanned
            do_full_scan = true
            snapshots[client.id] = {}
            if deps.on_sln_changed then
              pcall(deps.on_sln_changed, client.id, root)
            end
          end
        end

        -- Only check incremental scan optimization if solution didn't change
        -- Solution change always forces a full rescan
        if not sln_changed and deps.should_full_scan and deps.get_dirty_dirs and deps.partial_scan then
          do_full_scan = deps.should_full_scan(client.id)

          if not do_full_scan then
            dirty_dir_list = deps.get_dirty_dirs(client.id)
            if not dirty_dir_list or #dirty_dir_list == 0 then
              -- No dirty dirs and no need for full scan - skip this poll cycle
              return
            end
          end
        end

        ---@type table<string, roslyn_filewatch.SnapshotEntry>
        local new_map
        local old_map = snapshots[client.id] or {}

        if do_full_scan then
          -- Full scan: prefer async scanning if available (prevents UI freeze)
          if deps.scan_tree_async then
            -- Use async scanning - callback will process results
            deps.scan_tree_async(root, function(async_new_map)
              -- Process the async scan results
              local async_old_map = snapshots[client.id] or {}
              local async_evs = {}
              local async_rename_pairs = {}

              -- Build old identity map
              local async_old_id_map = {}
              for path, entry in pairs(async_old_map) do
                local id = deps.identity_from_stat and deps.identity_from_stat(entry) or nil
                if id then
                  async_old_id_map[id] = path
                end
              end

              local async_processed_old = {}
              local is_initial_scan = next(async_old_map) == nil

              if is_initial_scan then
                if deps.notify then
                  pcall(
                    deps.notify,
                    "Initial scan complete: " .. vim.tbl_count(async_new_map) .. " files",
                    vim.log.levels.DEBUG
                  )
                end
                -- Optimization: On initial scan, just populate the snapshot.
                -- Do NOT send thousands of "Created" events, as Roslyn loads the project structure itself.
                -- sending 30k+ events causes massive lag and RPC timeout.
                snapshots[client.id] = async_new_map
                if deps.last_events then
                  deps.last_events[client.id] = os.time()
                end
                return
              end

              -- Detect creates / renames / changes
              for path, mt in pairs(async_new_map) do
                local old_mt = async_old_map[path]
                if not old_mt then
                  local id = deps.identity_from_stat and deps.identity_from_stat(mt) or nil
                  local oldpath = id and async_old_id_map[id]
                  if oldpath then
                    table.insert(async_rename_pairs, { old = oldpath, ["new"] = path })
                    async_processed_old[oldpath] = true
                    async_old_id_map[id] = nil
                  else
                    table.insert(async_evs, { uri = vim.uri_from_fname(path), type = 1 })
                  end
                elseif not (deps.same_file_info and deps.same_file_info(async_old_map[path], async_new_map[path])) then
                  table.insert(async_evs, { uri = vim.uri_from_fname(path), type = 2 })
                end
                async_processed_old[path] = true
              end

              -- Remaining old_map entries are deletes
              for path, _ in pairs(async_old_map) do
                if not async_processed_old[path] and async_new_map[path] == nil then
                  table.insert(async_evs, { uri = vim.uri_from_fname(path), type = 3 })
                end
              end

              -- Send renames
              if #async_rename_pairs > 0 then
                if deps.notify then
                  pcall(
                    deps.notify,
                    "Async scan detected " .. #async_rename_pairs .. " rename(s)",
                    vim.log.levels.DEBUG
                  )
                end
                if deps.notify_roslyn_renames then
                  pcall(deps.notify_roslyn_renames, async_rename_pairs)
                end
              end

              -- Update snapshot and queue events
              snapshots[client.id] = async_new_map
              if #async_evs > 0 and deps.queue_events then
                pcall(deps.queue_events, client.id, async_evs)
              end

              -- Update last event time
              if deps.last_events then
                deps.last_events[client.id] = os.time()
              end
            end)
            -- Return early - async callback will handle the rest
            return
          end

          -- Fallback: synchronous scan (if async not available)
          new_map = {}
          local scan_ok, scan_err = pcall(function()
            deps.scan_tree(root, new_map)
          end)
          if not scan_ok then
            if deps.notify then
              pcall(deps.notify, "Poller scan_tree failed: " .. tostring(scan_err), vim.log.levels.WARN)
            end
            return
          end
        else
          -- Partial scan: prefer async if available (prevents UI freeze)
          if deps.partial_scan_async then
            local partial_new_map = {}
            for k, v in pairs(old_map) do
              partial_new_map[k] = v
            end
            deps.partial_scan_async(dirty_dir_list, partial_new_map, root, function(async_partial_map)
              local async_old_map = snapshots[client.id] or {}
              local async_evs = {}
              local async_old_id_map = {}
              for path, entry in pairs(async_old_map) do
                local id = deps.identity_from_stat and deps.identity_from_stat(entry) or nil
                if id then
                  async_old_id_map[id] = path
                end
              end
              local async_processed_old = {}
              for path, mt in pairs(async_partial_map) do
                local old_mt = async_old_map[path]
                if not old_mt then
                  local id = deps.identity_from_stat and deps.identity_from_stat(mt) or nil
                  local oldpath = id and async_old_id_map[id]
                  if oldpath then
                    async_processed_old[oldpath] = true
                    async_old_id_map[id] = nil
                  else
                    table.insert(async_evs, { uri = vim.uri_from_fname(path), type = 1 })
                  end
                elseif
                  not (deps.same_file_info and deps.same_file_info(async_old_map[path], async_partial_map[path]))
                then
                  table.insert(async_evs, { uri = vim.uri_from_fname(path), type = 2 })
                end
                async_processed_old[path] = true
              end
              for path, _ in pairs(async_old_map) do
                if not async_processed_old[path] and async_partial_map[path] == nil then
                  for _, dirty_dir in ipairs(dirty_dir_list) do
                    if path:find(dirty_dir, 1, true) == 1 then
                      table.insert(async_evs, { uri = vim.uri_from_fname(path), type = 3 })
                      break
                    end
                  end
                end
              end
              snapshots[client.id] = async_partial_map
              if #async_evs > 0 and deps.queue_events then
                pcall(deps.queue_events, client.id, async_evs)
              end
              if deps.last_events then
                deps.last_events[client.id] = os.time()
              end
            end)
            return
          end
          -- Fallback: synchronous partial scan
          new_map = {}
          for k, v in pairs(old_map) do
            new_map[k] = v
          end
          local scan_ok, scan_err = pcall(function()
            deps.partial_scan(dirty_dir_list, new_map, root)
          end)
          if not scan_ok then
            if deps.notify then
              pcall(deps.notify, "Poller partial_scan failed: " .. tostring(scan_err), vim.log.levels.WARN)
            end
            -- Fallback: request full scan next time
            return
          end
        end

        ---@type roslyn_filewatch.FileChange[]
        local evs = {}
        local saw_delete = false
        ---@type roslyn_filewatch.RenameEntry[]
        local rename_pairs = {}

        -- Build old identity map
        ---@type table<string, string>
        local old_id_map = {}
        for path, entry in pairs(old_map) do
          local id = deps.identity_from_stat and deps.identity_from_stat(entry) or nil
          if id then
            old_id_map[id] = path
          end
        end

        -- Track processed old paths to avoid double-processing
        ---@type table<string, boolean>
        local processed_old = {}

        local is_initial_scan = next(old_map) == nil
        if is_initial_scan then
          if deps.notify then
            pcall(
              deps.notify,
              "Initial scan (sync) complete: " .. vim.tbl_count(new_map) .. " files",
              vim.log.levels.DEBUG
            )
          end
          snapshots[client.id] = new_map
          if deps.last_events then
            deps.last_events[client.id] = os.time()
          end
          return
        end

        -- Detect creates / renames / changes
        for path, mt in pairs(new_map) do
          local old_mt = old_map[path]
          if not old_mt then
            local id = deps.identity_from_stat and deps.identity_from_stat(mt) or nil
            local oldpath = id and old_id_map[id]
            if oldpath then
              table.insert(rename_pairs, { old = oldpath, ["new"] = path })
              processed_old[oldpath] = true
              old_id_map[id] = nil
            else
              table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
            end
          elseif not (deps.same_file_info and deps.same_file_info(old_map[path], new_map[path])) then
            table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
          end
          processed_old[path] = true
        end

        -- Remaining old_map entries are deletes
        for path, _ in pairs(old_map) do
          if not processed_old[path] and new_map[path] == nil then
            saw_delete = true

            table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
          end
        end

        -- Send renames
        if #rename_pairs > 0 then
          if deps.notify then
            pcall(deps.notify, "Poller detected " .. #rename_pairs .. " rename(s)", vim.log.levels.DEBUG)
          end
          if deps.notify_roslyn_renames then
            pcall(deps.notify_roslyn_renames, rename_pairs)
          end
        end

        if #evs > 0 then
          -- Update snapshot, queue events
          snapshots[client.id] = new_map
          if deps.queue_events then
            pcall(deps.queue_events, client.id, evs)
          end

          -- Now update last_events AFTER processing
          if deps.last_events then
            deps.last_events[client.id] = os.time()
          end
        else
          -- No diffs -> update snapshot
          snapshots[client.id] = new_map
        end
      end
      perform_scan()
    end)
  end)

  if not ok then
    -- Close poller and trailing timer if start failed
    pcall(function()
      if poller and poller.close then
        poller:close()
      end
    end)
    M.stop(client.id)
    return nil, start_err
  end

  return poller, nil
end

return M
