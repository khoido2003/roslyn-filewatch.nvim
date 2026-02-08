---@class roslyn_filewatch.watcher
---@field start fun(client: vim.lsp.Client)
---@field stop fun(client: vim.lsp.Client)

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")
local notify_mod = require("roslyn_filewatch.watcher.notify")
local snapshot_mod = require("roslyn_filewatch.watcher.snapshot")
local rename_mod = require("roslyn_filewatch.watcher.rename")
local fs_event_mod = require("roslyn_filewatch.watcher.fs_event")
local fs_poll_mod = require("roslyn_filewatch.watcher.fs_poll")
local watchdog_mod = require("roslyn_filewatch.watcher.watchdog")
local autocmds_mod = require("roslyn_filewatch.watcher.autocmds")
local restore_mod = require("roslyn_filewatch.restore")

local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat
local same_file_info = utils.same_file_info
local normalize_path = utils.normalize_path
local to_roslyn_path = utils.to_roslyn_path
local safe_close_handle = utils.safe_close_handle
local request_diagnostics_refresh = utils.request_diagnostics_refresh
local notify_project_open = utils.notify_project_open
local scan_tree = snapshot_mod.scan_tree

local notify = notify_mod.user
local notify_roslyn = notify_mod.roslyn_changes
local notify_roslyn_renames = notify_mod.roslyn_renames

local M = {}

local DIRTY_DIRS_THRESHOLD = 10

---@class ClientState
---@field watcher uv_fs_event_t|nil
---@field poller uv_fs_poll_t|nil
---@field watchdog uv_timer_t|nil
---@field sln_poll_timer uv_timer_t|nil
---@field batch_queue table|nil
---@field snapshot table<string, any>
---@field last_event number
---@field restart_scheduled boolean
---@field restart_backoff_until number
---@field fs_event_disabled_until number
---@field dirty_dirs table<string, boolean>
---@field needs_full_scan boolean
---@field sln_info table|nil
---@field csproj_reload_pending table|nil
---@field root string|nil
---@field autocmd_ids number[]|nil
---@field recovery_consecutive_failures number
---@field recovery_current_backoff number

---@type table<number, ClientState>
local client_states = {}

local function get_client_state(client_id)
  if not client_states[client_id] then
    client_states[client_id] = {
      watcher = nil,
      poller = nil,
      watchdog = nil,
      sln_poll_timer = nil,
      batch_queue = nil,
      snapshot = {},
      last_event = 0,
      restart_scheduled = false,
      restart_backoff_until = 0,
      fs_event_disabled_until = 0,
      dirty_dirs = {},
      needs_full_scan = false,
      sln_info = nil,
      csproj_reload_pending = nil,
      autocmd_ids = nil,
      root = nil,
      recovery_consecutive_failures = 0,
      recovery_current_backoff = config.options.recovery_initial_delay_ms or 300,
    }
  end
  return client_states[client_id]
end

local diagnostics_mod = nil
local function get_diagnostics_mod()
  if not diagnostics_mod then
    local ok, mod = pcall(require, "roslyn_filewatch.diagnostics")
    if ok then
      diagnostics_mod = mod
    end
  end
  return diagnostics_mod
end

pcall(function()
  local status_mod = require("roslyn_filewatch.status")
  if status_mod and status_mod.register_refs then
    local watchers_proxy = setmetatable({}, {
      __index = function(_, k)
        return client_states[k] and client_states[k].watcher
      end,
      __pairs = function()
        local result = {}
        for k, v in pairs(client_states) do
          if v.watcher then
            result[k] = v.watcher
          end
        end
        return pairs(result)
      end,
    })
    local pollers_proxy = setmetatable({}, {
      __index = function(_, k)
        return client_states[k] and client_states[k].poller
      end,
    })
    local watchdogs_proxy = setmetatable({}, {
      __index = function(_, k)
        return client_states[k] and client_states[k].watchdog
      end,
    })
    local snapshots_proxy = setmetatable({}, {
      __index = function(_, k)
        return client_states[k] and client_states[k].snapshot
      end,
      __newindex = function(_, k, v)
        if client_states[k] then
          client_states[k].snapshot = v
        end
      end,
    })
    local last_events_proxy = setmetatable({}, {
      __index = function(_, k)
        return client_states[k] and client_states[k].last_event
      end,
      __newindex = function(_, k, v)
        if client_states[k] then
          client_states[k].last_event = v
        end
      end,
    })
    local dirty_dirs_proxy = setmetatable({}, {
      __index = function(_, k)
        return client_states[k] and client_states[k].dirty_dirs
      end,
    })

    local sln_info_proxy = setmetatable({}, {
      __index = function(_, k)
        return client_states[k] and client_states[k].sln_info
      end,
    })

    status_mod.register_refs({
      watchers = watchers_proxy,
      pollers = pollers_proxy,
      watchdogs = watchdogs_proxy,
      snapshots = snapshots_proxy,
      last_events = last_events_proxy,
      sln_infos = sln_info_proxy,
      dirty_dirs = dirty_dirs_proxy,
    })
  end
end)

