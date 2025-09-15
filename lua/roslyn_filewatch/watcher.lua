local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")
local notify_mod = require("roslyn_filewatch.watcher.notify")
local snapshot_mod = require("roslyn_filewatch.watcher.snapshot")
local rename_mod = require("roslyn_filewatch.watcher.rename")
local fs_event_mod = require("roslyn_filewatch.watcher.fs_event")
local fs_poll_mod = require("roslyn_filewatch.watcher.fs_poll")
local watchdog_mod = require("roslyn_filewatch.watcher.watchdog")
local autocmds_mod = require("roslyn_filewatch.watcher.autocmds")

local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat
local same_file_info = utils.same_file_info
local normalize_path = utils.normalize_path
local scan_tree = snapshot_mod.scan_tree

local notify = notify_mod.user
local notify_roslyn = notify_mod.roslyn_changes
local notify_roslyn_renames = notify_mod.roslyn_renames

local M = {}

local watchers = {}
local pollers = {}
local batch_queues = {}
local watchdogs = {}
local snapshots = {} -- client_id -> { [path]= { mtime, size, ino, dev } }
local last_events = {} -- client_id -> os.time()
local restart_scheduled = {} -- client_id -> true
local restart_backoff_until = {} -- client_id -> timestamp (seconds)
local autocmds = {} -- client_id -> { id_main = ..., id_early = ..., id_extra = ... }
local fs_event_disabled_until = {} -- client_id -> timestamp (seconds)

-- Helper: close buffers for deleted files (safe: runs in scheduled context)
local function close_deleted_buffers(path)
	path = normalize_path(path)
	local uri = vim.uri_from_fname(path)

	vim.defer_fn(function()
		local ok, st = pcall(function()
			return uv.fs_stat(path)
		end)
		if ok and st then
			-- file exists -> nothing to do
			return
		end

		vim.schedule(function()
			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(bufnr) then
					local bname = vim.api.nvim_buf_get_name(bufnr)
					if bname ~= "" then
						local bufuri = vim.uri_from_fname(normalize_path(bname))
						if bufuri == uri then
							pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
							notify("Closed buffer for deleted file: " .. path, vim.log.levels.DEBUG)
							break
						end
					end
				end
			end
		end)
	end, 200)
end

-- Helper: queue + batch flush
local function queue_events(client_id, evs)
	if not evs or #evs == 0 then
		return
	end

	if config.options.batching and config.options.batching.enabled then
		if not batch_queues[client_id] then
			batch_queues[client_id] = { events = {}, timer = nil }
		end
		local queue = batch_queues[client_id]
		vim.list_extend(queue.events, evs)

		if not queue.timer then
			local t = uv.new_timer()
			queue.timer = t
			t:start((config.options.batching.interval or 300), 0, function()
				local changes = queue.events
				queue.events = {}
				pcall(function()
					if queue.timer and not queue.timer:is_closing() then
						queue.timer:stop()
						queue.timer:close()
					end
				end)
				queue.timer = nil
				if #changes > 0 then
					vim.schedule(function()
						pcall(notify_roslyn, changes)
					end)
				end
			end)
		end
	else
		vim.schedule(function()
			pcall(notify_roslyn, evs)
		end)
	end
end

-- Detect Windows platform
local function is_windows()
	local ok, uname = pcall(function()
		return uv.os_uname()
	end)
	if ok and uname and uname.sysname then
		return uname.sysname:match("Windows")
	end
	return package.config:sub(1, 1) == "\\"
end

