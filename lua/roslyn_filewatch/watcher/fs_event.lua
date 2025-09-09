local uv = vim.uv or vim.loop

local M = {}

-- start(client, root, snapshots, opts) -> (handle, err)
-- opts (table):
--   config
--   rename_mod
--   snapshot_mod
--   notify
--   notify_roslyn_renames
--   queue_events
--   close_deleted_buffers
--   restart_watcher
--   mtime_ns
--   identity_from_stat
--   same_file_info
--   normalize_path
--   last_events
--   rename_window_ms
function M.start(client, root, snapshots, opts)
	opts = opts or {}
	local config = opts.config
	local rename_mod = opts.rename_mod
	local snapshot_mod = opts.snapshot_mod
	local notify = opts.notify or function() end
	local notify_roslyn_renames = opts.notify_roslyn_renames or function() end
	local queue_events = opts.queue_events or function() end
	local close_deleted_buffers = opts.close_deleted_buffers or function() end
	local restart_watcher = opts.restart_watcher or function() end
	local mtime_ns = opts.mtime_ns
	local identity_from_stat = opts.identity_from_stat
	local same_file_info = opts.same_file_info
	local normalize_path = opts.normalize_path or function(p)
		return p
	end
	local last_events = opts.last_events or {}
	local RENAME_WINDOW_MS = opts.rename_window_ms or 300

	if not client or not client.id then
		return nil, "invalid client"
	end

	local handle, err = uv.new_fs_event()
	if not handle then
		return nil, err or "failed creating fs_event handle"
	end

	local ok, start_err = pcall(function()
		handle:start(root, { recursive = true }, function(err2, filename, events)
			if err2 then
				notify("Watcher error: " .. tostring(err2), vim.log.levels.ERROR)
				if snapshot_mod and snapshot_mod.resync_snapshot_for then
					pcall(snapshot_mod.resync_snapshot_for, client.id, root, snapshots, {
						notify = notify,
						notify_roslyn_renames = notify_roslyn_renames,
						queue_events = queue_events,
						close_deleted_buffers = close_deleted_buffers,
						restart_watcher = restart_watcher,
						last_events = last_events,
					})
				end
				restart_watcher()
				return
			end

			if not filename then
				notify("fs_event filename=nil -> resync + restart", vim.log.levels.DEBUG)
				if snapshot_mod and snapshot_mod.resync_snapshot_for then
					pcall(snapshot_mod.resync_snapshot_for, client.id, root, snapshots, {
						notify = notify,
						notify_roslyn_renames = notify_roslyn_renames,
						queue_events = queue_events,
						close_deleted_buffers = close_deleted_buffers,
						restart_watcher = restart_watcher,
						last_events = last_events,
					})
				end
				restart_watcher()
				return
			end

			-- normalize incoming path
			local fullpath = normalize_path(root .. "/" .. filename)
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

			-- update last event timestamp
			last_events[client.id] = os.time()

			-- If the path is not a watched file (e.g. it is a directory event),
			-- check snapshot for entries under that directory -> treat them as deletes.
			if not should_watch_path(fullpath) then
				-- find any snapshot entries whose path begins with fullpath + "/"
				local evs = {}
				local prefix = fullpath .. "/"
				local snap = snapshots[client.id] or {}
				local found = false

				for path, _ in pairs(snap) do
					if path == fullpath or path:sub(1, #prefix) == prefix then
						found = true
						-- remove from snapshot
						snapshots[client.id][path] = nil
						-- close buffer if loaded
						pcall(close_deleted_buffers, path)
						table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
					end
				end

				if found then
					notify(
						"Detected directory deletion affecting " .. tostring(#evs) .. " watched file(s): " .. fullpath,
						vim.log.levels.DEBUG
					)
					if #evs > 0 then
						-- send batched delete events to the client
						pcall(function()
							queue_events(client.id, evs)
						end)
					end
					restart_watcher()
				end

				return
			end

			-- the path is a watched file path (extension matches).
			local st = uv.fs_stat(fullpath)
			local evs = {}

			local prev_mt = snapshots[client.id] and snapshots[client.id][fullpath]

			if st then
				-- created or changed
				local mt = mtime_ns and mtime_ns(st) or 0
				local new_entry = { mtime = mt, size = st.size, ino = st.ino, dev = st.dev }

				-- rename detection: try to match buffered deletes via rename_mod (if provided)
				local matched = false
				if rename_mod and rename_mod.on_create and identity_from_stat then
					matched = pcall(function()
						return rename_mod.on_create(client.id, fullpath, st, snapshots, {
							notify = notify,
							notify_roslyn_renames = notify_roslyn_renames,
						})
					end)
					-- pcall returns (ok, result). If ok==true and result==true -> matched
					if type(matched) == "table" then
						matched = matched[1]
					end
				end

				if not matched then
					snapshots[client.id][fullpath] = new_entry
					if not prev_mt then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
					elseif not same_file_info(prev_mt, snapshots[client.id][fullpath]) then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
					end
				end
			else
				-- file no longer exists: buffer the delete via rename_mod if possible,
				-- otherwise act as immediate delete
				if prev_mt then
					local buffered = false
					if rename_mod and rename_mod.on_delete and identity_from_stat then
						local ok, res = pcall(function()
							return rename_mod.on_delete(client.id, fullpath, prev_mt, snapshots, {
								queue_events = queue_events,
								close_deleted_buffers = close_deleted_buffers,
								notify = notify,
								rename_window_ms = RENAME_WINDOW_MS,
							})
						end)
						if ok then
							buffered = res == true
						else
							buffered = false
						end
					end

					if not buffered then
						snapshots[client.id][fullpath] = nil
						pcall(close_deleted_buffers, fullpath)
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
						restart_watcher()
					end
				end
			end

			if #evs > 0 then
				pcall(function()
					queue_events(client.id, evs)
				end)
			end
		end)
	end)

	if not ok then
		-- failed to start; ensure handle is closed if allocated
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
