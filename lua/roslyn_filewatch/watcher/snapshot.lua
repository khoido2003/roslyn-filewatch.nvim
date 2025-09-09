local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

local normalize_path = utils.normalize_path
local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat
local same_file_info = utils.same_file_info

local M = {}

-- Directory scan (for poller snapshot) — writes normalized paths into out_map
function M.scan_tree(root, out_map)
	root = normalize_path(root)
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
				local skip = false
				for _, dir in ipairs(config.options.ignore_dirs) do
					-- match "/dir/" or "/dir$" in normalized path
					if fullpath:find("/" .. dir .. "/") or fullpath:find("/" .. dir .. "$") then
						skip = true
						break
					end
				end
				if not skip then
					scan_dir(fullpath)
				end
			elseif typ == "file" then
				local function should_watch(p)
					-- reuse same logic as watcher
					for _, dir in ipairs(config.options.ignore_dirs) do
						if p:find("/" .. dir .. "/") or p:find("/" .. dir .. "$") then
							return false
						end
					end
					for _, ext in ipairs(config.options.watch_extensions) do
						if p:sub(-#ext) == ext then
							return true
						end
					end
					return false
				end

				if should_watch(fullpath) then
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

-- Resync snapshot for a specific client.
--
-- client_id: numeric id of client
-- root: normalized root path
-- snapshots: the shared snapshots table (from watcher.lua) — this function will replace snapshots[client_id]
-- helpers: table with function references required by the logic:
--   helpers.notify(client_id_or_msg?) - (function) for logging: notify(msg, level)
--   helpers.notify_roslyn_renames(files) - (function) to send didRenameFiles
--   helpers.queue_events(client_id, evs) - (function) to enqueue didChangeWatchedFiles events
--   helpers.close_deleted_buffers(path) - (function) to close buffers on delete
--   helpers.restart_watcher() - (function) to schedule a restart when needed
--   helpers.last_events - (table) the last_events table from watcher (so we can set last_events[client_id])
function M.resync_snapshot_for(client_id, root, snapshots, helpers)
	local new_map = {}
	M.scan_tree(root, new_map)

	if not snapshots[client_id] then
		snapshots[client_id] = {}
	end

	local old_map = vim.deepcopy(snapshots[client_id])
	local evs = {}
	local saw_delete = false
	local rename_pairs = {}

	-- build old identity map for quick lookup
	local old_id_map = {}
	for path, entry in pairs(old_map) do
		local id = identity_from_stat(entry)
		if id then
			old_id_map[id] = path
		end
	end

	-- detect creates / renames / changes
	for path, mt in pairs(new_map) do
		if old_map[path] == nil then
			-- possible create OR rename (match by identity)
			local id = identity_from_stat(mt)
			local oldpath = id and old_id_map[id]
			if oldpath then
				-- rename detected: remember it, and remove old_map entry so it won't be treated as delete
				table.insert(rename_pairs, { old = oldpath, ["new"] = path })
				old_map[oldpath] = nil
				old_id_map[id] = nil
			else
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
			end
		elseif not same_file_info(old_map[path], new_map[path]) then
			table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
		end
	end

	-- detect deletes (remaining entries in old_map)
	for path, _ in pairs(old_map) do
		saw_delete = true
		helpers.close_deleted_buffers(path)
		table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
	end

	-- send rename notifications first (if any)
	if #rename_pairs > 0 then
		helpers.notify("Resynced and detected " .. #rename_pairs .. " renames", vim.log.levels.DEBUG)
		helpers.notify_roslyn_renames(rename_pairs)
	end

	if #evs > 0 then
		helpers.notify("Resynced " .. #evs .. " changes from snapshot", vim.log.levels.DEBUG)
		helpers.queue_events(client_id, evs)
		-- if deletes were found, restart to ensure fs_event isn't left in a bad state
		if saw_delete then
			helpers.restart_watcher()
		end
	end

	-- replace snapshot
	snapshots[client_id] = new_map
	if helpers.last_events then
		helpers.last_events[client_id] = os.time()
	end
end

return M
