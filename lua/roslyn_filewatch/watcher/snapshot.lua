---@class roslyn_filewatch.snapshot
---@field scan_tree fun(root: string, out_map: table<string, roslyn_filewatch.SnapshotEntry>)
---@field resync_snapshot_for fun(client_id: number, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, helpers: roslyn_filewatch.Helpers)

---@class roslyn_filewatch.Helpers
---@field notify fun(msg: string, level?: number)
---@field notify_roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])
---@field queue_events fun(client_id: number, evs: roslyn_filewatch.FileChange[])
---@field close_deleted_buffers fun(path: string)
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

--- Async directory scan that yields to event loop periodically
--- This prevents UI freezes during large scans (Unity regeneration)
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
				if helpers.close_deleted_buffers then
					pcall(helpers.close_deleted_buffers, path)
				end
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
