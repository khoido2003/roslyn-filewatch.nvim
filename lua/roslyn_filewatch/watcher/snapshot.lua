---@class roslyn_filewatch.snapshot
---@field scan_tree fun(root: string, out_map: table<string, roslyn_filewatch.SnapshotEntry>)
---@field resync_snapshot_for fun(client_id: number, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, helpers: roslyn_filewatch.Helpers)

---@class roslyn_filewatch.Helpers
---@field notify fun(msg: string, level?: number)
---@field notify_roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])
---@field queue_events fun(client_id: number, evs: roslyn_filewatch.FileChange[])
---@field close_deleted_buffers? fun(path: string) -- DEPRECATED: no longer used
---@field restart_watcher fun(reason?: string, delay_ms?: number, disable_fs_event?: boolean)
---@field last_events table<number, number>

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

local normalize_path = utils.normalize_path
local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat
local same_file_info = utils.same_file_info
local should_watch_path = utils.should_watch_path

local M = {}

-- Async scanning state per-root to prevent duplicate scans
---@type table<string, boolean>
local scanning_in_progress = {}

-- Chunk size for async scanning (files between yields)
local ASYNC_SCAN_CHUNK_SIZE = 30

--- Cancel any in-progress async scan for a root
---@param root string
function M.cancel_async_scan(root)
  scanning_in_progress[normalize_path(root)] = nil
end

--- Check if async scan is in progress for a root
---@param root string
---@return boolean
function M.is_scanning(root)
  return scanning_in_progress[normalize_path(root)] == true
end

