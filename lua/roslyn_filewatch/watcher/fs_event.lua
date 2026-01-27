---@class roslyn_filewatch.fs_event
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, deps: roslyn_filewatch.FsEventDeps): uv_fs_event_t|nil, string|nil
---@field clear fun(client_id: number)

---@class roslyn_filewatch.FsEventDeps
---@field config roslyn_filewatch.config
---@field rename_mod roslyn_filewatch.rename
---@field snapshot_mod roslyn_filewatch.snapshot
---@field notify fun(msg: string, level?: number)
---@field notify_roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])
---@field queue_events fun(client_id: number, evs: roslyn_filewatch.FileChange[])
---@field close_deleted_buffers? fun(path: string) -- DEPRECATED: no longer used
---@field restart_watcher fun(reason?: string, delay_ms?: number, disable_fs_event?: boolean)
---@field mark_dirty_dir fun(client_id: number, path: string)|nil
---@field mtime_ns fun(stat: any): number
---@field identity_from_stat fun(st: any): string|nil
---@field same_file_info fun(a: any, b: any): boolean
---@field normalize_path fun(path: string): string
---@field last_events table<number, number>
---@field rename_window_ms number

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")
local rename_mod = require("roslyn_filewatch.watcher.rename")
local snapshot_mod = require("roslyn_filewatch.watcher.snapshot")
local notify_mod = require("roslyn_filewatch.watcher.notify")

local notify = notify_mod and notify_mod.user or function() end

local M = {}

---@class EventBuffer
---@field map table<string, boolean>
---@field timer uv_timer_t|nil

--- Per-client event buffer
---@type table<number, EventBuffer>
local event_buffers = {}

---@class RawEventQueue
---@field events string[] Raw filenames from fs_event
---@field processing boolean

--- Per-client raw event queue
---@type table<number, RawEventQueue>
local raw_event_queues = {}

--- Stop and close timer safely
---@param t uv_timer_t|nil
local function local_stop_close(t)
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

-- Error/resync throttle knobs
local ERROR_WINDOW_SEC = 2
local ERROR_THRESHOLD = 2
local RESYNC_MIN_INTERVAL_SEC = 2

---@type table<number, { count: number, since: number }>
local error_counters = {}

---@type table<number, number>
local last_resync_ts = {}

--- Clear event buffer for a client
---@param client_id number
function M.clear(client_id)
	local buf = event_buffers[client_id]
	if not buf then
		-- Still clean up error tracking tables even if no buffer
		error_counters[client_id] = nil
		last_resync_ts[client_id] = nil
		return
	end
	if buf.timer then
		pcall(function()
			if not buf.timer:is_closing() then
				buf.timer:stop()
				buf.timer:close()
			end
		end)
		buf.timer = nil
	end
	buf.map = nil
	event_buffers[client_id] = nil

	-- Clear raw queue
	raw_event_queues[client_id] = nil

	-- Clean up error tracking tables to prevent memory leaks
	error_counters[client_id] = nil
	last_resync_ts[client_id] = nil
end

-- Default debounce for processing fs_event bursts (ms)
-- Higher values coalesce more events (better for Unity regeneration)
local DEFAULT_PROCESSING_DEBOUNCE_MS = 300

-- Async flush processing chunk size (files per chunk)
local FLUSH_CHUNK_SIZE = 25
-- Delay between chunks (ms) - allows UI to remain responsive
local FLUSH_CHUNK_DELAY_MS = 5

-- Raw event processing chunk size
local RAW_PROCESS_CHUNK_SIZE = 50
-- Raw event processing delay
local RAW_PROCESS_DELAY_MS = 5

-- Error/resync throttle knobs

