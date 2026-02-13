---@class roslyn_filewatch.fs_event
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table, deps: table): uv_fs_event_t|nil, string|nil
---@field clear fun(client_id: number)

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")
local rename_mod = require("roslyn_filewatch.watcher.rename")
local snapshot_mod = require("roslyn_filewatch.watcher.snapshot")
local notify_mod = require("roslyn_filewatch.watcher.notify")

local notify = notify_mod and notify_mod.user or function() end

local M = {}

---@type table<number, {map: table, timer: uv_timer_t|nil}>
local event_buffers = {}

---@type table<number, {events: string[], processing: boolean}>
local raw_event_queues = {}

local regen_detector = nil
local function get_regen_detector()
  if regen_detector == nil then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.regen_detector")
    if ok then
      regen_detector = mod
      if mod.set_on_regen_start then
        mod.set_on_regen_start(function(client_id)
          local q = raw_event_queues[client_id]
          if q then
            q.events = {}
            q.processing = false
          end
          local buf = event_buffers[client_id]
          if buf then
            if buf.timer and not buf.timer:is_closing() then
              buf.timer:stop()
              buf.timer:close()
            end
            buf.timer = nil
            buf.map = {}
          end
        end)
      end
    else
      regen_detector = false
    end
  end
  return regen_detector or nil
end

---@type table<number, boolean>
local fast_regen_flags = {}

---@type table<number, number>
local event_sample_counters = {}
local EVENT_SAMPLE_RATE = 10

---@type table<number, {count: number, since: number}>
local error_counters = {}

---@type table<number, number>
local last_resync_ts = {}

local ERROR_WINDOW_SEC = 2
local ERROR_THRESHOLD = 2
local RESYNC_MIN_INTERVAL_SEC = 2
local DEFAULT_PROCESSING_DEBOUNCE_MS = 150
local FLUSH_CHUNK_SIZE = 25
local FLUSH_CHUNK_DELAY_MS = 5
local RAW_PROCESS_CHUNK_SIZE = 100
local RAW_PROCESS_DELAY_MS = 5
local MAX_RAW_QUEUE_SIZE = 500

local function stop_close_timer(t)
  if t and not t:is_closing() then
    pcall(t.stop, t)
    pcall(t.close, t)
  end
end

function M.clear(client_id)
  local buf = event_buffers[client_id]
  if buf then
    stop_close_timer(buf.timer)
    event_buffers[client_id] = nil
  end
  raw_event_queues[client_id] = nil
  fast_regen_flags[client_id] = nil
  event_sample_counters[client_id] = nil
  error_counters[client_id] = nil
  last_resync_ts[client_id] = nil
end

local function should_watch_path(fullpath, cfg)
  local opts = cfg.options
  if not opts then
    return false
  end

  local ext = utils.get_extension(fullpath)
  if not ext then
    return false
  end

  local is_win = utils.is_windows()
  local compare_ext = is_win and ext:lower() or ext

  local ext_match = false
  for _, watch_ext in ipairs(opts.watch_extensions or {}) do
    local cmp = is_win and watch_ext:lower() or watch_ext
    if compare_ext == cmp then
      ext_match = true
      break
    end
  end

  if not ext_match then
    return false
  end

  return utils.should_watch_path(fullpath, opts.ignore_dirs or {}, opts.watch_extensions or {})
end

local function record_error(client_id, msg, notify_fn, restart_fn)
  local now = os.time()
  local ec = error_counters[client_id] or { count = 0, since = now }
  if now - (ec.since or 0) > ERROR_WINDOW_SEC then
    ec = { count = 0, since = now }
  end
  ec.count = ec.count + 1
  error_counters[client_id] = ec

  local is_perm_error = msg and (msg:match("EPERM") or msg:lower():match("permission"))

  if is_perm_error and ec.count >= ERROR_THRESHOLD then
    pcall(notify_fn, "Persistent EPERM errors; restarting watcher", vim.log.levels.ERROR)
    error_counters[client_id] = nil
    vim.defer_fn(function()
      if restart_fn then
        pcall(restart_fn, "EPERM_escalated", 1200, true)
      end
    end, 50)
    return true
  end

  if is_perm_error then
    pcall(notify_fn, "EPERM error: " .. tostring(msg), vim.log.levels.WARN)
  else
    pcall(notify_fn, "fs_event error: " .. tostring(msg), vim.log.levels.ERROR)
  end
  return false
end