--- Async directory scan using 'fd' (Sharkdp/fd) for high performance
---@param fd_exe string Path to fd executable
---@param root string Root directory to scan
---@param callback fun(out_map: table<string, roslyn_filewatch.SnapshotEntry>)
---@param on_progress? fun(scanned: number)
local function scan_tree_async_fd(fd_exe, root, callback, on_progress)
  root = normalize_path(root)
  local args = { "--type", "f", "--color", "never", "--absolute-path" }

  -- Handle gitignore
  if config.options.respect_gitignore == false then
    table.insert(args, "--no-ignore")
    table.insert(args, "--hidden")
  end

  -- Add excludes
  for _, dir in ipairs(config.options.ignore_dirs or {}) do
    table.insert(args, "--exclude")
    table.insert(args, dir)
  end

  -- Add ignore patterns
  for _, pattern in ipairs(config.options.ignore_patterns or {}) do
    table.insert(args, "--exclude")
    table.insert(args, pattern)
  end

  -- Add extensions
  for _, ext in ipairs(config.options.watch_extensions or {}) do
    local e = ext:gsub("^%.", "")
    table.insert(args, "--extension")
    table.insert(args, e)
  end

  -- Path arguments
  -- NOTE: fd accepts [pattern] [path]. We want to match all files in root.
  -- Passing "." as pattern matches everything.
  -- But passing just root is enough if we rely on --type f
  table.insert(args, root)

  local out_map = {}
  local collected_paths = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local buffer = ""

  local handle, pid
  handle, pid = uv.spawn(fd_exe, {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code, signal)
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    handle:close()

    -- Process collected paths asynchronously using stat
    vim.schedule(function()
      -- If fd failed, fallback to empty map or partial results
      if code ~= 0 then
        -- Fallback logic could go here, but for now just process what we got
        if #collected_paths == 0 then
          if callback then
            callback(out_map)
          end
          return
        end
      end

      -- Check if scan was cancelled during fd execution
      if not scanning_in_progress[root] then
        return
      end

      -- Stat all collected files in PARALLEL batches
      -- Libuv thread pool defaults to 4, but we can queue more to keep it busy
      local pending = #collected_paths
      local processed = 0
      -- OPTIMIZATION: Reduce batch size to prevent thread pool saturation
      local BATCH_SIZE = 50
      local current_idx = 1

      if pending == 0 then
        scanning_in_progress[root] = nil
        if callback then
          callback(out_map)
        end
        return
      end

      local function process_batch()
        -- Check cancellation
        if not scanning_in_progress[root] then
          return
        end

        local end_idx = math.min(current_idx + BATCH_SIZE - 1, pending)
        local batch_completed = 0
        local batch_total = end_idx - current_idx + 1

        -- Launch stats in parallel for this batch
        for i = current_idx, end_idx do
          local fullpath = collected_paths[i]
          uv.fs_stat(fullpath, function(err, st)
            if not err and st then
              out_map[fullpath] = {
                mtime = mtime_ns(st),
                size = st.size,
                ino = st.ino,
                dev = st.dev,
              }
            end

            processed = processed + 1
            batch_completed = batch_completed + 1

            -- Report progress occasionally
            if on_progress and processed % 2000 == 0 then
              vim.schedule(function()
                pcall(on_progress, processed)
              end)
            end

            -- When batch finishes, schedule next batch
            if batch_completed == batch_total then
              current_idx = end_idx + 1
              if current_idx <= pending then
                -- Yield to avoid starving main loop, then next batch
                -- OPTIMIZATION: Increase yield time to 12ms to let UI breathe
                vim.defer_fn(process_batch, 12)
              else
                -- All done
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
  end)

  if not handle then
    -- Failed to spawn, cleanup
    scanning_in_progress[root] = nil
    if stdout then
      stdout:close()
    end
    if stderr then
      stderr:close()
    end
    return
  end

  -- Read stdout
  uv.read_start(stdout, function(err, data)
    if err or not data then
      return
    end
    buffer = buffer .. data

    while true do
      local line_end = buffer:find("\n")
      if not line_end then
        break
      end

      local line = buffer:sub(1, line_end - 1):gsub("\r$", "")
      buffer = buffer:sub(line_end + 1)

      if #line > 0 then
        local fullpath = normalize_path(line)
        table.insert(collected_paths, fullpath)
      end
    end
  end)
end

--- Standard Lua-based async directory scan (fallback)
---@param root string Root directory to scan
---@param callback fun(out_map: table<string, roslyn_filewatch.SnapshotEntry>) Called when scan completes
---@param on_progress? fun(scanned: number) Optional progress callback
local function scan_tree_async_lua(root, callback, on_progress)
  root = normalize_path(root)

  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}
  local is_win = utils.is_windows()

  -- Pre-compute lowercase ignore dirs on Windows
  local ignore_dirs_lower = {}
  if is_win then
    for _, dir in ipairs(ignore_dirs) do
      table.insert(ignore_dirs_lower, dir:lower())
    end
  end

  -- Cache gitignore module and matcher
  local gitignore_mod = nil
  local gitignore_matcher = nil
  if config.options.respect_gitignore ~= false then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
    if ok and mod then
      gitignore_mod = mod
      gitignore_matcher = mod.load(root)
    end
  end

  ---@type table<string, roslyn_filewatch.SnapshotEntry>
  local out_map = {}
  local files_scanned = 0

  -- Queue of directories to scan (breadth-first to allow chunking)
  ---@type string[]
  local dir_queue = {}

  -- Determine starting directories based on solution-aware setting
  if config.options.solution_aware then
    local ok, sln_parser = pcall(require, "roslyn_filewatch.watcher.sln_parser")
    if ok and sln_parser then
      local project_dirs = sln_parser.get_watch_dirs(root)
      if project_dirs and #project_dirs > 0 then
        for _, project_dir in ipairs(project_dirs) do
          local stat = uv.fs_stat(project_dir)
          if stat and stat.type == "directory" then
            table.insert(dir_queue, project_dir)
          end
        end
      end
    end
  end

  -- Fallback: start from root if no project dirs found
  if #dir_queue == 0 then
    table.insert(dir_queue, root)
  end

  --- Check if directory should be skipped
  ---@param name string Directory name
  ---@param fullpath string Full path
  ---@return boolean
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

  --- Process a single directory (non-recursive, adds subdirs to queue)
  ---@param path string
  ---@return number files_processed Number of files processed in this call
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

      -- Check gitignore
      if gitignore_matcher and gitignore_mod then
        if gitignore_mod.is_ignored(gitignore_matcher, fullpath, typ == "directory") then
          goto continue
        end
      end

      if typ == "directory" then
        if not should_skip_dir(name, fullpath) then
          -- Add to queue for later processing (breadth-first)
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

  --- Process chunk of directories and schedule next chunk
  local function process_chunk()
    -- Check if scan was cancelled
    if not scanning_in_progress[root] then
      return
    end

    local chunk_files = 0
    local dirs_this_chunk = 0
    local MAX_DIRS_PER_CHUNK = 5 -- Process up to 5 directories per chunk

    while #dir_queue > 0 and dirs_this_chunk < MAX_DIRS_PER_CHUNK and chunk_files < ASYNC_SCAN_CHUNK_SIZE do
      local dir = table.remove(dir_queue, 1)
      local processed = process_single_dir(dir)
      chunk_files = chunk_files + processed
      files_scanned = files_scanned + processed
      dirs_this_chunk = dirs_this_chunk + 1
    end

    -- Report progress if callback provided
    if on_progress then
      pcall(on_progress, files_scanned)
    end

    -- Continue or finish
    if #dir_queue > 0 then
      -- More directories to process - yield and continue
      vim.defer_fn(process_chunk, 0)
    else
      -- Done! Clean up and callback
      scanning_in_progress[root] = nil
      if callback then
        vim.schedule(function()
          pcall(callback, out_map)
        end)
      end
    end
  end

  -- Start processing
  vim.defer_fn(process_chunk, 0)
end

--- Async directory scan that yields to event loop periodically
--- Dispatches to 'fd' if available, otherwise uses Lua fallback
---@param root string Root directory to scan
---@param callback fun(out_map: table<string, roslyn_filewatch.SnapshotEntry>) Called when scan completes
---@param on_progress? fun(scanned: number) Optional progress callback
function M.scan_tree_async(root, callback, on_progress)
  root = normalize_path(root)

  -- Prevent duplicate concurrent scans
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

--- Directory scan (for poller snapshot) — writes normalized paths into out_map
--- If solution_aware is enabled, only scans project directories from .sln
---@param root string
---@param out_map table<string, roslyn_filewatch.SnapshotEntry>
function M.scan_tree(root, out_map)
  root = normalize_path(root)

  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}

  -- Cache platform check once before recursion
  local is_win = utils.is_windows()

  -- Pre-compute lowercase ignore dirs on Windows for faster comparisons
  local ignore_dirs_lower = {}
  if is_win then
    for _, dir in ipairs(ignore_dirs) do
      table.insert(ignore_dirs_lower, dir:lower())
    end
  end

  -- Cache gitignore module and matcher outside scan loop (optimization)
  local gitignore_mod = nil
  local gitignore_matcher = nil
  if config.options.respect_gitignore ~= false then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
    if ok and mod then
      gitignore_mod = mod
      gitignore_matcher = mod.load(root)
    end
  end

  ---@param path string
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

      -- Check gitignore first (using cached module)
      if gitignore_matcher and gitignore_mod then
        if gitignore_mod.is_ignored(gitignore_matcher, fullpath, typ == "directory") then
          goto continue
        end
      end

      if typ == "directory" then
        -- Check if this directory should be skipped using exact segment match
        -- Case-insensitive matching on Windows (using pre-computed lowercase)
        local skip = false
        local cmp_name = is_win and name:lower() or name
        local cmp_fullpath = is_win and fullpath:lower() or fullpath
        local dirs_to_check = is_win and ignore_dirs_lower or ignore_dirs

        for _, dir in ipairs(dirs_to_check) do
          -- Check if the current directory name matches exactly
          if cmp_name == dir then
            skip = true
            break
          end
          -- Also check the full path for nested matches
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
            -- store additional fields for rename detection (ino/dev when available)
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

  -- Solution-aware watching: only scan project directories if enabled
  if config.options.solution_aware then
    local ok, sln_parser = pcall(require, "roslyn_filewatch.watcher.sln_parser")
    if ok and sln_parser then
      local project_dirs = sln_parser.get_watch_dirs(root)
      if project_dirs and #project_dirs > 0 then
        -- Scan each project directory
        for _, project_dir in ipairs(project_dirs) do
          -- Verify directory exists before scanning
          local stat = uv.fs_stat(project_dir)
          if stat and stat.type == "directory" then
            scan_dir(project_dir)
          end
        end
        return -- Done with solution-aware scan
      end
    end
  end

  -- Fallback: scan entire root
  scan_dir(root)
