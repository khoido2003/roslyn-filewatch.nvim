---@class roslyn_filewatch.watcher
---@field start fun(client: vim.lsp.Client)
---@field stop fun(client: vim.lsp.Client)

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

---@type table<number, uv_fs_event_t>
local watchers = {}
---@type table<number, uv_fs_poll_t>
local pollers = {}
---@type table<number, { events: roslyn_filewatch.FileChange[], timer: uv_timer_t|nil }>
local batch_queues = {}
---@type table<number, uv_timer_t>
local watchdogs = {}
---@type table<number, table<string, roslyn_filewatch.SnapshotEntry>>
local snapshots = {}
---@type table<number, number>
local last_events = {}
---@type table<number, boolean>
local restart_scheduled = {}
---@type table<number, number>
local restart_backoff_until = {}
---@type table<number, number[]>
local autocmds = {}
---@type table<number, number>
local fs_event_disabled_until = {}

-- Incremental scanning: track directories that need rescanning
---@type table<number, table<string, boolean>>
local dirty_dirs = {}
-- Force full scan on next poll (set on startup, watchdog restart, errors)
---@type table<number, boolean>
local needs_full_scan = {}
-- Threshold: if more than this many dirty dirs, do full scan instead
local DIRTY_DIRS_THRESHOLD = 10

-- Register state references with status module for RoslynFilewatchStatus command
pcall(function()
	local status_mod = require("roslyn_filewatch.status")
	if status_mod and status_mod.register_refs then
		status_mod.register_refs({
			watchers = watchers,
			pollers = pollers,
			watchdogs = watchdogs,
			snapshots = snapshots,
			last_events = last_events,
			dirty_dirs = dirty_dirs,
		})
	end
end)

------------------------------------------------------
-- Incremental scanning helpers
------------------------------------------------------

--- Mark a directory as needing rescan
---@param client_id number
---@param path string File or directory path that changed
local function mark_dirty_dir(client_id, path)
	if not path or path == "" then
		return
	end

	-- Initialize if needed
	if not dirty_dirs[client_id] then
		dirty_dirs[client_id] = {}
	end

	-- Get parent directory of the path
	local normalized = normalize_path(path)
	local parent = normalized:match("^(.+)/[^/]+$")
	if parent then
		dirty_dirs[client_id][parent] = true
	else
		-- Path is a root-level item, mark root
		dirty_dirs[client_id][normalized] = true
	end
end

--- Get and clear dirty directories for a client
---@param client_id number
---@return string[] dirs List of dirty directories
local function get_and_clear_dirty_dirs(client_id)
	local dirs = {}
	if dirty_dirs[client_id] then
		for dir, _ in pairs(dirty_dirs[client_id]) do
			table.insert(dirs, dir)
		end
		dirty_dirs[client_id] = {}
	end
	return dirs
end

--- Check if full scan is needed
---@param client_id number
---@return boolean
local function should_full_scan(client_id)
	-- Check explicit flag
	if needs_full_scan[client_id] then
		needs_full_scan[client_id] = nil
		return true
	end

	-- Check dirty dirs count threshold
	if dirty_dirs[client_id] then
		local count = 0
		for _ in pairs(dirty_dirs[client_id]) do
			count = count + 1
			if count > DIRTY_DIRS_THRESHOLD then
				return true
			end
		end
	end

	return false
end

--- Request full scan on next poll
---@param client_id number
local function request_full_scan(client_id)
	needs_full_scan[client_id] = true
end

------------------------------------------------------