local function scan_csproj_async(root, callback)
  root = normalize_path(root)
  local results = {}
  local pending_dirs = 0
  local scan_complete = false

  local ignore_dirs = config.options.ignore_dirs or {}
  local ignore_set = {}
  for _, d in ipairs(ignore_dirs) do
    ignore_set[d:lower()] = true
  end

  local function finish_scan()
    if scan_complete then
      return
    end
    scan_complete = true
    vim.schedule(function()
      callback(results)
    end)
  end

  local function scan_dir_async(dir)
    pending_dirs = pending_dirs + 1

    uv.fs_scandir(dir, function(err, scanner)
      if err or not scanner then
        pending_dirs = pending_dirs - 1
        if pending_dirs == 0 then
          finish_scan()
        end
        return
      end

      local subdirs = {}
      local csproj_paths = {}

      while true do
        local name, typ = uv.fs_scandir_next(scanner)
        if not name then
          break
        end
        local fullpath = normalize_path(dir .. "/" .. name)
        if typ == "directory" then
          if not ignore_set[name:lower()] then
            table.insert(subdirs, fullpath)
          end
        elseif typ == "file" then
          if name:match("%.csproj$") or name:match("%.vbproj$") or name:match("%.fsproj$") then
            table.insert(csproj_paths, fullpath)
          end
        end
      end

      for _, csproj_path in ipairs(csproj_paths) do
        pending_dirs = pending_dirs + 1
        uv.fs_stat(csproj_path, function(stat_err, stat)
          results[csproj_path] = (not stat_err and stat) and stat.mtime.sec or 0
          pending_dirs = pending_dirs - 1
          if pending_dirs == 0 then
            finish_scan()
          end
        end)
      end

      for _, subdir in ipairs(subdirs) do
        vim.defer_fn(function()
          scan_dir_async(subdir)
        end, 0)
      end

      pending_dirs = pending_dirs - 1
      if pending_dirs == 0 then
        finish_scan()
      end
    end)
  end

  scan_dir_async(root)
end

local function scan_projects_from_sln_async(project_dirs, callback)
  local results = {}
  local pending = 0
  local finished = false

  local function finish()
    if finished then
      return
    end
    finished = true
    vim.schedule(function()
      callback(results)
    end)
  end

  if not project_dirs or #project_dirs == 0 then
    finish()
    return
  end

  for _, dir in ipairs(project_dirs) do
    pending = pending + 1
    uv.fs_scandir(dir, function(err, scanner)
      if err or not scanner then
        pending = pending - 1
        if pending == 0 then
          finish()
        end
        return
      end

      local csproj_found = {}
      while true do
        local name, typ = uv.fs_scandir_next(scanner)
        if not name then
          break
        end
        if name:match("%.csproj$") or name:match("%.vbproj$") or name:match("%.fsproj$") then
          table.insert(csproj_found, normalize_path(dir .. "/" .. name))
        end
      end

      for _, p in ipairs(csproj_found) do
        pending = pending + 1
        uv.fs_stat(p, function(stat_err, stat)
          results[p] = (not stat_err and stat) and stat.mtime.sec or 0
          pending = pending - 1
          if pending == 0 then
            finish()
          end
        end)
      end

      pending = pending - 1
      if pending == 0 then
        finish()
      end
    end)
  end
end

local function mark_dirty_dir(client_id, path)
  if not path or path == "" then
    return
  end
  local state = get_client_state(client_id)
  local normalized = normalize_path(path)
  local parent = normalized:match("^(.+)/[^/]+$")
  state.dirty_dirs[parent or normalized] = true
end

local function get_and_clear_dirty_dirs(client_id)
  local state = get_client_state(client_id)
  local dirs = {}
  for dir in pairs(state.dirty_dirs) do
    table.insert(dirs, dir)
  end
  state.dirty_dirs = {}
  return dirs
end

local function should_full_scan(client_id)
  local state = get_client_state(client_id)
  if state.needs_full_scan then
    state.needs_full_scan = false
    return true
  end
  local count = 0
  for _ in pairs(state.dirty_dirs) do
    count = count + 1
    if count > DIRTY_DIRS_THRESHOLD then
      return true
    end
  end
  return false
end

