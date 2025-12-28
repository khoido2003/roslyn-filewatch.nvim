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

--- Directory scan (for poller snapshot) — writes normalized paths into out_map
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
		end
	end

	scan_dir(root)
end

--- Resync snapshot for a specific client.
--- Compares current filesystem state with stored snapshot and emits appropriate events.
---@param client_id number Numeric id of client
---@param root string Normalized root path
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Shared snapshots table
---@param helpers roslyn_filewatch.Helpers Helper functions
function M.resync_snapshot_for(client_id, root, snapshots, helpers)
	local new_map = {}
	M.scan_tree(root, new_map)

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
		-- If deletes were found, restart to ensure fs_event isn't left in a bad state
		if saw_delete and helpers.restart_watcher then
			pcall(helpers.restart_watcher, "delete_detected")
		end
	end

	-- Replace snapshot
	snapshots[client_id] = new_map
	if helpers.last_events then
		helpers.last_events[client_id] = os.time()
	end
end

return M