--- Close buffers for deleted files (safe: runs in scheduled context)
---@param path string
local function close_deleted_buffers(path)
	-- BUG FIX: Guard against empty/nil path
	if not path or path == "" then
		return
	end

	path = normalize_path(path)

	local ok_uri, uri = pcall(vim.uri_from_fname, path)
	if not ok_uri or not uri then
		return
	end

	vim.defer_fn(function()
		local ok, st = pcall(function()
			return uv.fs_stat(path)
		end)
		if ok and st then
			-- File exists -> nothing to do
			return
		end

		vim.schedule(function()
			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(bufnr) then
					local bname = vim.api.nvim_buf_get_name(bufnr)
					if bname ~= "" then
						local ok_bufuri, bufuri = pcall(vim.uri_from_fname, normalize_path(bname))
						if ok_bufuri and bufuri == uri then
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

------------------------------------------------------

--- Queue and batch flush events
---@param client_id number
---@param evs roslyn_filewatch.FileChange[]
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

-------------------------------------------------

--- Cleanup all resources for a client
---@param client_id number
local function cleanup_client(client_id)
	-- Clear fs_event internal timers for this client (if any)
	pcall(function()
		if fs_event_mod and fs_event_mod.clear then
			pcall(fs_event_mod.clear, client_id)
		end
	end)

	if watchers[client_id] then
		pcall(function()
			local h = watchers[client_id]
			pcall(function()
				if h and not (h.is_closing and h:is_closing()) then
					if h.stop then
						pcall(h.stop, h)
					end
					if h.close then
						pcall(h.close, h)
					end
				end
			end)
		end)
		watchers[client_id] = nil
	end

	if pollers[client_id] then
		pcall(function()
			local p = pollers[client_id]
			if p then
				if p.stop then
					pcall(p.stop, p)
				end
				if p.close then
					pcall(p.close, p)
				end
			end
		end)
		pollers[client_id] = nil
	end

	if watchdogs[client_id] then
		pcall(function()
			local w = watchdogs[client_id]
			if w and not (w.is_closing and w:is_closing()) then
				pcall(function()
					w:stop()
					w:close()
				end)
			end
		end)
		watchdogs[client_id] = nil
	end

	if batch_queues[client_id] then
		if batch_queues[client_id].timer then
			pcall(function()
				if not batch_queues[client_id].timer:is_closing() then
					batch_queues[client_id].timer:stop()
					batch_queues[client_id].timer:close()
				end
			end)
		end
		batch_queues[client_id] = nil
	end

	-- Clear rename buffers
	pcall(function()
		rename_mod.clear(client_id)
	end)

	-- Clear autocmds (the augroup will be auto-cleared when recreated)
	if autocmds[client_id] then
		-- Also try to delete the augroup
		pcall(function()
			vim.api.nvim_del_augroup_by_name("RoslynFilewatch_" .. client_id)
		end)
		autocmds[client_id] = nil
	end
end

-- //////////////////////////////////////////////////
-- /////////////////////////////////////////////////

--- Stop watcher for a client
---@param client vim.lsp.Client
function M.stop(client)
	if not client then
		return
	end
	local cid = client.id
	-- Clear snapshot & restart state
	snapshots[cid] = nil
	restart_scheduled[cid] = nil
	restart_backoff_until[cid] = nil
	fs_event_disabled_until[cid] = nil
	last_events[cid] = nil
	-- Clear incremental scanning state
	dirty_dirs[cid] = nil
	needs_full_scan[cid] = nil
	-- Cleanup handles/timers
	cleanup_client(cid)
	notify("Watcher stopped for client " .. (client.name or "<unknown>"), vim.log.levels.DEBUG)
end

--- Force resync for all active clients
--- Clears snapshots and sets needs_full_scan flag for next poll cycle
function M.resync()
	local clients = vim.lsp.get_clients()
	local resynced = 0

	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			local cid = client.id
			-- Clear snapshot to force full scan
			snapshots[cid] = {}
			-- Set full scan flag
			needs_full_scan[cid] = true
			-- Clear dirty dirs
			dirty_dirs[cid] = {}
			-- Update last event time
			last_events[cid] = os.time()
			resynced = resynced + 1
			notify("Resync triggered for client " .. client.name, vim.log.levels.INFO)
		end
	end

	if resynced > 0 then
		vim.notify("[roslyn-filewatch] Resync triggered for " .. resynced .. " client(s)", vim.log.levels.INFO)
	else
		vim.notify("[roslyn-filewatch] No active Roslyn clients to resync", vim.log.levels.WARN)
	end
end

-- /////////////////////////////////////////////////
-- /////////////////////////////////////////////////

--- Start watcher for a client
---@param client vim.lsp.Client
function M.start(client)
	if not client then
		return
	end

	-- If client already stopped, nothing to do
	if client.is_stopped and client.is_stopped() then
		return
	end

	-- Prevent duplicate starts. Check all handles so poller-only case doesn't start duplicates.
	if watchers[client.id] or pollers[client.id] or watchdogs[client.id] then
		return -- already running
	end

	-- Tunables
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

	--- Restart watcher with backoff and optional fs_event disable flag
	---@param reason? string
	---@param delay_ms? number
	---@param disable_fs_event? boolean
	local function restart_watcher(reason, delay_ms, disable_fs_event)
		delay_ms = delay_ms or 300

		-- BUG FIX: Set restart_scheduled IMMEDIATELY to prevent race condition
		if restart_scheduled[client.id] then
			return
		end
		restart_scheduled[client.id] = true

		local now = os.time()
		local until_ts = restart_backoff_until[client.id] or 0
		if now < until_ts then
			notify("Restart suppressed due to backoff for client " .. client.name, vim.log.levels.DEBUG)
			restart_scheduled[client.id] = nil
			return
		end

		if disable_fs_event then
			-- Disable fs_event attempts for a short window (avoid re-creating broken handle)
			fs_event_disabled_until[client.id] = now + 5 -- 5 seconds
		end

		restart_backoff_until[client.id] = now + math.ceil(delay_ms / 1000)

		vim.defer_fn(function()
			restart_scheduled[client.id] = nil

			if client.is_stopped() then
				return
			end

			notify(
				"Restarting watcher for client "
					.. client.name
					.. " (reason: "
					.. tostring(reason or "unspecified")
					.. ")",
				vim.log.levels.DEBUG
			)

			-- LIGHTWEIGHT RESTART: Only recreate fs_event handle, preserve snapshot
			-- This avoids the expensive full tree scan that was causing freezes

			-- Stop old fs_event handle if exists
			if watchers[client.id] then
				pcall(function()
					local h = watchers[client.id]
					if h and not (h.is_closing and h:is_closing()) then
						if h.stop then
							pcall(h.stop, h)
						end
						if h.close then
							pcall(h.close, h)
						end
					end
				end)
				watchers[client.id] = nil
			end

			-- Recreate fs_event handle (if not disabled)
			local use_fs_event = not config.options.force_polling
			if fs_event_disabled_until[client.id] and os.time() < fs_event_disabled_until[client.id] then
				use_fs_event = false
			end

			if use_fs_event then
				local handle, err = fs_event_mod.start(client, root, snapshots, {
					notify = notify,
					queue_events = queue_events,
					notify_roslyn_renames = notify_roslyn_renames,
					restart_watcher = restart_watcher,
					mark_dirty_dir = mark_dirty_dir,
				})
				if handle then
					watchers[client.id] = handle
				else
					notify("Failed to recreate fs_event: " .. tostring(err), vim.log.levels.DEBUG)
				end
			end

			-- Note: Snapshot is preserved, no full scan needed
			-- The poller will continue with incremental scanning using dirty_dirs
		end, delay_ms)
	end

	---@type roslyn_filewatch.Helpers
	local helpers = {
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		queue_events = queue_events,
		close_deleted_buffers = close_deleted_buffers,
		restart_watcher = restart_watcher,
		last_events = last_events,
	}

	-- Choose whether to attempt native fs_event
	-- IMPROVEMENT: Enable fs_event on Windows since error handling is robust
	local force_polling = (config.options and config.options.force_polling) or false
	local disabled_until = fs_event_disabled_until[client.id] or 0
	local now = os.time()
	local use_fs_event = not force_polling and now >= disabled_until

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
			mark_dirty_dir = mark_dirty_dir,
			mtime_ns = mtime_ns,
			identity_from_stat = identity_from_stat,
			same_file_info = same_file_info,
			normalize_path = normalize_path,
			last_events = last_events,
			rename_window_ms = RENAME_WINDOW_MS,
		})

		if not handle then
			-- If native start failed, temporarily disable attempts and continue with poller
			notify("Failed to create fs_event: " .. tostring(start_err), vim.log.levels.WARN)
			fs_event_disabled_until[client.id] = os.time() + 5
			use_fs_event = false
		else
			watchers[client.id] = handle
			last_events[client.id] = os.time()
		end
	else
		local is_win = utils.is_windows()
		notify(
			"Using poller-only mode for client "
				.. client.name
				.. " (force_polling="
				.. tostring(force_polling)
				.. ", disabled_until="
				.. tostring(disabled_until > now)
				.. ")",
			vim.log.levels.DEBUG
		)

		-- Prime last_events so the watchdog does not immediately treat this as idle
		last_events[client.id] = os.time()
	end

	-- Always create poller fallback (keeps snapshot reliable)
	-- Request full scan on startup
	needs_full_scan[client.id] = true

	local poller, poll_err = fs_poll_mod.start(client, root, snapshots, {
		scan_tree = scan_tree,
		partial_scan = snapshot_mod.partial_scan,
		get_dirty_dirs = get_and_clear_dirty_dirs,
		should_full_scan = should_full_scan,
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
		-- Close any fs_event to avoid leaking
		pcall(function()
			if watchers[client.id] and watchers[client.id].close then
				watchers[client.id]:close()
			end
		end)
		return
	end
	pollers[client.id] = poller

	-- Watchdog
	local watchdog, watchdog_err = watchdog_mod.start(client, root, snapshots, {
		notify = notify,
		restart_watcher = restart_watcher,
		get_handle = function()
			return watchers[client.id]
		end,
		last_events = last_events,
		watchdog_idle = WATCHDOG_IDLE,
		use_fs_event = use_fs_event,
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

	-- Autocmds to keep editor <-> fs state coherent
	local autocmd_ids = autocmds_mod.start(client, root, snapshots, {
		notify = notify,
		restart_watcher = restart_watcher,
		normalize_path = normalize_path,
		queue_events = queue_events,
	})
	autocmds[client.id] = autocmd_ids

	notify("Watcher started for client " .. client.name .. " at root: " .. root, vim.log.levels.DEBUG)

	vim.api.nvim_create_autocmd("LspDetach", {
		callback = function(args)
			if args.data.client_id == client.id then
				-- Clear snapshot + state
				snapshots[client.id] = nil
				restart_scheduled[client.id] = nil
				restart_backoff_until[client.id] = nil
				fs_event_disabled_until[client.id] = nil
				last_events[client.id] = nil
				-- Clear incremental scanning state
				dirty_dirs[client.id] = nil
				needs_full_scan[client.id] = nil
				-- Cleanup handles & timers
				cleanup_client(client.id)
				notify("LspDetach: Watcher stopped for client " .. client.name, vim.log.levels.DEBUG)
				return true -- Remove this autocmd after cleanup
			end
		end,
	})
end

return M
