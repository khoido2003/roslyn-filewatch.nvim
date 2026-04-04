---@class roslyn_filewatch.snapshot
---@field scan_tree fun(root: string, out_map: table)
---@field scan_tree_async fun(root: string, callback: fun(out_map: table), on_progress?: fun(scanned: number))
---@field is_scanning fun(root: string): boolean

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

local normalize_path = utils.normalize_path
local mtime_ns = utils.mtime_ns
local should_watch_path = utils.should_watch_path

local M = {}

---@type table<string, boolean>
local scanning_in_progress = {}
local rust_warned = false

--- Cached gitignore state per root
---@type table<string, { matcher: any, mtime: number }>
local gitignore_cache = {}

function M.cancel_async_scan(root)
  scanning_in_progress[normalize_path(root)] = nil
end

function M.is_scanning(root)
  return scanning_in_progress[normalize_path(root)] == true
end

local function check_rust_module()
  local ok, rs = pcall(require, "roslyn_filewatch_rs")
  if ok and rs and rs.fast_snapshot then
    return true, rs
  end
  if not rust_warned then
    rust_warned = true
    -- Silently fall back to fd/Lua scanning.
    -- Users can check :checkhealth for missing optional tools.
  end
  return false, nil
end

--- Build options table for the Rust fast_snapshot call
---@return table
local function build_rust_options()
  local opts = config.options or {}
  return {
    extensions = opts.watch_extensions,
    ignore_dirs = opts.ignore_dirs,
    respect_gitignore = opts.respect_gitignore ~= false,
  }
end

--- Call Rust fast_snapshot and normalize the result into snapshot format
---@param rs table The Rust module
---@param root string Root directory
---@return table<string, roslyn_filewatch.SnapshotEntry>|nil
local function call_rust_snapshot(rs, root)
  local ok_snap, result = pcall(rs.fast_snapshot, root, build_rust_options())
  if not ok_snap or type(result) ~= "table" then
    return nil
  end

  local out = {}
  for path, info in pairs(result) do
    out[path] = {
      mtime = info.mtime or 0,
      size = info.size or 0,
    }
  end
  return out
end

--- Get cached or freshly loaded gitignore matcher
---@param root string
---@return any|nil matcher
---@return any|nil gitignore_mod
local function get_cached_gitignore(root)
  if config.options.respect_gitignore == false then
    return nil, nil
  end

  local ok, gitignore_mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
  if not ok or not gitignore_mod then
    return nil, nil
  end

  local gitignore_path = root .. "/.gitignore"
  local stat = uv.fs_stat(gitignore_path)
  if not stat then
    gitignore_cache[root] = nil
    return nil, gitignore_mod
  end

  local current_mtime = stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)
  local cached = gitignore_cache[root]

  if cached and cached.mtime == current_mtime then
    return cached.matcher, gitignore_mod
  end

  local matcher = gitignore_mod.load(root)
  gitignore_cache[root] = { matcher = matcher, mtime = current_mtime }
  return matcher, gitignore_mod
end

