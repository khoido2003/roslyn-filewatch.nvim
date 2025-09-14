local uv = vim.uv or vim.loop

local M = {}

-- Per-client event buffer: client_id -> { map = { [path]=true }, timer = uv_timer }
local event_buffers = {}

-- stop & close timer safely
local local_stop_close = function(t)
	if not t then
		return
	end
	pcall(function()
		if not t:is_closing() then
			t:stop()
		end
		t:close()
	end)
end

-- default debounce for processing fs_event bursts (ms)
local DEFAULT_PROCESSING_DEBOUNCE_MS = 80

local function should_watch_path(p, cfg)
	for _, dir in ipairs((cfg.options and cfg.options.ignore_dirs) or {}) do
		if p:find("/" .. dir .. "/") or p:find("/" .. dir .. "$") then
			return false
		end
	end
	for _, ext in ipairs((cfg.options and cfg.options.watch_extensions) or {}) do
		if p:sub(-#ext) == ext then
			return true
		end
	end
	return false
end

-- start returns (handle, nil) on success or (nil, err) on failure
function M.start(client, root, snapshots, deps)
	if not client then
		return nil, "missing client"
	end
	if not root then
		return nil, "missing root"
	end
	if not deps then
		return nil, "missing deps"
	end

	local config = deps.config
	local rename_mod = deps.rename_mod
	local snapshot_mod = deps.snapshot_mod
	local notify = deps.notify
	local notify_roslyn_renames = deps.notify_roslyn_renames
	local queue_events = deps.queue_events
	local close_deleted_buffers = deps.close_deleted_buffers
	local restart_watcher = deps.restart_watcher
	local mtime_ns = deps.mtime_ns
	local identity_from_stat = deps.identity_from_stat
	local same_file_info = deps.same_file_info
	local normalize_path = deps.normalize_path
	local last_events = deps.last_events
	local rename_window_ms = deps.rename_window_ms or 300
	local processing_debounce_ms = (config and config.options and config.options.processing_debounce_ms)
		or DEFAULT_PROCESSING_DEBOUNCE_MS

	local helpers = {
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		queue_events = queue_events,
		close_deleted_buffers = close_deleted_buffers,
		restart_watcher = restart_watcher,
		last_events = last_events,
	}

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
		for p, _ in pairs(buf.map) do
			table.insert(paths, p)
		end
		-- clear buffer map immediately to accept new events while processing
		buf.map = {}

		if buf.timer then
			local_stop_close(buf.timer)
			buf.timer = nil
		end

		-- process each path in batch
		local evs = {}

		for _, fullpath in ipairs(paths) do
			if not should_watch_path(fullpath, config) then
				goto continue_path
			end

			local prev_mt = snapshots[client_id] and snapshots[client_id][fullpath]
			local ok_st, st = pcall(function()
				return uv.fs_stat(fullpath)
			end)

			if ok_st and st then
				local mt = (mtime_ns and mtime_ns(st)) or ((st.mtime and st.mtime.sec and st.mtime.sec * 1e9) or 0)
				local new_entry = { mtime = mt, size = st.size, ino = st.ino, dev = st.dev }

				local matched = false
				if rename_mod and rename_mod.on_create then
					local ok, res = pcall(rename_mod.on_create, client_id, fullpath, st, snapshots, {
						notify = notify,
						notify_roslyn_renames = notify_roslyn_renames,
					})
					if not ok then
						pcall(notify, "rename_mod.on_create error: " .. tostring(res), vim.log.levels.ERROR)
					else
						if res then
							matched = true
						end
					end
				end

				if not matched then
					-- normal create/change handling
					snapshots[client_id] = snapshots[client_id] or {}
					snapshots[client_id][fullpath] = new_entry
					if not prev_mt then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 }) -- Created
					elseif not same_file_info(prev_mt, snapshots[client_id][fullpath]) then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 }) -- Changed
					end
				end
			else
				-- file missing: possible delete (or transient)
				if prev_mt then
					-- try rename buffering via rename_mod (if available)
					local buffered = false
					if rename_mod and rename_mod.on_delete then
						local ok, res = pcall(rename_mod.on_delete, client_id, fullpath, prev_mt, snapshots, {
							queue_events = queue_events,
							close_deleted_buffers = close_deleted_buffers,
							notify = notify,
							rename_window_ms = rename_window_ms,
						})
						if not ok then
							pcall(notify, "rename_mod.on_delete error: " .. tostring(res), vim.log.levels.ERROR)
						else
							buffered = res and true or false
						end
					end

					if not buffered then
						-- immediate delete fallback
						if snapshots[client_id] then
							snapshots[client_id][fullpath] = nil
						end
						-- schedule buffer closing safely
						pcall(close_deleted_buffers, fullpath)
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 }) -- Deleted
						-- for safety, restart watcher if a delete happened on fast-path
						pcall(restart_watcher)
					end
				end
			end

			::continue_path::
		end

		if #evs > 0 then
			pcall(queue_events, client_id, evs)
		end
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
			t:start(processing_debounce_ms, 0, function()
				pcall(function()
					flush_client_buffer(client_id)
				end)
			end)
		end
	end

	--  buffer path + schedule flush
	local ok_start, start_err = pcall(function()
		handle:start(root, { recursive = true }, function(err2, filename, events)
			if err2 then
				pcall(notify, "Watcher error: " .. tostring(err2), vim.log.levels.ERROR)
				pcall(function()
					snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
				end)
				pcall(restart_watcher)
				return
			end

			if not filename then
				pcall(notify, "fs_event filename=nil -> resync + restart", vim.log.levels.DEBUG)
				pcall(function()
					snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
				end)
				pcall(restart_watcher)
				return
			end

			local fullpath = normalize_path(root .. "/" .. filename)

			if not should_watch_path(fullpath, config) then
				return
			end

			-- record activity
			if last_events then
				last_events[client.id] = os.time()
			end

			-- add to per-client map and schedule flush
			event_buffers[client.id] = event_buffers[client.id] or { map = {}, timer = nil }
			event_buffers[client.id].map[fullpath] = true
			-- schedule a short debounce flush
			schedule_flush(client.id)
		end)
	end)

	if not ok_start then
		-- start failed: close handle & return error
		if handle and handle.close then
			pcall(function()
				handle:close()
			end)
		end
		return nil, start_err
	end

	return handle, nil
end

return M
