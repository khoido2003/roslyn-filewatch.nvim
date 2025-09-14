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
local autocmds = {} -- client_id -> { id_main = ..., id_early = ..., id_extra = ... }

-- ================================================================
-- Helper: close buffers for deleted files (safe: runs in scheduled context)
-- ================================================================
local function close_deleted_buffers(path)
	path = normalize_path(path)
	local uri = vim.uri_from_fname(path)

	-- double-check after short delay to avoid race conditions
	vim.defer_fn(function()
		local st = uv.fs_stat(path)
		if st then
			-- file still exists -> skip closing
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
	end, 200) -- wait 200ms before confirming deletion
end

-- ================================================================
-- Helper: queue + batch flush
-- ================================================================

local function queue_events(client_id, evs)
	if config.options.batching.enabled then
		if not batch_queues[client_id] then
			batch_queues[client_id] = { events = {}, timer = nil }
		end
		local queue = batch_queues[client_id]
		vim.list_extend(queue.events, evs)

		if not queue.timer then
			queue.timer = uv.new_timer()
			queue.timer:start(config.options.batching.interval, 0, function()
				local changes = queue.events
				queue.events = {}
				-- stop & close safely
				pcall(function()
					queue.timer:stop()
					queue.timer:close()
				end)
				queue.timer = nil
				if #changes > 0 then
					vim.schedule(function()
						notify_roslyn(changes)
					end)
				end
			end)
		end
	else
		vim.schedule(function()
			notify_roslyn(evs)
		end)
	end
end

-- ================================================================
-- Core Watch Logic
-- ================================================================
M.start = function(client)
	if watchers[client.id] then
		return -- already running
	end

	-- read tunables at start-time (so config.setup can be called before M.start)
	local POLL_INTERVAL = (config.options and config.options.poll_interval) or 3000 -- ms
	local POLLER_RESTART_THRESHOLD = (config.options and config.options.poller_restart_threshold) or 2 -- seconds
	local WATCHDOG_IDLE = (config.options and config.options.watchdog_idle) or 60 -- seconds
	-- rename detection window (ms)
	local RENAME_WINDOW_MS = (config.options and config.options.rename_detection_ms) or 300

	local root = client.config.root_dir
	if not root then
		notify("No root_dir for client " .. client.name, vim.log.levels.ERROR)
		return
	end
	root = normalize_path(root)

	-- safe cleanup
	local function cleanup()
		-- fs_event handle
		if watchers[client.id] then
			pcall(function()
				local h = watchers[client.id]
				-- stop and close if possible
				pcall(function()
					if h and not h:is_closing() then
						if h.stop then
							h:stop()
						end
						if h.close then
							h:close()
						end
					end
				end)
			end)
			watchers[client.id] = nil
		end

		if pollers[client.id] then
			pcall(function()
				local p = pollers[client.id]
				if p and not p:is_closing() then
					p:stop()
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
					batch_queues[client.id].timer:stop()
					batch_queues[client.id].timer:close()
				end)
			end
			batch_queues[client.id] = nil
		end

		-- stop & clear pending delete timers & maps
		pcall(function()
			rename_mod.clear(client.id)
		end)

		-- remove autocmds for this exact client id (avoid accidental prefix matches)
		if autocmds[client.id] then
			for _, id in pairs(autocmds[client.id]) do
				pcall(vim.api.nvim_del_autocmd, id)
			end
			autocmds[client.id] = nil
		end
	end

	local function restart_watcher()
		if restart_scheduled[client.id] then
			return
		end
		restart_scheduled[client.id] = true
		vim.defer_fn(function()
			restart_scheduled[client.id] = nil

			local old_snapshot = snapshots[client.id] or {}

			cleanup()
			if not client.is_stopped() then
				notify("Restarting watcher for client " .. client.name, vim.log.levels.DEBUG)
				M.start(client)

				-- rescan for diff
				local new_map = {}
				scan_tree(client.config.root_dir, new_map)

				local evs = {}

				-- backfill deletes
				for path, _ in pairs(old_snapshot) do
					if new_map[path] == nil then
						close_deleted_buffers(path)
						table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 }) -- Deleted
					end
				end

				-- backfill creates
				for path, _ in pairs(new_map) do
					if old_snapshot[path] == nil then
						table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 }) -- Created
					end
				end

				if #evs > 0 then
					notify("Backfilled " .. #evs .. " events after restart", vim.log.levels.DEBUG)
					queue_events(client.id, evs)
				end

				snapshots[client.id] = new_map
			end
		end, 300)
	end

	local helpers = {
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		queue_events = queue_events,
		close_deleted_buffers = close_deleted_buffers,
		restart_watcher = restart_watcher,
		last_events = last_events,
	}

	-- ********** fs_event **********
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
		notify("Failed to create fs_event: " .. tostring(start_err), vim.log.levels.ERROR)
		return
	end

	watchers[client.id] = handle
	last_events[client.id] = os.time()

	-- Initialize snapshot only if missing
	if not snapshots[client.id] then
		snapshots[client.id] = {}
		scan_tree(root, snapshots[client.id])
	end

	-- -------- fs_poll --------
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
		-- close the fs_event handle started earlier to avoid leaking
		pcall(function()
			if handle and handle.close then
				handle:close()
			end
		end)
		return
	end

	pollers[client.id] = poller

	-- -------- watchdog --------
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
	})
	if not watchdog then
		notify("Failed to start watchdog: " .. tostring(watchdog_err), vim.log.levels.ERROR)
		-- cleanup poller + fs_event if needed
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

	-- -------- autocmds --------
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
				cleanup()
				notify("LspDetach: Watcher stopped for client " .. client.name, vim.log.levels.DEBUG)
			end
		end,
	})
end

return M