local function scan_tree_async_fd(fd_exe, root, callback, on_progress)
  root = normalize_path(root)
  local args = { "--type", "f", "--color", "never", "--absolute-path" }

  if config.options.respect_gitignore == false then
    table.insert(args, "--no-ignore")
    table.insert(args, "--hidden")
  end

  for _, dir in ipairs(config.options.ignore_dirs or {}) do
    table.insert(args, "--exclude")
    table.insert(args, dir)
  end

  for _, pattern in ipairs(config.options.ignore_patterns or {}) do
    table.insert(args, "--exclude")
    table.insert(args, pattern)
  end

  for _, ext in ipairs(config.options.watch_extensions or {}) do
    table.insert(args, "--extension")
    table.insert(args, (ext:gsub("^%.", "")))
  end

  table.insert(args, root)

  local out_map = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local buffer = ""

  local exit_code = nil
  local stdout_closed = false
  local handle_closed = false

  local process_idx = 1
  local pending_paths = {}

  local function check_all_done()
    if all_stats_queued and process_idx > #pending_paths then
      scanning_in_progress[root] = nil
      vim.schedule(function()
        if callback then
          callback(out_map)
        end
      end)
    end
  end

  local function drain_pending()
    if not scanning_in_progress[root] then
      return
    end

    local chunk = 0
    local CHUNK_SIZE = 2000

    while chunk < CHUNK_SIZE and process_idx <= #pending_paths do
      local path = pending_paths[process_idx]
      process_idx = process_idx + 1

      local st = uv.fs_stat(path)
      if st then
        out_map[path] = {
          mtime = mtime_ns(st),
          size = st.size,
          ino = st.ino,
          dev = st.dev,
        }
      end

      chunk = chunk + 1
      total_processed = total_processed + 1

      if on_progress and total_processed % 2000 == 0 then
        -- We cannot block inside the iterator thread safely, schedule the callback
        vim.schedule(function()
          pcall(on_progress, total_processed)
        end)
      end
    end

    if process_idx <= #pending_paths or not all_stats_queued then
      vim.defer_fn(drain_pending, 2)
    else
      check_all_done()
    end
  end

  local function process_line(line)
    if #line > 0 then
      table.insert(pending_paths, normalize_path(line))
    end
  end

  vim.defer_fn(drain_pending, 2)

  local function on_finish()
    if not stdout_closed or not handle_closed then
      return
    end

    if exit_code ~= 0 and process_idx > #pending_paths and total_processed == 0 then
      scanning_in_progress[root] = nil
      if callback then
        vim.schedule(function()
          callback(out_map)
        end)
      end
      return
    end

    if not scanning_in_progress[root] then
      return
    end

    all_stats_queued = true
    check_all_done()
  end

  local handle
  handle = uv.spawn(fd_exe, {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code)
    exit_code = code
    if handle then
      handle:close()
    end
    handle_closed = true
    on_finish()
  end)

  if not handle then
    scanning_in_progress[root] = nil
    if stdout then
      stdout:close()
    end
    if stderr then
      stderr:close()
    end
    return
  end

  if stdout then
    uv.read_start(stdout, function(err, data)
      if err then
        if stdout then
          stdout:read_stop()
          stdout:close()
        end
        stdout_closed = true
        on_finish()
        return
      end

      if data then
        buffer = buffer .. data
        while true do
          local line_end = buffer:find("\n")
          if not line_end then
            break
          end

          local line = buffer:sub(1, line_end - 1):gsub("\r$", "")
          buffer = buffer:sub(line_end + 1)
          process_line(line)
        end
      else
        -- EOF
        if #buffer > 0 then
          local line = buffer:gsub("\r$", "")
          process_line(line)
        end
        if stdout then
          stdout:read_stop()
          stdout:close()
        end
        stdout_closed = true
        on_finish()
      end
    end)
  end

  -- Also read stderr to prevent buffer blocking, but ignore output
  if stderr then
    uv.read_start(stderr, function(err, data)
      if not data then
        if stderr then
          stderr:read_stop()
          stderr:close()
        end
      end
    end)
  end
end

local function scan_tree_async_lua(root, callback, on_progress)
  root = normalize_path(root)

  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}
  local is_win = utils.is_windows()

  local ignore_dirs_lower = {}
  if is_win then
    for _, dir in ipairs(ignore_dirs) do
      table.insert(ignore_dirs_lower, dir:lower())
    end
  end

  local gitignore_matcher, gitignore_mod = get_cached_gitignore(root)

  local out_map = {}
  local files_scanned = 0
  local dir_queue = { root }

  local function should_skip_dir(name, fullpath)
    -- Use O(1) cached lookup when available
    if config._ignore_dirs_set then
      if config._ignore_dirs_set[name:lower()] then
        return true
      end
    else
      local cmp_name = is_win and name:lower() or name
      local dirs_to_check = is_win and ignore_dirs_lower or ignore_dirs
      for _, dir in ipairs(dirs_to_check) do
        if cmp_name == dir then
          return true
        end
      end
    end
    return false
  end

  local function process_single_dir(path)
    local fd = uv.fs_scandir(path)
    if not fd then
      return 0
    end

    local processed = 0

    while true do
      local name, typ = uv.fs_scandir_next(fd)
      if not name then
        break
      end

      local fullpath = normalize_path(path .. "/" .. name)

      if gitignore_matcher and gitignore_mod then
        if gitignore_mod.is_ignored(gitignore_matcher, fullpath, typ == "directory") then
          goto continue
        end
      end

      if typ == "directory" then
        if not should_skip_dir(name, fullpath) then
          table.insert(dir_queue, fullpath)
        end
      elseif typ == "file" then
        if should_watch_path(fullpath, ignore_dirs, watch_extensions) then
          local st = uv.fs_stat(fullpath)
          if st then
            out_map[fullpath] = {
              mtime = mtime_ns(st),
              size = st.size,
              ino = st.ino,
              dev = st.dev,
            }
            processed = processed + 1
          end
        end
      end

      ::continue::
    end

    return processed
  end

  local dir_idx = 1

  local function process_chunk()
    if not scanning_in_progress[root] then
      return
    end

    local chunk_files = 0
    local dirs_this_chunk = 0
    local MAX_DIRS_PER_CHUNK = 50
    local CHUNK_SIZE = 2000

    while dir_idx <= #dir_queue and dirs_this_chunk < MAX_DIRS_PER_CHUNK and chunk_files < CHUNK_SIZE do
      local dir = dir_queue[dir_idx]
      dir_idx = dir_idx + 1

      local processed = process_single_dir(dir)
      chunk_files = chunk_files + processed
      files_scanned = files_scanned + processed
      dirs_this_chunk = dirs_this_chunk + 1
    end

    if on_progress then
      pcall(on_progress, files_scanned)
    end

    if dir_idx <= #dir_queue then
      vim.defer_fn(process_chunk, 0)
    else
      scanning_in_progress[root] = nil
      if callback then
        vim.schedule(function()
          pcall(callback, out_map)
        end)
      end
    end
  end

  vim.defer_fn(process_chunk, 0)