local function maybe_restart_nil_filename(client_id, notify_fn, restart_fn)
  local now = os.time()
  local last = last_resync_ts[client_id] or 0
  if now - last < RESYNC_MIN_INTERVAL_SEC then
    return false
  end
  last_resync_ts[client_id] = now
  vim.defer_fn(function()
    pcall(notify_fn, "fs_event filename=nil -> restart", vim.log.levels.DEBUG)
    if restart_fn then
      pcall(restart_fn, "filename_nil", 800)
    end
  end, 50)
  return true
end

local function schedule_raw_processing(client_id, root, cfg, schedule_flush_fn)
  local q = raw_event_queues[client_id]
  if not q or q.processing or #q.events == 0 then
    return
  end

  q.processing = true

  local function process_chunk()
    local queue = raw_event_queues[client_id]
    if not queue then
      return
    end

    local chunk_size = math.min(#queue.events, RAW_PROCESS_CHUNK_SIZE)
    if chunk_size == 0 then
      queue.processing = false
      return
    end

    local chunk = {}
    for i = 1, chunk_size do
      chunk[i] = queue.events[i]
    end

    local new_events = {}
    for i = chunk_size + 1, #queue.events do
      new_events[#new_events + 1] = queue.events[i]
    end
    queue.events = new_events

    local added_any = false
    for _, filename in ipairs(chunk) do
      if filename then
        local fullpath = utils.normalize_path(root .. "/" .. filename)
        if utils.get_extension(fullpath) and should_watch_path(fullpath, cfg) then
          event_buffers[client_id] = event_buffers[client_id] or { map = {}, timer = nil }
          event_buffers[client_id].map[fullpath] = true
          added_any = true
        end
      end
    end

    if added_any then
      schedule_flush_fn(client_id)
    end

    if #queue.events > 0 then
      vim.defer_fn(process_chunk, RAW_PROCESS_DELAY_MS)
    else
      queue.processing = false
    end
  end

  vim.defer_fn(process_chunk, RAW_PROCESS_DELAY_MS)
end

function M.start(client, root, snapshots, deps)
  if not client or not root or not deps then
    return nil, "missing required arguments"
  end

  local cfg = deps.config or config
  local rename_m = deps.rename_mod or rename_mod
  local notify_fn = deps.notify or notify
  local notify_roslyn_renames = deps.notify_roslyn_renames
  local queue_events = deps.queue_events
  local restart_watcher = deps.restart_watcher
  local mtime_ns = deps.mtime_ns or utils.mtime_ns
  local identity_from_stat = deps.identity_from_stat or utils.identity_from_stat
  local same_file_info = deps.same_file_info or utils.same_file_info
  local normalize_path = deps.normalize_path or utils.normalize_path
  local last_events = deps.last_events
  local rename_window_ms = deps.rename_window_ms or 300
  local processing_debounce_ms = (cfg.options and cfg.options.processing_debounce_ms) or DEFAULT_PROCESSING_DEBOUNCE_MS
  local mark_dirty_dir = deps.mark_dirty_dir

  snapshots[client.id] = snapshots[client.id] or {}

  local handle, err = uv.new_fs_event()
  if not handle then
    return nil, err or "uv.new_fs_event failed"
  end

  local function flush_client_buffer(client_id)
    local buf = event_buffers[client_id]
    if not buf or not buf.map then
      return
    end

    local paths = {}
    for p in pairs(buf.map) do
      table.insert(paths, p)
    end
    buf.map = {}
    stop_close_timer(buf.timer)
    buf.timer = nil

    if #paths == 0 then
      return
    end

    local all_evs = {}
    local idx = 1

    local function process_file(fullpath, on_done)
      if mark_dirty_dir then
        pcall(mark_dirty_dir, client_id, fullpath)
      end

      if not should_watch_path(fullpath, cfg) then
        on_done()
        return
      end

      local prev_mt = snapshots[client.id] and snapshots[client.id][fullpath]

      uv.fs_stat(fullpath, function(stat_err, st)
        vim.schedule(function()
          if not stat_err and st then
            local new_entry = { mtime = mtime_ns(st), size = st.size, ino = st.ino, dev = st.dev }
            local matched = false

            if rename_m and rename_m.on_create then
              local ok, res = pcall(rename_m.on_create, client.id, fullpath, st, snapshots, {
                notify = notify_fn,
                notify_roslyn_renames = notify_roslyn_renames,
              })
              if ok and res then
                matched = true
              end
            end

            if not matched then
              snapshots[client.id] = snapshots[client.id] or {}
              snapshots[client.id][fullpath] = new_entry
              if not prev_mt then
                table.insert(all_evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
              elseif not same_file_info(prev_mt, new_entry) then
                table.insert(all_evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
              end
            end
          else
            if prev_mt then
              local buffered = false
              if rename_m and rename_m.on_delete then
                local ok, res = pcall(rename_m.on_delete, client.id, fullpath, prev_mt, snapshots, {
                  queue_events = queue_events,
                  notify = notify_fn,
                  rename_window_ms = rename_window_ms,
                })
                if ok and res then
                  buffered = true
                end
              end

              if not buffered then
                if snapshots[client.id] then
                  snapshots[client.id][fullpath] = nil
                end
                table.insert(all_evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
              end
            end
          end
          on_done()
        end)
      end)
    end

    local function process_chunk()
      local chunk_end = math.min(idx + FLUSH_CHUNK_SIZE - 1, #paths)
      local pending = chunk_end - idx + 1
      local completed = 0

      for i = idx, chunk_end do
        process_file(paths[i], function()
          completed = completed + 1
          if completed == pending then
            idx = chunk_end + 1
            if idx <= #paths then
              vim.defer_fn(process_chunk, FLUSH_CHUNK_DELAY_MS)
            elseif #all_evs > 0 then
              pcall(queue_events, client.id, all_evs)
            end
          end
        end)
      end
    end

    process_chunk()
  end

  local function schedule_flush(client_id)
    local buf = event_buffers[client_id]
    if not buf then
      buf = { map = {}, timer = nil }
      event_buffers[client_id] = buf
    end

    if not buf.timer then
      local t = uv.new_timer()
      buf.timer = t

      local raw_q = raw_event_queues[client_id]
      local raw_count = raw_q and #raw_q.events or 0
      local buf_count = vim.tbl_count(buf.map)

      local debounce = processing_debounce_ms
      if raw_count == 0 and buf_count < 5 then
        debounce = math.min(50, processing_debounce_ms)
      end

      t:start(debounce, 0, function()
        pcall(flush_client_buffer, client_id)
      end)
    end
  end

  local ok_start, start_err = pcall(function()
    handle:start(root, { recursive = true }, function(err2, filename, _)
      if fast_regen_flags[client.id] then
        event_sample_counters[client.id] = (event_sample_counters[client.id] or 0) + 1
        if event_sample_counters[client.id] >= EVENT_SAMPLE_RATE then
          event_sample_counters[client.id] = 0
          local regen = get_regen_detector()
          if regen then
            pcall(regen.on_event, client.id)
            if not regen.is_regenerating(client.id) then
              fast_regen_flags[client.id] = false
            end
          end
        end
        return
      end

      local ok_cb, _ = pcall(function()
        if err2 then
          record_error(client.id, tostring(err2), notify_fn, function(reason, delay_ms, disable)
            if restart_watcher then
              pcall(restart_watcher, reason, delay_ms, disable)
            end
          end)

          vim.defer_fn(function()
            if handle and not handle:is_closing() then
              pcall(handle.stop, handle)
              pcall(handle.close, handle)
            end
            if restart_watcher then
              pcall(restart_watcher, "EPERM", 800, true)
            end
          end, 50)
          return
        end

        if not filename then
          maybe_restart_nil_filename(client.id, notify_fn, function(reason, delay_ms)
            if restart_watcher then
              pcall(restart_watcher, reason, delay_ms)
            end
          end)
          return
        end

        if last_events then
          last_events[client.id] = os.time()
        end

        local regen = get_regen_detector()
        if regen then
          pcall(regen.on_event, client.id)
          if regen.is_regenerating(client.id) then
            fast_regen_flags[client.id] = true
            event_sample_counters[client.id] = 0
            return
          end
        end

        local q = raw_event_queues[client.id]
        if not q then
          q = { events = {}, processing = false }
          raw_event_queues[client.id] = q
        end

        table.insert(q.events, filename)

        while #q.events > MAX_RAW_QUEUE_SIZE do
          table.remove(q.events, 1)
        end

        if not q.processing then
          schedule_raw_processing(client.id, root, cfg, schedule_flush)
        end
      end)

      if not ok_cb then
        record_error(client.id, "callback error", notify_fn, function(reason, delay_ms, disable)
          if restart_watcher then
            pcall(restart_watcher, reason, delay_ms, disable)
          end
        end)
      end
    end)
  end)

  if not ok_start then
    if handle and handle.close then
      pcall(handle.close, handle)
    end
    return nil, start_err
  end

  return handle, nil
end

return M
