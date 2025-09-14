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

-- error/resync throttle knobs
local ERROR_WINDOW_SEC = 2
local ERROR_THRESHOLD = 2
local RESYNC_MIN_INTERVAL_SEC = 2

local error_counters = {} -- client_id -> { count = n, since = ts }
local last_resync_ts = {} -- client_id -> ts

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

local function record_error_and_maybe_escalate(client_id, msg, notify, resync_fn, restart_fn)
	local now = os.time()
	local ec = error_counters[client_id] or { count = 0, since = now }
	if now - (ec.since or 0) > ERROR_WINDOW_SEC then
		ec.count = 0
		ec.since = now
	end
	ec.count = ec.count + 1
	ec.since = ec.since or now
	error_counters[client_id] = ec

	local looks_like_perm = (msg and (msg:match("EPERM") or msg:lower():match("permission"))) and true or false

	if looks_like_perm then
		if ec.count >= ERROR_THRESHOLD then
			pcall(function()
				notify(
					"Persistent permission/EPERM errors from fs_event; resyncing and restarting watcher",
					vim.log.levels.ERROR
				)
			end)
			error_counters[client_id] = nil
			-- escalate (do resync+restart with fs_event disabled)
			vim.defer_fn(function()
				if resync_fn then
					pcall(resync_fn)
				end
				if restart_fn then
					pcall(function()
						restart_fn("EPERM_escalated", 1200, true)
					end)
				end
			end, 50)
			return true
		else
			pcall(function()
				notify(
					"fs_event permission error (will escalate on repeated occurrences): " .. tostring(msg),
					vim.log.levels.WARN
				)
			end)
			return false
		end
	else
		pcall(function()
			notify("fs_event callback error (non-EPERM): " .. tostring(msg), vim.log.levels.ERROR)
		end)
		return false
	end
end

local function may_resync_due_to_nil_filename(client_id, notify, resync_fn, restart_fn)
	local now = os.time()
	local last = last_resync_ts[client_id] or 0
	if now - last < RESYNC_MIN_INTERVAL_SEC then
		pcall(function()
			notify("Skipping frequent resync (recently resynced)", vim.log.levels.DEBUG)
		end)
		return false
	end
	last_resync_ts[client_id] = now
	vim.defer_fn(function()
		pcall(function()
			notify("fs_event filename=nil -> resync + restart", vim.log.levels.DEBUG)
		end)
		if resync_fn then
			pcall(resync_fn)
		end
		if restart_fn then
			pcall(function()
				restart_fn("filename_nil", 800)
			end)
		end
	end, 50)
	return true
end

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
		buf.map = {}

		if buf.timer then
			local_stop_close(buf.timer)
			buf.timer = nil
		end

		local evs = {}
		for _, fullpath in ipairs(paths) do
			if not should_watch_path(fullpath, config) then
				goto continue_path
			end

			local prev_mt = snapshots[client.id] and snapshots[client.id][fullpath]
			local ok_st, st = pcall(function()
				return uv.fs_stat(fullpath)
			end)

			if ok_st and st then
				local mt = (mtime_ns and mtime_ns(st)) or ((st.mtime and st.mtime.sec and st.mtime.sec * 1e9) or 0)
				local new_entry = { mtime = mt, size = st.size, ino = st.ino, dev = st.dev }

				local matched = false
				if rename_mod and rename_mod.on_create then
					local ok, res = pcall(rename_mod.on_create, client.id, fullpath, st, snapshots, {
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
					snapshots[client.id] = snapshots[client.id] or {}
					snapshots[client.id][fullpath] = new_entry
					if not prev_mt then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
					elseif not same_file_info(prev_mt, snapshots[client.id][fullpath]) then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
					end
				end
			else
				-- missing -> possible delete
				if prev_mt then
					local buffered = false
					if rename_mod and rename_mod.on_delete then
						local ok, res = pcall(rename_mod.on_delete, client.id, fullpath, prev_mt, snapshots, {
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
						if snapshots[client.id] then
							snapshots[client.id][fullpath] = nil
						end
						pcall(close_deleted_buffers, fullpath)
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
					end
				end
			end

			::continue_path::
		end

		if #evs > 0 then
			pcall(queue_events, client.id, evs)
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

	-- start the fs_event watch with a fully protected callback
	local ok_start, start_err = pcall(function()
		handle:start(root, { recursive = true }, function(err2, filename, events)
			-- wrap entire callback to ensure nothing bubbles
			local ok_cb, cb_err = pcall(function()
				if err2 then
					-- handle libuv-level error (often EPERM on windows dir delete race)
					local msg = tostring(err2)
					-- escalate only after repeated occurrences; on first occurrence log and schedule cleanup/resync
					local escalated = record_error_and_maybe_escalate(client.id, msg, notify, function()
						pcall(function()
							snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
						end)
					end, function()
						-- restart_watcher accepts (reason, delay_ms, disable_fs_event)
						if restart_watcher then
							pcall(function()
								restart_watcher("EPERM", 1200, true)
							end)
						end
					end)

					-- schedule a deferred stop+restart if not escalated (prevents calling stop from inside uv callback directly)
					if not escalated then
						vim.defer_fn(function()
							pcall(function()
								-- stop/close the handle safely
								if handle and handle.stop and not handle:is_closing() then
									pcall(handle.stop, handle)
								end
								if handle and handle.close and not handle:is_closing() then
									pcall(handle.close, handle)
								end
							end)
							-- schedule restart with a small delay and request fs_event disabled for a bit
							if restart_watcher then
								pcall(function()
									restart_watcher("EPERM", 800, true)
								end)
							end
						end, 50)
					end
					return
				end

				-- filename missing: rate-limit resyncs
				if not filename then
					may_resync_due_to_nil_filename(client.id, notify, function()
						pcall(function()
							snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
						end)
					end, function()
						if restart_watcher then
							pcall(function()
								restart_watcher("filename_nil", 800)
							end)
						end
					end)
					return
				end

				local fullpath = normalize_path(root .. "/" .. filename)
				if not should_watch_path(fullpath, config) then
					return
				end

				if last_events then
					last_events[client.id] = os.time()
				end

				event_buffers[client.id] = event_buffers[client.id] or { map = {}, timer = nil }
				event_buffers[client.id].map[fullpath] = true
				schedule_flush(client.id)
			end)

			if not ok_cb then
				local msg = tostring(cb_err)
				record_error_and_maybe_escalate(client.id, msg, notify, function()
					pcall(function()
						snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
					end)
				end, function()
					if restart_watcher then
						pcall(function()
							restart_watcher("callback_error", 800, true)
						end)
					end
				end)
			end
		end)
	end)

	if not ok_start then
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