local function collect_roslyn_project_paths(sln_info)
  if not sln_info or not sln_info.csproj_files then
    return {}
  end
  local paths = {}
  for csproj_path in pairs(sln_info.csproj_files) do
    table.insert(paths, to_roslyn_path(csproj_path))
  end
  return paths
end

local function send_csproj_change_events(project_paths)
  if #project_paths == 0 then
    return
  end
  local events = {}
  for _, path in ipairs(project_paths) do
    table.insert(events, { uri = vim.uri_from_fname(path), type = 2 })
  end
  pcall(notify_roslyn, events)
  notify("[CSPROJ] Sent csproj change events (" .. #events .. " file(s))", vim.log.levels.DEBUG)
end

local function handle_csproj_reload(client, sln_info)
  local state = get_client_state(client.id)
  if not state.csproj_reload_pending then
    state.csproj_reload_pending = { timer = nil, pending = false }
  end
  local pending = state.csproj_reload_pending

  if pending.timer then
    safe_close_handle(pending.timer)
    pending.timer = nil
  end

  pending.pending = true
  local timer = uv.new_timer()
  pending.timer = timer

  timer:start(500, 0, function()
    pending.timer = nil
    pending.pending = false

    vim.schedule(function()
      if client.is_stopped and client.is_stopped() then
        return
      end

      local project_paths = collect_roslyn_project_paths(sln_info)
      if #project_paths == 0 then
        return
      end

      send_csproj_change_events(project_paths)
      notify_project_open(client, project_paths, notify)

      if config.options.enable_autorestore and project_paths[1] then
        pcall(restore_mod.schedule_restore, project_paths[1], function()
          vim.defer_fn(function()
            if client.is_stopped and client.is_stopped() then
              return
            end
            send_csproj_change_events(project_paths)
            notify_project_open(client, project_paths, notify)
            request_diagnostics_refresh(client, 500)
          end, 500)
        end)
      end
    end)
  end)
end

local function process_auto_restore(client_id, evs, state)
  if not config.options.enable_autorestore then
    return
  end

  local restore_triggered = false
  for _, ev in ipairs(evs) do
    local uri = ev.uri
    if uri and (uri:match("%.csproj$") or uri:match("%.vbproj$") or uri:match("%.fsproj$")) then
      pcall(restore_mod.schedule_restore, vim.uri_to_fname(uri), 2000)
      restore_triggered = true
    end
  end

  if not restore_triggered then
    for _, ev in ipairs(evs) do
      if ev.type == 1 and ev.uri then
        local path = vim.uri_to_fname(ev.uri)
        if path:match("%.cs$") or path:match("%.vb$") or path:match("%.fs$") then
          if state.sln_info and state.sln_info.path then
            pcall(restore_mod.schedule_restore, state.sln_info.path, 5000)
          end
          break
        end
      end
    end
  end
end

local function process_csproj_only_reload(client_id, evs, state)
  if not config.options.solution_aware or not state.sln_info or not state.sln_info.csproj_only then
    return
  end

  for _, ev in ipairs(evs) do
    if ev.uri and ev.type == 1 then
      local path = vim.uri_to_fname(ev.uri)
      if path:match("%.cs$") or path:match("%.vb$") or path:match("%.fs$") then
        local clients_list = vim.lsp.get_clients()
        for _, c in ipairs(clients_list) do
          if vim.tbl_contains(config.options.client_names, c.name) and c.id == client_id then
            handle_csproj_reload(c, state.sln_info)
            break
          end
        end
        break
      end
    end
  end
end

local function queue_events(client_id, evs)
  if not evs or #evs == 0 then
    return
  end

  local state = get_client_state(client_id)
  process_auto_restore(client_id, evs, state)
  process_csproj_only_reload(client_id, evs, state)

  if config.options.batching and config.options.batching.enabled then
    if not state.batch_queue then
      state.batch_queue = { events = {}, timer = nil }
    end
    local queue = state.batch_queue
    vim.list_extend(queue.events, evs)

    if not queue.timer then
      local t = uv.new_timer()
      queue.timer = t
      t:start(config.options.batching.interval or 300, 0, function()
        local changes = queue.events
        queue.events = {}
        safe_close_handle(queue.timer)
        queue.timer = nil
        if #changes > 0 then
          local max_events = config.options.max_events_per_batch or 100
          if #changes > max_events then
            notify("[BATCH] Limiting batch from " .. #changes .. " to " .. max_events, vim.log.levels.DEBUG)
            local limited = {}
            for i = 1, max_events do
              limited[i] = changes[i]
            end
            changes = limited
          end
          vim.schedule(function()
            pcall(notify_roslyn, changes)
          end)
        end
      end)
    end
  else
    vim.schedule(function()
      pcall(notify_roslyn, evs)
    end)
  end
end

local function cleanup_client(client_id)
  local state = client_states[client_id]
  if not state then
    return
  end

  pcall(function()
    if fs_event_mod and fs_event_mod.clear then
      fs_event_mod.clear(client_id)
    end
  end)

  pcall(function()
    if fs_poll_mod and fs_poll_mod.stop then
      fs_poll_mod.stop(client_id)
    end
  end)

  safe_close_handle(state.watcher)
  safe_close_handle(state.poller)
  safe_close_handle(state.watchdog)
  safe_close_handle(state.sln_poll_timer)
  state.watcher = nil
  state.poller = nil
  state.watchdog = nil
  state.sln_poll_timer = nil

  if state.batch_queue and state.batch_queue.timer then
    safe_close_handle(state.batch_queue.timer)
    state.batch_queue = nil
  end

  if state.csproj_reload_pending and state.csproj_reload_pending.timer then
    safe_close_handle(state.csproj_reload_pending.timer)
    state.csproj_reload_pending = nil
  end

  pcall(rename_mod.clear, client_id)

  if state.autocmd_ids then
    pcall(vim.api.nvim_del_augroup_by_name, "RoslynFilewatch_" .. client_id)
    state.autocmd_ids = nil
  end

  pcall(function()
    if autocmds_mod and autocmds_mod.clear_client then
      autocmds_mod.clear_client(client_id)
    end
  end)

  if state.root then
    pcall(restore_mod.clear_for_root, state.root)
  end

  pcall(function()
    local regen = require("roslyn_filewatch.watcher.regen_detector")
    if regen and regen.clear then
      regen.clear(client_id)
    end
  end)

  pcall(watchdog_mod.clear, client_id)
end

function M.stop(client)
  if not client then
    return
  end
  cleanup_client(client.id)
  client_states[client.id] = nil
  notify("Watcher stopped for client " .. (client.name or "<unknown>"), vim.log.levels.DEBUG)
end

function M.resync()
  local clients = vim.lsp.get_clients()
  local resynced = 0

  for _, client in ipairs(clients) do
    if vim.tbl_contains(config.options.client_names, client.name) then
      local state = get_client_state(client.id)

      -- If using poller, flag is enough
      if state.poller then
        state.needs_full_scan = true
      else
        -- If using fs_event, we must trigger scan manually
        local helpers = {
          queue_events = queue_events,
          notify = notify,
          notify_roslyn_renames = notify_roslyn_renames,
          last_events = nil, -- Don't pass client_states here! state.last_event is updated below
        }
        -- Mock snapshots table structure for resync_snapshot_for
        local snapshots_wrapper = {
          [client.id] = state.snapshot,
        }

        snapshot_mod.resync_snapshot_for(client.id, state.root, snapshots_wrapper, helpers)

        -- Update state with result
        state.snapshot = snapshots_wrapper[client.id]
      end

      state.dirty_dirs = {}
      state.last_event = os.time()

      pcall(autocmds_mod.clear_client, client.id)

      if state.sln_info and state.sln_info.csproj_files then
        local project_paths = collect_roslyn_project_paths(state.sln_info)
        if #project_paths > 0 then
          notify_project_open(client, project_paths, notify)
          notify("[RESYNC] Sent project/open for " .. #project_paths .. " project(s)", vim.log.levels.DEBUG)
          if config.options.enable_autorestore and project_paths[1] then
            pcall(restore_mod.schedule_restore, project_paths[1], 1000)
          end
          request_diagnostics_refresh(client, 2000)
        end
      end

      resynced = resynced + 1
      notify("Resync triggered for client " .. client.name, vim.log.levels.INFO)
    end
  end

  if resynced > 0 then
    vim.notify("[roslyn-filewatch] Resync triggered for " .. resynced .. " client(s)", vim.log.levels.INFO)
  else
    vim.notify("[roslyn-filewatch] No active Roslyn clients to resync", vim.log.levels.WARN)
  end
end

function M.start(client)
  if not client or (client.is_stopped and client.is_stopped()) then
    return
  end

  local state = get_client_state(client.id)
  if state.watcher or state.poller or state.watchdog then
    return
  end

  local POLL_INTERVAL = config.options.poll_interval or 5000
  local POLLER_RESTART_THRESHOLD = config.options.poller_restart_threshold or 2
  local WATCHDOG_IDLE = config.options.watchdog_idle or 60
  local RENAME_WINDOW_MS = config.options.rename_detection_ms or 300
  local ACTIVITY_QUIET_PERIOD = config.options.activity_quiet_period or 5

  local root = client.config and client.config.root_dir
  if not root then
    notify("No root_dir for client " .. (client.name or "<unknown>"), vim.log.levels.ERROR)
    return
  end
  root = normalize_path(root)
  state.root = root

  config.apply_preset_for_root(root)
  local applied_preset = config.options._applied_preset
  if applied_preset then
    notify("[PRESET] Applied '" .. applied_preset .. "' preset", vim.log.levels.DEBUG)
  end

  local function calculate_backoff_delay()
    local initial = config.options.recovery_initial_delay_ms or 300
    local max_delay = config.options.recovery_max_delay_ms or 30000
    local base_delay = math.min(initial * math.pow(2, state.recovery_consecutive_failures), max_delay)
    local jitter = base_delay * 0.2 * (math.random() * 2 - 1)
    return math.max(initial, math.min(math.floor(base_delay + jitter), max_delay))
  end

  local function restart_watcher(reason, delay_ms, disable_fs_event)
    if not delay_ms then
      delay_ms = calculate_backoff_delay()
    end

    if state.restart_scheduled then
      return
    end
    state.restart_scheduled = true

    local now = os.time()
    if now < state.restart_backoff_until then
      notify("Restart suppressed due to backoff", vim.log.levels.DEBUG)
      state.restart_scheduled = false
      return
    end

    if disable_fs_event then
      state.fs_event_disabled_until = now + 5
    end
    state.restart_backoff_until = now + math.ceil(delay_ms / 1000)

    notify(
      string.format("Scheduling restart (reason: %s, delay: %dms)", tostring(reason), delay_ms),
      vim.log.levels.DEBUG
    )

    vim.defer_fn(function()
      state.restart_scheduled = false
      if client.is_stopped() then
        return
      end

      notify("Restarting watcher for " .. client.name, vim.log.levels.DEBUG)

      if state.watcher then
        safe_close_handle(state.watcher)
        state.watcher = nil
      end

      local use_fs_event = not config.options.force_polling
      if state.fs_event_disabled_until > 0 and os.time() < state.fs_event_disabled_until then
        use_fs_event = false
      end

      local restart_success = false
      if use_fs_event then
        local snapshots_proxy_inner = setmetatable({}, {
          __index = function(_, k)
            return client_states[k] and client_states[k].snapshot
          end,
          __newindex = function(_, k, v)
            if client_states[k] then
              client_states[k].snapshot = v
            end
          end,
        })

        local handle, err = fs_event_mod.start(client, root, snapshots_proxy_inner, {
          notify = notify,
          queue_events = queue_events,
          notify_roslyn_renames = notify_roslyn_renames,
          restart_watcher = restart_watcher,
          mark_dirty_dir = mark_dirty_dir,
        })
        if handle then
          state.watcher = handle
          restart_success = true
        else
          notify("Failed to recreate fs_event: " .. tostring(err), vim.log.levels.DEBUG)
        end
      else
        restart_success = true
      end

      if restart_success then
        state.recovery_consecutive_failures = 0
        state.recovery_current_backoff = config.options.recovery_initial_delay_ms or 300
        if config.options.recovery_verify_enabled then
          vim.defer_fn(function()
            if client.is_stopped() then
              return
            end
            state.needs_full_scan = true
            state.last_event = os.time()
          end, 500)
        end
      else
        state.recovery_consecutive_failures = state.recovery_consecutive_failures + 1
        local max_retries = config.options.recovery_max_retries or 5
        if state.recovery_consecutive_failures >= max_retries then
          vim.schedule(function()
            vim.notify(
              "[roslyn-filewatch] Watcher recovery failed after " .. max_retries .. " attempts",
              vim.log.levels.WARN
            )
          end)
          state.recovery_consecutive_failures = 0
        end
      end
    end, delay_ms)
  end

  local snapshots_proxy = setmetatable({}, {
    __index = function(_, k)
      return client_states[k] and client_states[k].snapshot
    end,
    __newindex = function(_, k, v)
      if client_states[k] then
        client_states[k].snapshot = v
      end
    end,
  })

  local last_events_proxy = setmetatable({}, {
    __index = function(_, k)
      return client_states[k] and client_states[k].last_event
    end,
    __newindex = function(_, k, v)
      if client_states[k] then
        client_states[k].last_event = v
      end
    end,
  })

  local force_polling = config.options.force_polling or false
  local now = os.time()
  local use_fs_event = not force_polling and now >= state.fs_event_disabled_until

  if use_fs_event then
    local handle, start_err = fs_event_mod.start(client, root, snapshots_proxy, {
      config = config,
      rename_mod = rename_mod,
      snapshot_mod = snapshot_mod,
      notify = notify,
      notify_roslyn_renames = notify_roslyn_renames,
      queue_events = queue_events,
      restart_watcher = restart_watcher,
      mark_dirty_dir = mark_dirty_dir,
      mtime_ns = mtime_ns,
      identity_from_stat = identity_from_stat,
      same_file_info = same_file_info,
      normalize_path = normalize_path,
      last_events = last_events_proxy,
      rename_window_ms = RENAME_WINDOW_MS,
    })

    if not handle then
      notify("Failed to create fs_event: " .. tostring(start_err), vim.log.levels.WARN)
      state.fs_event_disabled_until = os.time() + 5
      use_fs_event = false
    else
      state.watcher = handle
      state.last_event = os.time()
    end
  else
    notify("Using poller-only mode for " .. client.name, vim.log.levels.DEBUG)
    state.last_event = os.time()
  end

  state.needs_full_scan = true

  -- Perform initial scan if using fs_event (as it has no poll loop)
  if not state.poller and state.watcher then
    snapshot_mod.scan_tree_async(root, function(new_map)
      state.snapshot = new_map
      state.needs_full_scan = false
      notify("Initial scan complete: " .. vim.tbl_count(new_map) .. " files", vim.log.levels.DEBUG)
    end)
  end

  if config.options.solution_aware then
    local ok, sln_parser = pcall(require, "roslyn_filewatch.watcher.sln_parser")
    if ok and sln_parser and sln_parser.get_sln_info_async then
      sln_parser.get_sln_info_async(root, function(sln_info)
        if sln_info then
          state.sln_info = { path = sln_info.path, mtime = sln_info.mtime, csproj_files = nil }

          sln_parser.get_project_dirs_async(sln_info.path, sln_info.type, function(project_dirs)
            if project_dirs and #project_dirs > 0 then
              notify("[SLN] Parsing for " .. #project_dirs .. " projects", vim.log.levels.DEBUG)
              scan_projects_from_sln_async(project_dirs, function(initial_csproj)
                if state.sln_info then
                  state.sln_info.csproj_files = initial_csproj
                  local project_paths = collect_roslyn_project_paths(state.sln_info)
                  if #project_paths > 0 then
                    vim.schedule(function()
                      notify_project_open(client, project_paths, notify)
                      notify("[STARTUP] Loaded " .. #project_paths .. " projects", vim.log.levels.DEBUG)
                    end)
                  end
                end
              end)
            else
              notify("[SLN] Parser returned no projects, falling back", vim.log.levels.DEBUG)
              scan_csproj_async(root, function(initial_csproj)
                if state.sln_info then
                  state.sln_info.csproj_files = initial_csproj
                  local project_paths = collect_roslyn_project_paths(state.sln_info)
                  if #project_paths > 0 then
                    vim.schedule(function()
                      notify_project_open(client, project_paths, notify)
                      request_diagnostics_refresh(client, 2000)
                    end)
                  end
                end
              end)
            end
          end)
        else
          notify("[SLN] No solution file, checking for csproj-only", vim.log.levels.DEBUG)
          scan_csproj_async(root, function(csproj_files)
            if not csproj_files or vim.tbl_count(csproj_files) == 0 then
              vim.schedule(function()
                notify("No solution or csproj files in: " .. root, vim.log.levels.DEBUG)
              end)
              return
            end

            state.sln_info = { path = nil, mtime = 0, csproj_files = csproj_files, csproj_only = true }
            local project_paths = collect_roslyn_project_paths(state.sln_info)
            if #project_paths > 0 then
              vim.schedule(function()
                notify_project_open(client, project_paths, notify)
                request_diagnostics_refresh(client, 2000)
              end)
            end
          end)
        end
      end)
    else
      vim.schedule(function()
        vim.notify("[roslyn-filewatch] Failed to load sln_parser", vim.log.levels.WARN)
      end)
    end
  end

  local poller, poll_err = fs_poll_mod.start(client, root, snapshots_proxy, {
    scan_tree = scan_tree,
    scan_tree_async = snapshot_mod.scan_tree_async,
    is_scanning = snapshot_mod.is_scanning,
    partial_scan = snapshot_mod.partial_scan,
    partial_scan_async = snapshot_mod.partial_scan_async,
    get_dirty_dirs = get_and_clear_dirty_dirs,
    should_full_scan = should_full_scan,
    identity_from_stat = identity_from_stat,
    same_file_info = same_file_info,
    queue_events = queue_events,
    notify = notify,
    notify_roslyn_renames = notify_roslyn_renames,
    restart_watcher = restart_watcher,
    last_events = last_events_proxy,
    poll_interval = POLL_INTERVAL,
    poller_restart_threshold = POLLER_RESTART_THRESHOLD,
    activity_quiet_period = ACTIVITY_QUIET_PERIOD,
    check_sln_changed = function(cid, poll_root)
      local poll_state = get_client_state(cid)
      if not poll_state.sln_info or not poll_state.sln_info.path then
        return false
      end
      local stat = uv.fs_stat(poll_state.sln_info.path)
      if not stat then
        return false
      end
      local current_mtime = stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)
      if current_mtime ~= poll_state.sln_info.mtime then
        notify("[SLN] Solution mtime changed", vim.log.levels.DEBUG)
        poll_state.sln_info.mtime = current_mtime
        return true
      end
      return false
    end,
    on_sln_changed = function(cid, poll_root)
      local poll_state = get_client_state(cid)
      notify("[SLN] Solution changed, rescanning", vim.log.levels.DEBUG)
      poll_state.needs_full_scan = true
      scan_csproj_async(poll_root, function(collected_mtimes)
        if not poll_state.sln_info then
          return
        end
        local previous_csproj = poll_state.sln_info.csproj_files or {}
        local new_projects_list = {}
        local current_csproj_set = {}

        for path, mtime in pairs(collected_mtimes) do
          current_csproj_set[path] = mtime
          if not previous_csproj[path] then
            table.insert(new_projects_list, to_roslyn_path(path))
          end
        end

        poll_state.sln_info.csproj_files = current_csproj_set

        if #new_projects_list > 0 then
          vim.schedule(function()
            for _, c in ipairs(vim.lsp.get_clients()) do
              if vim.tbl_contains(config.options.client_names, c.name) then
                notify_project_open(c, new_projects_list, notify)
                request_diagnostics_refresh(c, 2000)
              end
            end
          end)
        end
      end)
    end,
  })

  if not poller then
    notify("Failed to create poller: " .. tostring(poll_err), vim.log.levels.ERROR)
    safe_close_handle(state.watcher)
    state.watcher = nil
    return
  end
  state.poller = poller

  if config.options.solution_aware then
    local sln_timer = uv.new_timer()
    if sln_timer then
      notify("[PROJECT] Starting project watcher timer", vim.log.levels.DEBUG)

      sln_timer:start(POLL_INTERVAL, POLL_INTERVAL, function()
        if client.is_stopped and client.is_stopped() then
          safe_close_handle(sln_timer)
          state.sln_poll_timer = nil
          return
        end

        local cached = state.sln_info
        if not cached then
          return
        end

        if cached.csproj_only then
          scan_csproj_async(root, function(collected_mtimes)
            if not state.sln_info then
              return
            end

            local previous_csproj = state.sln_info.csproj_files or {}
            local new_projects_list = {}
            local current_csproj_set = {}

            for path, current_mtime in pairs(collected_mtimes) do
              current_csproj_set[path] = current_mtime
              local old_mtime = previous_csproj[path]
              if not old_mtime or old_mtime ~= current_mtime then
                table.insert(new_projects_list, to_roslyn_path(path))
                if old_mtime and old_mtime ~= current_mtime then
                  pcall(restore_mod.schedule_restore, path)
                end
              end
            end

            state.sln_info.csproj_files = current_csproj_set

            if #new_projects_list > 0 then
              vim.schedule(function()
                for _, c in ipairs(vim.lsp.get_clients()) do
                  if vim.tbl_contains(config.options.client_names, c.name) then
                    notify_project_open(c, new_projects_list, notify)
                    request_diagnostics_refresh(c, 2000)
                  end
                end
              end)
            end
          end)
          return
        end

        if not cached.path then
          return
        end

        uv.fs_stat(cached.path, function(err, stat)
          if err or not stat then
            return
          end

          local current_mtime = stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)
          if current_mtime == cached.mtime then
            return
          end

          local old_csproj = cached.csproj_files
          state.sln_info = { path = cached.path, mtime = current_mtime, csproj_files = old_csproj }

          vim.schedule(function()
            if not state.sln_info or not state.sln_info.path then
              return
            end

            local previous_csproj = state.sln_info.csproj_files or {}

            scan_csproj_async(root, function(collected_mtimes)
              local new_projects_list = {}
              local current_csproj_set = {}
              local restore_needed = false

              for path, current_mtime_sec in pairs(collected_mtimes) do
                current_csproj_set[path] = current_mtime_sec
                local old_mtime = previous_csproj[path]
                if state.sln_info.csproj_files and (not old_mtime or old_mtime ~= current_mtime_sec) then
                  table.insert(new_projects_list, to_roslyn_path(path))
                  if old_mtime and old_mtime ~= current_mtime_sec then
                    restore_needed = true
                  end
                end
              end

              if restore_needed then
                pcall(restore_mod.schedule_restore, state.sln_info.path)
              end

              if not state.sln_info.csproj_files then
                state.sln_info.csproj_files = current_csproj_set
                return
              end

              state.sln_info.csproj_files = current_csproj_set

              if #new_projects_list > 0 then
                for _, c in ipairs(vim.lsp.get_clients()) do
                  if vim.tbl_contains(config.options.client_names, c.name) then
                    notify_project_open(c, new_projects_list, notify)
                    request_diagnostics_refresh(c, 2000)
                  end
                end
              end
            end)
          end)
        end)
      end)
      state.sln_poll_timer = sln_timer
    end
  end

  local watchdog, watchdog_err = watchdog_mod.start(client, root, snapshots_proxy, {
    notify = notify,
    restart_watcher = restart_watcher,
    get_handle = function()
      return state.watcher
    end,
    get_poller = function()
      return state.poller
    end,
    get_snapshot = function()
      return state.snapshot
    end,
    mark_needs_full_scan = function()
      state.needs_full_scan = true
      if not state.poller and state.watcher then
        -- Trigger manual resync for watchdog
        local helpers = {
          queue_events = queue_events,
          notify = notify,
          notify_roslyn_renames = notify_roslyn_renames,
          last_events = last_events_proxy,
        }
        snapshot_mod.resync_snapshot_for(client.id, root, snapshots_proxy, helpers)
      end
    end,
    last_events = last_events_proxy,
    watchdog_idle = WATCHDOG_IDLE,
    use_fs_event = use_fs_event,
  })

  if not watchdog then
    notify("Failed to start watchdog: " .. tostring(watchdog_err), vim.log.levels.ERROR)
    safe_close_handle(state.poller)
    safe_close_handle(state.watcher)
    state.poller = nil
    state.watcher = nil
    return
  end
  state.watchdog = watchdog

  local sln_mtimes_proxy = setmetatable({}, {
    __index = function(_, k)
      return client_states[k] and client_states[k].sln_info
    end,
  })

  local autocmd_ids = autocmds_mod.start(client, root, snapshots_proxy, {
    notify = notify,
    restart_watcher = restart_watcher,
    normalize_path = normalize_path,
    queue_events = queue_events,
    sln_mtimes = sln_mtimes_proxy,
    restore_mod = restore_mod,
  })
  state.autocmd_ids = autocmd_ids

  notify("Watcher started for " .. client.name .. " at: " .. root, vim.log.levels.DEBUG)

  vim.api.nvim_create_autocmd("LspDetach", {
    callback = function(args)
      if args.data.client_id == client.id then
        vim.schedule(function()
          local still_active = vim.lsp.get_client_by_id(client.id)
          if still_active and not (still_active.is_stopped and still_active:is_stopped()) then
            pcall(autocmds_mod.clear_client, client.id)
            notify("LspDetach: Buffer detached, client still active", vim.log.levels.DEBUG)
            return
          end

          notify("LspDetach: Client stopping, cleanup", vim.log.levels.DEBUG)

          local diag_mod = get_diagnostics_mod()
          if diag_mod and diag_mod.clear_client then
            pcall(diag_mod.clear_client, client.id)
          end

          if fs_event_mod and fs_event_mod.clear then
            pcall(fs_event_mod.clear, client.id)
          end

          cleanup_client(client.id)
          client_states[client.id] = nil
        end)
        return true
      end
    end,
  })
end

function M.reload_projects()
  local clients = vim.lsp.get_clients()
  local reloaded = 0

  for _, client in ipairs(clients) do
    if vim.tbl_contains(config.options.client_names, client.name) then
      local state = get_client_state(client.id)

      if state.sln_info and state.sln_info.csproj_files then
        local project_paths = collect_roslyn_project_paths(state.sln_info)

        if #project_paths > 0 then
          notify_project_open(client, project_paths, notify)
          reloaded = reloaded + 1

          local diag_mod = get_diagnostics_mod()
          if diag_mod and diag_mod.request_visible_diagnostics then
            vim.defer_fn(function()
              if client.is_stopped and client.is_stopped() then
                return
              end
              diag_mod.request_visible_diagnostics(client.id)
            end, 2000)
          else
            request_diagnostics_refresh(client, 2000)
          end
        end
      end
    end
  end

  if reloaded > 0 then
    vim.notify("[roslyn-filewatch] Reloaded projects for " .. reloaded .. " client(s)", vim.log.levels.INFO)
  else
    vim.notify("[roslyn-filewatch] No projects to reload", vim.log.levels.WARN)
  end
end

return M