end

function M.scan_tree_async(root, callback, on_progress)
  root = normalize_path(root)

  if scanning_in_progress[root] then
    return
  end
  scanning_in_progress[root] = true

  -- Try Rust module first — call directly on main thread (fast native code)
  local ok, rs = check_rust_module()
  if ok and rs then
    -- Call Rust directly — no serialization round-trip, no uv.new_work overhead
    -- The Rust module is fast enough to run synchronously without blocking UI
    -- because it now filters by extensions/ignore_dirs, reducing work dramatically
    local result = call_rust_snapshot(rs, root)
    if result then
      scanning_in_progress[root] = nil
      vim.schedule(function()
        pcall(callback, result)
      end)
      return
    end
    -- Fall through to fd/lua if Rust call failed
  end

  local fd_exe = nil
  if vim.fn.executable("fd") == 1 then
    fd_exe = "fd"
  elseif vim.fn.executable("fdfind") == 1 then
    fd_exe = "fdfind"
  end

  if fd_exe then
    scan_tree_async_fd(fd_exe, root, callback, on_progress)
  else
    scan_tree_async_lua(root, callback, on_progress)
  end
end

function M.scan_tree(root, out_map)
  root = normalize_path(root)

  -- Try Rust module — now with proper filtering and nanosecond precision
  local ok, rs = check_rust_module()
  if ok and rs then
    local result = call_rust_snapshot(rs, root)
    if result then
      for k, v in pairs(result) do
        out_map[k] = v
      end
      return
    end
  end

  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}
  local is_win = utils.is_windows()

  local ignore_dirs_lower = {}
  if is_win then
    for _, dir in ipairs(ignore_dirs) do
      table.insert(ignore_dirs_lower, dir:lower())
    end
  end

  local gitignore_matcher, gitignore_mod = get_cached_gitignore(root)

  local stack = { root }
  while #stack > 0 do
    local path = table.remove(stack)
    local fd = uv.fs_scandir(path)
    if fd then
      while true do
        local name, typ = uv.fs_scandir_next(fd)
        if not name then
          break
        end

        local fullpath = normalize_path(path .. "/" .. name)

        if gitignore_matcher and gitignore_mod then
          if gitignore_mod.is_ignored(gitignore_matcher, fullpath, typ == "directory") then
            goto continue
          end
        end

        if typ == "directory" then
          local skip = false
          if config._ignore_dirs_set then
            skip = config._ignore_dirs_set[name:lower()] == true
          else
            local cmp_name = is_win and name:lower() or name
            local dirs_to_check = is_win and ignore_dirs_lower or ignore_dirs
            for _, dir in ipairs(dirs_to_check) do
              if cmp_name == dir then
                skip = true
                break
              end
            end
          end

          if not skip then
            table.insert(stack, fullpath)
          end
        elseif typ == "file" then
          if should_watch_path(fullpath, ignore_dirs, watch_extensions) then
            local st = uv.fs_stat(fullpath)
            if st then
              out_map[fullpath] = {
                mtime = mtime_ns(st),
                size = st.size,
                ino = st.ino,
                dev = st.dev,
              }
            end
          end
        end

        ::continue::
      end
    end
  end
end

