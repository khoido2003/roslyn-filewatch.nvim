---@class roslyn_filewatch.fs_poll
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table, deps: table): uv_fs_poll_t|nil, string|nil
---@field stop fun(client_id: number)

local uv = vim.uv or vim.loop

local M = {}

local regen_detector = nil
local function get_regen_detector()
  if regen_detector == nil then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.regen_detector")
    regen_detector = ok and mod or false
  end
  return regen_detector or nil
end

---@type table<number, uv_timer_t>
local trailing_timers = {}

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

function M.stop(client_id)
  local timer = trailing_timers[client_id]
  if timer then
    safe_close_timer(timer)
    trailing_timers[client_id] = nil
  end
end

function M.start(client, root, snapshots, deps)
  if not deps or not deps.scan_tree then
    return nil, "missing deps"
  end

  local poll_interval = deps.poll_interval or 3000

  local poller = uv.new_fs_poll()
  if not poller then
    return nil, "failed to create fs_poll"
  end

  M.stop(client.id)
  local trailing_timer = uv.new_timer()
  trailing_timers[client.id] = trailing_timer

  local function process_scan_results(new_map, old_map)
    local evs = {}
    local rename_pairs = {}
    local old_id_map = {}

    for path, entry in pairs(old_map) do
      local id = deps.identity_from_stat and deps.identity_from_stat(entry) or nil
      if id then
        old_id_map[id] = path
      end
    end

    local processed_old = {}
    local is_initial = next(old_map) == nil

    if is_initial then
      if deps.notify then
        pcall(deps.notify, "Initial scan: " .. vim.tbl_count(new_map) .. " files", vim.log.levels.DEBUG)
      end
      snapshots[client.id] = new_map
      if deps.last_events then
        deps.last_events[client.id] = os.time()
      end
      return
    end

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

    for path in pairs(old_map) do
      if not processed_old[path] and new_map[path] == nil then
        table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
      end
    end

    if #rename_pairs > 0 and deps.notify_roslyn_renames then
      pcall(deps.notify_roslyn_renames, rename_pairs)
    end

    snapshots[client.id] = new_map

    if #evs > 0 and deps.queue_events then
      pcall(deps.queue_events, client.id, evs)
    end

    if deps.last_events then
      deps.last_events[client.id] = os.time()
    end
  end

  local ok, start_err = pcall(function()
    poller:start(root, poll_interval, function(errp, prev, curr)
      if errp then
        if deps.notify then
          pcall(deps.notify, "Poller error: " .. tostring(errp), vim.log.levels.ERROR)
        end
        return
      end

      if prev and curr and prev.mtime and curr.mtime then
        if prev.mtime.sec ~= curr.mtime.sec or prev.mtime.nsec ~= curr.mtime.nsec then
          if deps.restart_watcher then
            pcall(deps.restart_watcher, "root_metadata_change")
          end
          return
        end
      end

      local last_event_time = (deps.last_events and deps.last_events[client.id]) or 0
      local current_time = os.time()
      local time_since_last = current_time - last_event_time
      local quiet_period = deps.activity_quiet_period or 5

      if deps.is_scanning and deps.is_scanning(root) then
        return
      end

      local regen = get_regen_detector()
      if regen and regen.is_regenerating(client.id) then
        return
      end

      local perform_scan

      if time_since_last < quiet_period then
        if trailing_timer and not trailing_timer:is_active() then
          local delay = math.ceil((quiet_period - time_since_last) * 1000) + 200
          trailing_timer:start(delay, 0, function()
            if perform_scan then
              vim.schedule(perform_scan)
            end
          end)
        end
        return
      end

      if trailing_timer and trailing_timer:is_active() then
        trailing_timer:stop()
      end

      perform_scan = function()
        local do_full_scan = true
        local dirty_dirs = nil

        if deps.check_sln_changed and deps.check_sln_changed(client.id, root) then
          snapshots[client.id] = {}
          if deps.on_sln_changed then
            pcall(deps.on_sln_changed, client.id, root)
          end
        elseif deps.should_full_scan and deps.get_dirty_dirs and deps.partial_scan then
          do_full_scan = deps.should_full_scan(client.id)
          if not do_full_scan then
            dirty_dirs = deps.get_dirty_dirs(client.id)
            if not dirty_dirs or #dirty_dirs == 0 then
              return
            end
          end
        end

        local old_map = snapshots[client.id] or {}

        if do_full_scan then
          if deps.scan_tree_async then
            deps.scan_tree_async(root, function(new_map)
              process_scan_results(new_map, snapshots[client.id] or {})
            end)
            return
          end

          local new_map = {}
          local scan_ok = pcall(deps.scan_tree, root, new_map)
          if scan_ok then
            process_scan_results(new_map, old_map)
          end
        else
          if deps.partial_scan_async then
            local base_map = {}
            for k, v in pairs(old_map) do
              base_map[k] = v
            end
            deps.partial_scan_async(dirty_dirs, base_map, root, function(new_map)
              local async_old = snapshots[client.id] or {}
              local evs = {}

              for path, mt in pairs(new_map) do
                local old_mt = async_old[path]
                if not old_mt then
                  table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
                elseif not (deps.same_file_info and deps.same_file_info(old_mt, mt)) then
                  table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
                end
              end

              for path in pairs(async_old) do
                if not new_map[path] then
                  for _, dir in ipairs(dirty_dirs) do
                    if path:find(dir, 1, true) == 1 then
                      table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
                      break
                    end
                  end
                end
              end

              snapshots[client.id] = new_map
              if #evs > 0 and deps.queue_events then
                pcall(deps.queue_events, client.id, evs)
              end
              if deps.last_events then
                deps.last_events[client.id] = os.time()
              end
            end)
            return
          end

          local new_map = {}
          for k, v in pairs(old_map) do
            new_map[k] = v
          end
          local scan_ok = pcall(deps.partial_scan, dirty_dirs, new_map, root)
          if scan_ok then
            process_scan_results(new_map, old_map)
          end
        end
      end

      perform_scan()
    end)
  end)

  if not ok then
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