-- Core start
M.start = function(client)
	if not client then
		return
	end

	-- Prevent duplicate starts. Check all handles so poller-only case doesn't start duplicates.
	if watchers[client.id] or pollers[client.id] or watchdogs[client.id] then
		return -- already running
	end

	-- tunables
	local POLL_INTERVAL = (config.options and config.options.poll_interval) or 3000
	local POLLER_RESTART_THRESHOLD = (config.options and config.options.poller_restart_threshold) or 2
	local WATCHDOG_IDLE = (config.options and config.options.watchdog_idle) or 60
	local RENAME_WINDOW_MS = (config.options and config.options.rename_detection_ms) or 300

	local root = client.config and client.config.root_dir
	if not root then
		notify("No root_dir for client " .. (client.name or "<unknown>"), vim.log.levels.ERROR)
		return
	end
	root = normalize_path(root)

	-- cleanup (close handles, timers, autocmds, rename buffers)
	local function cleanup()
		-- clear fs_event internal timers for this client (if any)
		pcall(function()
			if fs_event_mod and fs_event_mod.clear then
				pcall(fs_event_mod.clear, client.id)
			end
		end)

		if watchers[client.id] then
			pcall(function()
				local h = watchers[client.id]
				pcall(function()
					if h and not h:is_closing() then
						if h.stop then
							pcall(h.stop, h)
						end
						if h.close then
							pcall(h.close, h)
						end
					end
				end)
			end)
			watchers[client.id] = nil
		end

		if pollers[client.id] then
			pcall(function()
				local p = pollers[client.id]
				if p and not p:is_closing() and p.stop then
					p:stop()
				end
				if p and p.close then
					p:close()
				end
			end)
			pollers[client.id] = nil
		end

		if watchdogs[client.id] then
			pcall(function()
				local w = watchdogs[client.id]
				if w and not w:is_closing() then
					w:stop()
					w:close()
				end
			end)
			watchdogs[client.id] = nil
		end

		if batch_queues[client.id] then
			if batch_queues[client.id].timer then
				pcall(function()
					if not batch_queues[client.id].timer:is_closing() then
						batch_queues[client.id].timer:stop()
						batch_queues[client.id].timer:close()
					end
				end)
			end
			batch_queues[client.id] = nil
		end

		pcall(function()
			rename_mod.clear(client.id)
		end)

		if autocmds[client.id] then
			for _, id in pairs(autocmds[client.id]) do
				pcall(vim.api.nvim_del_autocmd, id)
			end
			autocmds[client.id] = nil
		end
	end

	-- restart watcher with backoff and optional fs_event disable flag
	local function restart_watcher(reason, delay_ms, disable_fs_event)
		delay_ms = delay_ms or 300
		if restart_scheduled[client.id] then
			return
		end
		local now = os.time()
		local until_ts = restart_backoff_until[client.id] or 0
		if now < until_ts then
			notify("Restart suppressed due to backoff for client " .. client.name, vim.log.levels.DEBUG)
			return
		end

		if disable_fs_event then
			-- disable fs_event attempts for a short window (avoid re-creating broken handle)
			fs_event_disabled_until[client.id] = now + 5 -- 5 seconds
		end

		restart_scheduled[client.id] = true
		restart_backoff_until[client.id] = now + math.ceil(delay_ms / 1000)

		vim.defer_fn(function()
			restart_scheduled[client.id] = nil
			local old_snapshot = snapshots[client.id] or {}
			cleanup()
			if not client.is_stopped() then
				notify(
					"Restarting watcher for client "
						.. client.name
						.. " (reason: "
						.. tostring(reason or "unspecified")
						.. ")",
					vim.log.levels.DEBUG
				)
				M.start(client)

				-- rescan and backfill events after restart
				local new_map = {}
				pcall(function()
					scan_tree(client.config.root_dir, new_map)
				end)

				local evs = {}
				for path, _ in pairs(old_snapshot) do
					if new_map[path] == nil then
						close_deleted_buffers(path)
						table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
					end
				end
				for path, _ in pairs(new_map) do
					if old_snapshot[path] == nil then
						table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
					end
				end

				if #evs > 0 then
					notify("Backfilled " .. #evs .. " events after restart", vim.log.levels.DEBUG)
					queue_events(client.id, evs)
				end

				snapshots[client.id] = new_map
			end
		end, delay_ms)
	end

	local helpers = {
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		queue_events = queue_events,
		close_deleted_buffers = close_deleted_buffers,
		restart_watcher = restart_watcher,
		last_events = last_events,
	}

	-- choose whether to attempt native fs_event
	local os_win = is_windows()
	local force_polling = (config.options and config.options.force_polling) or false
	local disabled_until = fs_event_disabled_until[client.id] or 0
	local now = os.time()
	local use_fs_event = (not os_win) and not force_polling and now >= disabled_until

	if use_fs_event then
		local handle, start_err = fs_event_mod.start(client, root, snapshots, {
			config = config,
			rename_mod = rename_mod,
			snapshot_mod = snapshot_mod,
			notify = notify,
			notify_roslyn_renames = notify_roslyn_renames,
			queue_events = queue_events,
			close_deleted_buffers = close_deleted_buffers,
			restart_watcher = restart_watcher,
			mtime_ns = mtime_ns,
			identity_from_stat = identity_from_stat,
			same_file_info = same_file_info,
			normalize_path = normalize_path,
			last_events = last_events,
			rename_window_ms = RENAME_WINDOW_MS,
		})

		if not handle then
			-- if native start failed, temporarily disable attempts and continue with poller
			notify("Failed to create fs_event: " .. tostring(start_err), vim.log.levels.WARN)
			fs_event_disabled_until[client.id] = os.time() + 5
		else
			watchers[client.id] = handle
			last_events[client.id] = os.time()
		end
	else
		notify(
			"Using poller-only mode for client "
				.. client.name
				.. " (windows="
				.. tostring(os_win)
				.. ", force_polling="
				.. tostring(force_polling)
				.. ")",
			vim.log.levels.DEBUG
		)

		-- Prime last_events so the watchdog does not immediately treat this as idle
		last_events[client.id] = os.time()
	end

	-- always create poller fallback (keeps snapshot reliable)
	local poller, poll_err = fs_poll_mod.start(client, root, snapshots, {
		scan_tree = scan_tree,
		identity_from_stat = identity_from_stat,
		same_file_info = same_file_info,
		queue_events = queue_events,
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		close_deleted_buffers = close_deleted_buffers,
		restart_watcher = restart_watcher,
		last_events = last_events,
		poll_interval = POLL_INTERVAL,
		poller_restart_threshold = POLLER_RESTART_THRESHOLD,
	})

	if not poller then
		notify("Failed to create poller: " .. tostring(poll_err), vim.log.levels.ERROR)
		-- close any fs_event to avoid leaking
		pcall(function()
			if watchers[client.id] and watchers[client.id].close then
				watchers[client.id]:close()
			end
		end)
		return
	end
	pollers[client.id] = poller

	-- watchdog
	local resync_fn = function()
		pcall(function()
			snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
		end)
	end

	local watchdog, watchdog_err = watchdog_mod.start(client, root, snapshots, {
		notify = notify,
		resync_snapshot = resync_fn,
		restart_watcher = restart_watcher,
		get_handle = function()
			return watchers[client.id]
		end,
		last_events = last_events,
		watchdog_idle = WATCHDOG_IDLE,
		use_fs_event = use_fs_event, -- explicit flag so watchdog only treats missing handle as error when fs_event expected
	})
	if not watchdog then
		notify("Failed to start watchdog: " .. tostring(watchdog_err), vim.log.levels.ERROR)
		pcall(function()
			if pollers[client.id] and pollers[client.id].close then
				pollers[client.id]:close()
			end
			if watchers[client.id] and watchers[client.id].close then
				watchers[client.id]:close()
			end
		end)
		return
	end
	watchdogs[client.id] = watchdog

	-- autocmds to keep editor <-> fs state coherent
	local autocmd_ids = autocmds_mod.start(client, root, snapshots, {
		notify = notify,
		resync_snapshot = resync_fn,
		restart_watcher = restart_watcher,
		normalize_path = normalize_path,
	})
	autocmds[client.id] = autocmd_ids

	notify("Watcher started for client " .. client.name .. " at root: " .. root, vim.log.levels.DEBUG)

	vim.api.nvim_create_autocmd("LspDetach", {
		once = true,
		callback = function(args)
			if args.data.client_id == client.id then
				snapshots[client.id] = nil
				restart_scheduled[client.id] = nil
				restart_backoff_until[client.id] = nil
				fs_event_disabled_until[client.id] = nil
				cleanup()
				notify("LspDetach: Watcher stopped for client " .. client.name, vim.log.levels.DEBUG)
			end
		end,
	})
end

return M