function M.partial_scan(dirs, existing_map, root)
  if not dirs or #dirs == 0 then
    return
  end

  root = normalize_path(root)
  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}

  local gitignore_matcher, gitignore_mod = get_cached_gitignore(root)

  for _, dir in ipairs(dirs) do
    local normalized_dir = normalize_path(dir)
    local prefix = normalized_dir .. "/"
    local to_remove = {}
    for path in pairs(existing_map) do
      if path == normalized_dir or path:sub(1, #prefix) == prefix then
        table.insert(to_remove, path)
      end
    end
    for _, path in ipairs(to_remove) do
      existing_map[path] = nil
    end
  end

  for _, dir in ipairs(dirs) do
    local normalized_dir = normalize_path(dir)
    local stat = uv.fs_stat(normalized_dir)
    if stat and stat.type == "directory" then
      local fd = uv.fs_scandir(normalized_dir)
      if fd then
        while true do
          local name, typ = uv.fs_scandir_next(fd)
          if not name then
            break
          end

          local fullpath = normalize_path(normalized_dir .. "/" .. name)

          if gitignore_matcher and gitignore_mod then
            if gitignore_mod.is_ignored(gitignore_matcher, fullpath, typ == "directory") then
              goto continue
            end
          end

          if typ == "file" then
            if should_watch_path(fullpath, ignore_dirs, watch_extensions) then
              local st = uv.fs_stat(fullpath)
              if st then
                existing_map[fullpath] = {
                  mtime = mtime_ns(st),
                  size = st.size,
                  ino = st.ino,
                  dev = st.dev,
                }
              end
            end
          end

          ::continue::
        end
      end
    end
  end
end

function M.partial_scan_async(dirs, existing_map, root, callback)
  if not dirs or #dirs == 0 then
    if callback then
      vim.schedule(function()
        callback(existing_map)
      end)
    end
    return
  end

  root = normalize_path(root)
  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}

  local gitignore_matcher, gitignore_mod = get_cached_gitignore(root)

  for _, dir in ipairs(dirs) do
    local normalized_dir = normalize_path(dir)
    local prefix = normalized_dir .. "/"
    local to_remove = {}
    for path in pairs(existing_map) do
      if path == normalized_dir or path:sub(1, #prefix) == prefix then
        table.insert(to_remove, path)
      end
    end
    for _, path in ipairs(to_remove) do
      existing_map[path] = nil
    end
  end

  local files_to_stat = {}
  local dirs_processed = 0
  local total_dirs = #dirs

  local function stat_files_async()
    if #files_to_stat == 0 then
      vim.schedule(function()
        if callback then
          callback(existing_map)
        end
      end)
      return
    end

    local pending = #files_to_stat
    local completed = 0
    local CHUNK = 20
    local idx = 1

    local function stat_chunk()
      local chunk_end = math.min(idx + CHUNK - 1, pending)

      for i = idx, chunk_end do
        uv.fs_stat(files_to_stat[i], function(err, st)
          if not err and st then
            existing_map[files_to_stat[i]] = {
              mtime = mtime_ns(st),
              size = st.size,
              ino = st.ino,
              dev = st.dev,
            }
          end
          completed = completed + 1

          if completed == pending then
            vim.schedule(function()
              if callback then
                callback(existing_map)
              end
            end)
          elseif i == chunk_end and idx + CHUNK <= pending then
            idx = chunk_end + 1
            vim.defer_fn(stat_chunk, 0)
          end
        end)
      end
    end

    stat_chunk()
  end

  local function scan_next_dir()
    if dirs_processed >= total_dirs then
      stat_files_async()
      return
    end

    local dir = dirs[dirs_processed + 1]
    dirs_processed = dirs_processed + 1

    uv.fs_scandir(dir, function(err, scanner)
      if err or not scanner then
        vim.defer_fn(scan_next_dir, 0)
        return
      end

      while true do
        local name, typ = uv.fs_scandir_next(scanner)
        if not name then
          break
        end

        local fullpath = normalize_path(dir .. "/" .. name)

        if gitignore_matcher and gitignore_mod then
          if gitignore_mod.is_ignored(gitignore_matcher, fullpath, typ == "directory") then
            goto continue
          end
        end

        if typ == "file" then
          if should_watch_path(fullpath, ignore_dirs, watch_extensions) then
            table.insert(files_to_stat, fullpath)
          end
        end

        ::continue::
      end

      vim.defer_fn(scan_next_dir, 0)
    end)
  end

  scan_next_dir()
end

function M.resync_snapshot_for(client_id, root, snapshots, helpers)
  if not root then
    return
  end

  root = normalize_path(root)

  M.scan_tree_async(root, function(new_map)
    local old_map = snapshots[client_id] or {}
    local evs = {}

    for path, mt in pairs(new_map) do
      local old_mt = old_map[path]
      if not old_mt then
        table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
      elseif old_mt.mtime ~= mt.mtime or old_mt.size ~= mt.size then
        table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
      end
    end

    for path in pairs(old_map) do
      if not new_map[path] then
        table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
      end
    end

    snapshots[client_id] = new_map

    if #evs > 0 and helpers.queue_events then
      pcall(helpers.queue_events, client_id, evs)
    end

    if helpers.last_events then
      helpers.last_events[client_id] = os.time()
    end
  end)
end

return M