--- Check if path should be watched with early extension check for performance
---@param fullpath string Normalized path
---@param cfg roslyn_filewatch.config
---@return boolean
local function should_watch_path(fullpath, cfg)
	local opts = cfg.options
	if not opts then
		return false
	end

	-- Early extension check for performance (avoid full path processing if extension doesn't match)
	local ext = utils.get_extension(fullpath)
	if not ext then
		return false
	end

	local is_win = utils.is_windows()
	local compare_ext = is_win and ext:lower() or ext

	local ext_match = false
	for _, watch_ext in ipairs(opts.watch_extensions or {}) do
		local compare_watch = is_win and watch_ext:lower() or watch_ext
		if compare_ext == compare_watch then
			ext_match = true
			break
		end
	end

	if not ext_match then
		return false
	end

	-- Check ignore dirs using the shared utility function
	return utils.should_watch_path(fullpath, opts.ignore_dirs or {}, opts.watch_extensions or {})
end

--- Record error and maybe escalate to restart
---@param client_id number
---@param msg string
---@param notify_fn fun(msg: string, level: number)
---@param restart_fn fun(reason: string, delay_ms: number, disable_fs_event: boolean)
---@return boolean escalated
local function record_error_and_maybe_escalate(client_id, msg, notify_fn, restart_fn)
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
				notify_fn("Persistent EPERM errors; restarting watcher", vim.log.levels.ERROR)
			end)
			error_counters[client_id] = nil
			vim.defer_fn(function()
				if restart_fn then
					pcall(function()
						restart_fn("EPERM_escalated", 1200, true)
					end)
				end
			end, 50)
			return true
		else
			pcall(function()
				notify_fn("EPERM error (will escalate on repeated): " .. tostring(msg), vim.log.levels.WARN)
			end)
			return false
		end
	else
		pcall(function()
			notify_fn("fs_event error: " .. tostring(msg), vim.log.levels.ERROR)
		end)
		return false
	end
end

---@param client_id number
---@param notify_fn fun(msg: string, level: number)
---@param restart_fn fun(reason: string, delay_ms: number)
---@return boolean restarted
local function may_restart_due_to_nil_filename(client_id, notify_fn, restart_fn)
	local now = os.time()
	local last = last_resync_ts[client_id] or 0
	if now - last < RESYNC_MIN_INTERVAL_SEC then
		pcall(function()
			notify_fn("Skipping frequent restart (recently restarted)", vim.log.levels.DEBUG)
		end)
		return false
	end
	last_resync_ts[client_id] = now
	vim.defer_fn(function()
		pcall(function()
			notify_fn("fs_event filename=nil -> restart", vim.log.levels.DEBUG)
		end)
		if restart_fn then
			pcall(function()
				restart_fn("filename_nil", 800)
			end)
		end
	end, 50)
	return true
end

