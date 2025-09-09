local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

local M = {}

-- Start a fs_event watcher for `client` at `root`.
-- Returns: handle on success, or nil, err on failure.
--
-- `snapshots` is the shared snapshots table (from watcher.lua).
-- `deps` is a table containing required helper functions / modules:
--   deps.rename_mod, deps.snapshot_mod, deps.notify, deps.notify_roslyn_renames,
--   deps.queue_events, deps.close_deleted_buffers, deps.restart_watcher,
--   deps.mtime_ns, deps.identity_from_stat, deps.same_file_info,
--   deps.normalize_path, deps.last_events, deps.rename_window_ms
function M.start(client, root, snapshots, deps)
	if not deps then
		return nil, "missing deps"
	end

	local handle, err = uv.new_fs_event()
	if not handle then
		return nil, err
	end

	local ok, start_err = pcall(function()
		handle:start(root, { recursive = true }, function(err2, filename, events)
			-- error handling: resync & restart
			if err2 then
				deps.notify("Watcher error: " .. tostring(err2), vim.log.levels.ERROR)
				deps.snapshot_mod.resync_snapshot_for(client.id, root, snapshots, deps)
				deps.restart_watcher()
				return
			end

			if not filename then
				deps.notify("fs_event filename=nil -> resync + restart", vim.log.levels.DEBUG)
				deps.snapshot_mod.resync_snapshot_for(client.id, root, snapshots, deps)
				deps.restart_watcher()
				return
			end

			local fullpath = deps.normalize_path(root .. "/" .. filename)

			-- Should we watch this path?
			local function should_watch_path(p)
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

			if not should_watch_path(fullpath) then
				return
			end

			-- record last event time
			if deps.last_events then
				deps.last_events[client.id] = os.time()
			end

			local st = uv.fs_stat(fullpath)
			local evs = {}

			-- compare against snapshot entry
			local prev_mt = snapshots[client.id] and snapshots[client.id][fullpath]
			if st then
				-- created or changed
				local mt = deps.mtime_ns(st)
				local new_entry = { mtime = mt, size = st.size, ino = st.ino, dev = st.dev }

				-- try rename detection via rename_mod
				local matched = false
				if deps.rename_mod then
					matched = deps.rename_mod.on_create(client.id, fullpath, st, snapshots, {
						notify = deps.notify,
						notify_roslyn_renames = deps.notify_roslyn_renames,
					})
				end

				if not matched then
					-- normal create/change handling
					snapshots[client.id][fullpath] = new_entry
					if not prev_mt then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
					elseif not deps.same_file_info(prev_mt, snapshots[client.id][fullpath]) then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
					end
				end
			else
				-- path disappeared -> consider buffering delete for rename matching
				if prev_mt then
					local buffered = false
					if deps.rename_mod then
						buffered = deps.rename_mod.on_delete(client.id, fullpath, prev_mt, snapshots, {
							queue_events = deps.queue_events,
							close_deleted_buffers = deps.close_deleted_buffers,
							notify = deps.notify,
							rename_window_ms = deps.rename_window_ms,
						})
					end
					if not buffered then
						-- fallback immediate delete
						if snapshots[client.id] then
							snapshots[client.id][fullpath] = nil
						end
						deps.close_deleted_buffers(fullpath)
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
						deps.restart_watcher()
					end
				end
			end

			if #evs > 0 and deps.queue_events then
				deps.queue_events(client.id, evs)
			end
		end)
	end)

	if not ok then
		-- ensure handle closed when start fails
		pcall(function()
			if handle and handle.close then
				handle:close()
			end
		end)
		return nil, start_err
	end

	return handle
end

return M