end

--- Partial scan: only scan specific directories and merge into existing snapshot
--- Used for incremental updates to avoid full tree rescans
---@param dirs string[] List of directories to scan
---@param existing_map table<string, roslyn_filewatch.SnapshotEntry> Existing snapshot to update
---@param root string Root path (for gitignore context)
function M.partial_scan(dirs, existing_map, root)
  if not dirs or #dirs == 0 then
    return
  end

  root = normalize_path(root)
  local ignore_dirs = config.options.ignore_dirs or {}
  local watch_extensions = config.options.watch_extensions or {}

  -- Cache platform check
  local is_win = utils.is_windows()

  -- Pre-compute lowercase ignore dirs on Windows
  local ignore_dirs_lower = {}
  if is_win then
    for _, dir in ipairs(ignore_dirs) do
      table.insert(ignore_dirs_lower, dir:lower())
    end
  end

  -- Cache gitignore module and matcher outside scan loop (optimization)
  local gitignore_mod = nil
  local gitignore_matcher = nil
  if config.options.respect_gitignore ~= false then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
    if ok and mod then
      gitignore_mod = mod
      gitignore_matcher = mod.load(root)
    end
  end

  -- First, remove all existing entries under the dirty directories
  for _, dir in ipairs(dirs) do
    local normalized_dir = normalize_path(dir)
    local prefix = normalized_dir .. "/"
    local to_remove = {}
    for path, _ in pairs(existing_map) do
      if path == normalized_dir or path:sub(1, #prefix) == prefix then
        table.insert(to_remove, path)
      end
    end
    for _, path in ipairs(to_remove) do
      existing_map[path] = nil
    end
  end

  -- Fast single-level scan (NOT recursive - keeps incremental scan lightweight)
  -- File events mark exact parent directories, so single-level is sufficient
  ---@param path string
  local function scan_single_dir(path)
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

      -- Check gitignore (using cached module)
      if gitignore_matcher and gitignore_mod then
        if gitignore_mod.is_ignored(gitignore_matcher, fullpath, typ == "directory") then
          goto continue
        end
      end

      -- Only process files (not directories - keeping it single-level)
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

  -- Scan each dirty directory (single level for speed)
  for _, dir in ipairs(dirs) do
    local normalized_dir = normalize_path(dir)
    local stat = uv.fs_stat(normalized_dir)
    if stat and stat.type == "directory" then
      scan_single_dir(normalized_dir)
    end
  end
end

--- Async partial scan: scan specific directories asynchronously and merge into existing snapshot
--- Used for incremental updates without blocking the UI during Unity regeneration
---@param dirs string[] List of directories to scan
---@param existing_map table<string, roslyn_filewatch.SnapshotEntry> Existing snapshot to update
---@param root string Root path (for gitignore context)
---@param callback fun(updated_map: table<string, roslyn_filewatch.SnapshotEntry>) Called when scan completes
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

  -- Cache platform check
  local is_win = utils.is_windows()

  -- Pre-compute lowercase ignore dirs on Windows
  local ignore_dirs_lower = {}
  if is_win then
    for _, dir in ipairs(ignore_dirs) do
      table.insert(ignore_dirs_lower, dir:lower())
    end
  end

  -- Cache gitignore module and matcher
  local gitignore_mod = nil
  local gitignore_matcher = nil
  if config.options.respect_gitignore ~= false then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.gitignore")
    if ok and mod then
      gitignore_mod = mod
      gitignore_matcher = mod.load(root)
    end
  end

  -- First, remove all existing entries under the dirty directories (sync - this is fast)
  for _, dir in ipairs(dirs) do
    local normalized_dir = normalize_path(dir)
    local prefix = normalized_dir .. "/"
    local to_remove = {}
    for path, _ in pairs(existing_map) do
      if path == normalized_dir or path:sub(1, #prefix) == prefix then
        table.insert(to_remove, path)
      end
    end
    for _, path in ipairs(to_remove) do
      existing_map[path] = nil
    end
  end

  -- Collect all files to stat asynchronously
  local files_to_stat = {}
  local dirs_processed = 0
  local total_dirs = #dirs

  --- Process a single directory async
  ---@param dir_path string
  ---@param on_dir_done fun()
  local function scan_single_dir_async(dir_path, on_dir_done)
    uv.fs_scandir(dir_path, function(err, scanner)
      if err or not scanner then
        on_dir_done()
        return
      end

      -- Collect entries (fs_scandir_next is fast and synchronous)
      local entries = {}
      while true do
        local name, typ = uv.fs_scandir_next(scanner)
        if not name then
          break
        end
        table.insert(entries, { name = name, typ = typ })
      end

      -- Process entries and collect files to stat
      local local_files = {}
      for _, entry in ipairs(entries) do
        local fullpath = normalize_path(dir_path .. "/" .. entry.name)

        -- Check gitignore
        if gitignore_matcher and gitignore_mod then
          if gitignore_mod.is_ignored(gitignore_matcher, fullpath, entry.typ == "directory") then
            goto continue
          end
        end

        -- Only process files (single-level scan)
        if entry.typ == "file" then
          if should_watch_path(fullpath, ignore_dirs, watch_extensions) then
            table.insert(local_files, fullpath)
          end
        end

        ::continue::
      end

      -- Add to global files list
      for _, f in ipairs(local_files) do
        table.insert(files_to_stat, f)
      end

      on_dir_done()
    end)
  end

  --- Stat all collected files asynchronously in chunks
  local function stat_files_async()
    if #files_to_stat == 0 then
      vim.schedule(function()
        if callback then
          callback(existing_map)
        end
      end)
      return
    end

    local pending_stats = #files_to_stat
    local completed_stats = 0
    local STAT_CHUNK_SIZE = 20
    local current_index = 1

    local function stat_chunk()
      local chunk_end = math.min(current_index + STAT_CHUNK_SIZE - 1, #files_to_stat)

      for i = current_index, chunk_end do
        local fullpath = files_to_stat[i]
        uv.fs_stat(fullpath, function(stat_err, st)
          if not stat_err and st then
            existing_map[fullpath] = {
              mtime = mtime_ns(st),
              size = st.size,
              ino = st.ino,
              dev = st.dev,
            }
          end
          completed_stats = completed_stats + 1

          if completed_stats == pending_stats then
            vim.schedule(function()
              if callback then
                callback(existing_map)
              end
            end)
          end
        end)
      end

      current_index = chunk_end + 1
      if current_index <= #files_to_stat then
        -- Yield between chunks to keep UI responsive
        -- OPTIMIZATION: Increase yield to 5ms (was 1ms)
        vim.defer_fn(stat_chunk, 5)
      end
    end

    stat_chunk()
  end

  -- Process all directories
  local function process_next_dir()
    if dirs_processed >= total_dirs then
      -- All directories scanned, now stat the files
      vim.defer_fn(stat_files_async, 0)
      return
    end

    local dir = dirs[dirs_processed + 1]
    local normalized_dir = normalize_path(dir)

    -- Check if directory exists async
    uv.fs_stat(normalized_dir, function(err, stat)
      if not err and stat and stat.type == "directory" then
        scan_single_dir_async(normalized_dir, function()
          dirs_processed = dirs_processed + 1
          -- Yield between directories
          vim.defer_fn(process_next_dir, 0)
        end)
      else
        dirs_processed = dirs_processed + 1
        vim.defer_fn(process_next_dir, 0)
      end
    end)
  end

  process_next_dir()
end

--- Resync snapshot for a specific client (ASYNC VERSION).
--- Compares current filesystem state with stored snapshot and emits appropriate events.
--- Uses async scanning to prevent UI freezes during large scans (Unity regeneration).
---@param client_id number Numeric id of client
---@param root string Normalized root path
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Shared snapshots table
---@param helpers roslyn_filewatch.Helpers Helper functions
function M.resync_snapshot_for(client_id, root, snapshots, helpers)
  -- Use async scanning to prevent UI freeze
  M.scan_tree_async(root, function(new_map)
    if not snapshots[client_id] then
      snapshots[client_id] = {}
    end

    -- Instead of deepcopy, iterate by reference and track deletions separately
    local old_map = snapshots[client_id]

    ---@type roslyn_filewatch.FileChange[]
    local evs = {}
    local saw_delete = false
    ---@type roslyn_filewatch.RenameEntry[]
    local rename_pairs = {}
    ---@type table<string, boolean>
    local processed_old_paths = {}

    -- Build old identity map for quick lookup
    ---@type table<string, string>
    local old_id_map = {}
    for path, entry in pairs(old_map) do
      local id = identity_from_stat(entry)
      if id then
        old_id_map[id] = path
      end
    end

    -- Detect creates / renames / changes
    for path, mt in pairs(new_map) do
      local old_entry = old_map[path]
      if old_entry == nil then
        -- Possible create OR rename (match by identity)
        local id = identity_from_stat(mt)
        local oldpath = id and old_id_map[id]
        if oldpath then
          -- Rename detected: remember it, mark old path as processed
          table.insert(rename_pairs, { old = oldpath, ["new"] = path })
          processed_old_paths[oldpath] = true
          old_id_map[id] = nil
        else
          table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
        end
      elseif not same_file_info(old_entry, mt) then
        table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
      end
      -- Mark this path as still existing
      processed_old_paths[path] = true
    end

    -- Detect deletes (entries in old_map that aren't in new_map and weren't renamed)
    for path, _ in pairs(old_map) do
      if not processed_old_paths[path] and new_map[path] == nil then
        saw_delete = true

        table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
      end
    end

    -- Send rename notifications first (if any)
    if #rename_pairs > 0 then
      if helpers.notify then
        pcall(helpers.notify, "Resynced and detected " .. #rename_pairs .. " renames", vim.log.levels.DEBUG)
      end
      if helpers.notify_roslyn_renames then
        pcall(helpers.notify_roslyn_renames, rename_pairs)
      end
    end

    if #evs > 0 then
      if helpers.notify then
        pcall(helpers.notify, "Resynced " .. #evs .. " changes from snapshot", vim.log.levels.DEBUG)
      end
      if helpers.queue_events then
        pcall(helpers.queue_events, client_id, evs)
      end
    end

    -- Replace snapshot
    snapshots[client_id] = new_map
    if helpers.last_events then
      helpers.last_events[client_id] = os.time()
    end
  end)
end

return M