--- Schedule processing of raw events for a client
---@param client_id number
---@param root string
---@param cfg roslyn_filewatch.config
---@param schedule_flush_fn fun(client_id: number)
local function schedule_raw_processing(client_id, root, cfg, schedule_flush_fn)
	local q = raw_event_queues[client_id]
	if not q or q.processing then
		return
	end

	-- If queue is empty, nothing to do
	if #q.events == 0 then
		return
	end

	q.processing = true

	local function process_next_chunk()
		local q_next = raw_event_queues[client_id]
		-- Client might have been cleared
		if not q_next then
			return
		end

		local chunk_size = math.min(#q_next.events, RAW_PROCESS_CHUNK_SIZE)
		if chunk_size == 0 then
			q_next.processing = false
			return
		end

		local chunk = {}
		for _ = 1, chunk_size do
			table.insert(chunk, table.remove(q_next.events, 1))
		end

		-- Process the chunk synchronously
		local added_any = false
		for _, filename in ipairs(chunk) do
			if filename then
				-- Expensive string ops happen here, spread out over time
				local fullpath = utils.normalize_path(root .. "/" .. filename)

				-- Quick extension check first
				local ext = utils.get_extension(fullpath)
				if ext then
					-- Full path check
					if should_watch_path(fullpath, cfg) then
						event_buffers[client_id] = event_buffers[client_id] or { map = {}, timer = nil }
						event_buffers[client_id].map[fullpath] = true
						added_any = true
					end
				end
			end
		end

		if added_any then
			schedule_flush_fn(client_id)
		end

		-- If more events, schedule next chunk
		if #q_next.events > 0 then
			vim.defer_fn(process_next_chunk, RAW_PROCESS_DELAY_MS)
		else
			q_next.processing = false
		end
	end

	vim.defer_fn(process_next_chunk, RAW_PROCESS_DELAY_MS)
end

--- Start fs_event watcher
---@param client vim.lsp.Client LSP client
---@param root string Root directory path
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Shared snapshots table
---@param deps roslyn_filewatch.FsEventDeps Dependencies
---@return uv_fs_event_t|nil handle The event handle, or nil on error
---@return string|nil error Error message if failed
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

	local cfg = deps.config or config
	local rename_m = deps.rename_mod or rename_mod
	local snapshot_m = deps.snapshot_mod or snapshot_mod
	local notify_fn = deps.notify or notify
	local notify_roslyn_renames = deps.notify_roslyn_renames
	local queue_events = deps.queue_events
	local restart_watcher = deps.restart_watcher
	local mtime_ns = deps.mtime_ns or utils.mtime_ns
	local identity_from_stat = deps.identity_from_stat or utils.identity_from_stat
	local same_file_info = deps.same_file_info or utils.same_file_info
	local normalize_path = deps.normalize_path or utils.normalize_path
	local last_events = deps.last_events
	local rename_window_ms = deps.rename_window_ms or 300
	local processing_debounce_ms = (cfg and cfg.options and cfg.options.processing_debounce_ms)
		or DEFAULT_PROCESSING_DEBOUNCE_MS
	local mark_dirty_dir = deps.mark_dirty_dir

	---@type roslyn_filewatch.Helpers
	local helpers = {
		notify = notify_fn,
		notify_roslyn_renames = notify_roslyn_renames,
		queue_events = queue_events,
		restart_watcher = restart_watcher,
		last_events = last_events,
	}

	snapshots[client.id] = snapshots[client.id] or {}

	local handle, err = uv.new_fs_event()
	if not handle then
		return nil, err or "uv.new_fs_event failed"
	end

	--- Flush buffered events for client - ASYNC CHUNKED VERSION
	--- Processes files in chunks to prevent UI freezes during heavy activity
	---@param client_id number
	local function flush_client_buffer(client_id)
		local buf = event_buffers[client_id]
		if not buf or not buf.map then
			return
		end

		---@type string[]
		local paths = {}
		for p, _ in pairs(buf.map) do
			table.insert(paths, p)
		end
		buf.map = {}

		if buf.timer then
			local_stop_close(buf.timer)
			buf.timer = nil
		end

		-- If no paths, nothing to do
		if #paths == 0 then
			return
		end

		-- Accumulated events (shared across async chunks)
		---@type roslyn_filewatch.FileChange[]
		local all_evs = {}
		local current_index = 1

		--- Process a single file asynchronously
		---@param fullpath string
		---@param on_done fun()
		local function process_file_async(fullpath, on_done)
			-- Mark directory as dirty for incremental scanning
			if mark_dirty_dir then
				pcall(mark_dirty_dir, client_id, fullpath)
			end

			if not should_watch_path(fullpath, cfg) then
				on_done()
				return
			end

			local prev_mt = snapshots[client.id] and snapshots[client.id][fullpath]

			-- Use async fs_stat
			uv.fs_stat(fullpath, function(err, st)
				vim.schedule(function()
					if not err and st then
						local mt = mtime_ns(st)
						---@type roslyn_filewatch.SnapshotEntry
						local new_entry = { mtime = mt, size = st.size, ino = st.ino, dev = st.dev }

						local matched = false
						if rename_m and rename_m.on_create then
							local ok, res = pcall(rename_m.on_create, client.id, fullpath, st, snapshots, {
								notify = notify_fn,
								notify_roslyn_renames = notify_roslyn_renames,
							})
							if not ok then
								pcall(notify_fn, "rename_mod.on_create error: " .. tostring(res), vim.log.levels.ERROR)
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
								table.insert(all_evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
							elseif not same_file_info(prev_mt, snapshots[client.id][fullpath]) then
								table.insert(all_evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
							end
						end
					else
						-- Missing -> possible delete
						if prev_mt then
							local buffered = false
							if rename_m and rename_m.on_delete then
								local ok, res = pcall(rename_m.on_delete, client.id, fullpath, prev_mt, snapshots, {
									queue_events = queue_events,
									notify = notify_fn,
									rename_window_ms = rename_window_ms,
								})
								if not ok then
									pcall(
										notify_fn,
										"rename_mod.on_delete error: " .. tostring(res),
										vim.log.levels.ERROR
									)
								else
									buffered = res and true or false
								end
							end

							if not buffered then
								if snapshots[client.id] then
									snapshots[client.id][fullpath] = nil
								end

								table.insert(all_evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
							end
						end
					end

					on_done()
				end)
			end)
		end

		--- Process a chunk of files and schedule next chunk
		local function process_chunk()
			local chunk_end = math.min(current_index + FLUSH_CHUNK_SIZE - 1, #paths)
			local pending = chunk_end - current_index + 1
			local completed = 0

			for i = current_index, chunk_end do
				process_file_async(paths[i], function()
					completed = completed + 1
					if completed == pending then
						-- All files in chunk completed
						current_index = chunk_end + 1
						if current_index <= #paths then
							-- More files to process - schedule next chunk with small delay
							vim.defer_fn(process_chunk, FLUSH_CHUNK_DELAY_MS)
						else
							-- All done - send accumulated events
							if #all_evs > 0 then
								pcall(queue_events, client.id, all_evs)
							end
						end
					end
				end)
			end
		end

		-- Start processing first chunk
		process_chunk()
	end

	--- Schedule a flush after debounce
	---@param client_id number
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

	-- Start the fs_event watch with a fully protected callback
	local ok_start, start_err = pcall(function()
		handle:start(root, { recursive = true }, function(err2, filename, events)
			-- Wrap entire callback to ensure nothing bubbles
			local ok_cb, cb_err = pcall(function()
				if err2 then
					-- Handle libuv-level error (often EPERM on Windows dir delete race)
					local msg = tostring(err2)
					local escalated = record_error_and_maybe_escalate(
						client.id,
						msg,
						notify_fn,
						function(reason, delay_ms, disable)
							if restart_watcher then
								pcall(function()
									restart_watcher(reason or "EPERM", delay_ms or 1200, disable)
								end)
							end
						end
					)

					-- Schedule a deferred stop+restart if not escalated
					if not escalated then
						vim.defer_fn(function()
							pcall(function()
								-- Stop/close the handle safely
								if handle and handle.stop and not handle:is_closing() then
									pcall(handle.stop, handle)
								end
								if handle and handle.close and not handle:is_closing() then
									pcall(handle.close, handle)
								end
							end)
							-- Schedule restart with a small delay and request fs_event disabled for a bit
							if restart_watcher then
								pcall(function()
									restart_watcher("EPERM", 800, true)
								end)
							end
						end, 50)
					end
					return
				end

				-- Filename missing: rate-limit restarts
				if not filename then
					may_restart_due_to_nil_filename(client.id, notify_fn, function(reason, delay_ms)
						if restart_watcher then
							pcall(function()
								restart_watcher(reason or "filename_nil", delay_ms or 800)
							end)
						end
					end)
					return
				end

				-- RAW EVENT QUEUE:
				-- Push raw filename to queue immediately.
				-- Do NOT perform string manipulation or filtering here on the hot path.

				if last_events then
					last_events[client.id] = os.time()
				end

				local q = raw_event_queues[client.id]
				if not q then
					q = { events = {}, processing = false }
					raw_event_queues[client.id] = q
				end

				table.insert(q.events, filename)

				-- Trigger processing if not already running
				if not q.processing then
					schedule_raw_processing(client.id, root, cfg, schedule_flush)
				end
			end)

			if not ok_cb then
				local msg = tostring(cb_err)
				record_error_and_maybe_escalate(client.id, msg, notify_fn, function(reason, delay_ms, disable)
					if restart_watcher then
						pcall(function()
							restart_watcher(reason or "callback_error", delay_ms or 800, disable)
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
