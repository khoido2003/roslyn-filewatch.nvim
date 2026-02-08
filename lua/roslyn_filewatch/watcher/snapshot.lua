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

function M.cancel_async_scan(root)
  scanning_in_progress[normalize_path(root)] = nil
end

function M.is_scanning(root)
  return scanning_in_progress[normalize_path(root)] == true
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
  local collected_paths = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local buffer = ""

  local exit_code = nil
  local stdout_closed = false
  local handle_closed = false

  local function on_finish()
    if not stdout_closed or not handle_closed then
      return
    end

    vim.schedule(function()
      if exit_code ~= 0 and #collected_paths == 0 then
        scanning_in_progress[root] = nil
        if callback then
          callback(out_map)
        end
        return
      end

      if not scanning_in_progress[root] then
        return
      end

      local pending = #collected_paths
      if pending == 0 then
        scanning_in_progress[root] = nil
        if callback then
          callback(out_map)
        end
        return
      end

      local processed = 0
      local BATCH_SIZE = 200
      local current_idx = 1

      local function process_batch()
        if not scanning_in_progress[root] then
          return
        end

        local end_idx = math.min(current_idx + BATCH_SIZE - 1, pending)
        local batch_completed = 0
        local batch_total = end_idx - current_idx + 1

        for i = current_idx, end_idx do
          uv.fs_stat(collected_paths[i], function(err, st)
            if not err and st then
              out_map[collected_paths[i]] = {
                mtime = mtime_ns(st),
                size = st.size,
                ino = st.ino,
                dev = st.dev,
              }
            end

            processed = processed + 1
            batch_completed = batch_completed + 1

            if on_progress and processed % 2000 == 0 then
              vim.schedule(function()
                pcall(on_progress, processed)
              end)
            end

            if batch_completed == batch_total then
              current_idx = end_idx + 1
              if current_idx <= pending then
                vim.defer_fn(process_batch, 5)
              else
                scanning_in_progress[root] = nil
                vim.schedule(function()
                  if callback then
                    callback(out_map)
                  end
                end)
              end
            end
          end)
        end
      end

      process_batch()
    end)
  end

  local handle
  handle = uv.spawn(fd_exe, {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code)
    exit_code = code
    handle:close()
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

  uv.read_start(stdout, function(err, data)
    if err then
      stdout:read_stop()
      stdout:close()
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

        if #line > 0 then
          table.insert(collected_paths, normalize_path(line))
        end
      end
    else
      -- EOF
      if #buffer > 0 then
        local line = buffer:gsub("\r$", "")
        if #line > 0 then
          table.insert(collected_paths, normalize_path(line))
        end
      end
      stdout:read_stop()
      stdout:close()
      stdout_closed = true
      on_finish()
    end
  end)

  -- Also read stderr to prevent buffer blocking, but ignore output
  uv.read_start(stderr, function(err, data)
    if not data then
      stderr:read_stop()
      stderr:close()
    end
  end)
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

  local gitignore_mod = nil
  local gitignore_matcher = nil
  if config.options.respect_gitignore ~= false then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
    if ok and mod then
      gitignore_mod = mod
      gitignore_matcher = mod.load(root)
    end
  end

  local out_map = {}
  local files_scanned = 0
  local dir_queue = { root }

  local function should_skip_dir(name, fullpath)
    local cmp_name = is_win and name:lower() or name
    local cmp_fullpath = is_win and fullpath:lower() or fullpath
    local dirs_to_check = is_win and ignore_dirs_lower or ignore_dirs

    for _, dir in ipairs(dirs_to_check) do
      if cmp_name == dir then
        return true
      end
      if cmp_fullpath:find("/" .. dir .. "/", 1, true) or cmp_fullpath:match("/" .. dir .. "$") then
        return true
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

  local function process_chunk()
    if not scanning_in_progress[root] then
      return
    end

    local chunk_files = 0
    local dirs_this_chunk = 0
    local MAX_DIRS_PER_CHUNK = 5
    local CHUNK_SIZE = 30

    while #dir_queue > 0 and dirs_this_chunk < MAX_DIRS_PER_CHUNK and chunk_files < CHUNK_SIZE do
      local dir = table.remove(dir_queue, 1)
      local processed = process_single_dir(dir)
      chunk_files = chunk_files + processed
      files_scanned = files_scanned + processed
      dirs_this_chunk = dirs_this_chunk + 1
    end

    if on_progress then
      pcall(on_progress, files_scanned)
    end

    if #dir_queue > 0 then
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

  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}
  local is_win = utils.is_windows()

  local ignore_dirs_lower = {}
  if is_win then
    for _, dir in ipairs(ignore_dirs) do
      table.insert(ignore_dirs_lower, dir:lower())
    end
  end

  local gitignore_mod = nil
  local gitignore_matcher = nil
  if config.options.respect_gitignore ~= false then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
    if ok and mod then
      gitignore_mod = mod
      gitignore_matcher = mod.load(root)
    end
  end

  local function scan_dir(path)
    local fd = uv.fs_scandir(path)
    if not fd then
      return
    end

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
        local cmp_name = is_win and name:lower() or name
        local cmp_fullpath = is_win and fullpath:lower() or fullpath
        local dirs_to_check = is_win and ignore_dirs_lower or ignore_dirs

        for _, dir in ipairs(dirs_to_check) do
          if cmp_name == dir then
            skip = true
            break
          end
          if cmp_fullpath:find("/" .. dir .. "/", 1, true) or cmp_fullpath:match("/" .. dir .. "$") then
            skip = true
            break
          end
        end

        if not skip then
          scan_dir(fullpath)
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

  scan_dir(root)
end

function M.partial_scan(dirs, existing_map, root)
  if not dirs or #dirs == 0 then
    return
  end

  root = normalize_path(root)
  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}

  local gitignore_mod = nil
  local gitignore_matcher = nil
  if config.options.respect_gitignore ~= false then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
    if ok and mod then
      gitignore_mod = mod
      gitignore_matcher = mod.load(root)
    end
  end

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

  local gitignore_mod = nil
  local gitignore_matcher = nil
  if config.options.respect_gitignore ~= false then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
    if ok and mod then
      gitignore_mod = mod
      gitignore_matcher = mod.load(root)
    end
  end

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
