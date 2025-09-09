-- lua/roslyn_filewatch/watcher.lua
local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")
local notify_mod = require("roslyn_filewatch.watcher.notify")
local snapshot_mod = require("roslyn_filewatch.watcher.snapshot")
local rename_mod = require("roslyn_filewatch.watcher.rename")
local fs_event_mod = require("roslyn_filewatch.watcher.fs_event")

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

		-- stop & clear pending delete timers & maps (rename module)
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

	-- prepare helpers for snapshot module (and fs_event/rename)
	local helpers = {
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		queue_events = queue_events,
		close_deleted_buffers = close_deleted_buffers,
		restart_watcher = restart_watcher,
		last_events = last_events,
	}

	-- ********** fs_event is delegated to fs_event_mod.start **********
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
	local poller = uv.new_fs_poll()
	poller:start(root, POLL_INTERVAL, function(errp, prev, curr)
		if errp then
			notify("Poller error: " .. tostring(errp), vim.log.levels.ERROR)
			return
		end

		if
			prev
			and curr
			and (prev.mtime and curr.mtime)
			and (prev.mtime.sec ~= curr.mtime.sec or prev.mtime.nsec ~= curr.mtime.nsec)
		then
			notify("Poller detected root metadata change; restarting watcher", vim.log.levels.DEBUG)
			restart_watcher()
			return
		end

		local new_map = {}
		scan_tree(root, new_map)

		local old_map = snapshots[client.id] or {}
		local evs = {}
		local saw_delete = false
		local rename_pairs = {}

		-- build old identity map
		local old_id_map = {}
		for path, entry in pairs(old_map) do
			local id = identity_from_stat(entry)
			if id then
				old_id_map[id] = path
			end
		end

		-- detect creates / renames / changes
		for path, mt in pairs(new_map) do
			local old_mt = old_map[path]
			if not old_mt then
				local id = identity_from_stat(mt)
				local oldpath = id and old_id_map[id]
				if oldpath then
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

		-- remaining old_map entries are deletes
		for path, _ in pairs(old_map) do
			saw_delete = true
			close_deleted_buffers(path)
			table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
		end

		-- send renames
		if #rename_pairs > 0 then
			notify("Poller detected " .. #rename_pairs .. " rename(s)", vim.log.levels.DEBUG)
			notify_roslyn_renames(rename_pairs)
		end

		if #evs > 0 then
			snapshots[client.id] = new_map
			queue_events(client.id, evs)
			last_events[client.id] = os.time()

			local last = last_events[client.id] or 0
			if os.time() - last > POLLER_RESTART_THRESHOLD then
				notify("Poller detected diffs while fs_event quiet; restarting watcher", vim.log.levels.DEBUG)
				restart_watcher()
			end

			if saw_delete then
				-- extra safety restart if deletes found by poller
				restart_watcher()
			end
		else
			snapshots[client.id] = new_map
		end
	end)
	pollers[client.id] = poller

	-- -------- watchdog --------
	local watchdog = uv.new_timer()
	watchdog:start(15000, 15000, function()
		if not client.is_stopped() then
			local last = last_events[client.id] or 0

			-- detect idle (no events in too long)
			if os.time() - last > WATCHDOG_IDLE then
				notify("Idle " .. WATCHDOG_IDLE .. "s, recycling watcher", vim.log.levels.DEBUG)
				snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
				restart_watcher()
				return
			end

			-- detect dead handle
			local h = watchers[client.id]
			if not h or (h.is_closing and h:is_closing()) then
				notify("Watcher handle missing/closed, restarting", vim.log.levels.DEBUG)
				snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
				restart_watcher()
			end
		end
	end)
	watchdogs[client.id] = watchdog

	-- -------- autocmds --------
	local id = vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		callback = function(args)
			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					notify("Buffer closed for deleted file: " .. bufpath .. " -> resync+restart", vim.log.levels.DEBUG)
					snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
					restart_watcher()
				end
			end
		end,
	})

	local id2 = vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FileChangedRO" }, {
		callback = function(args)
			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					notify("File vanished while buffer open: " .. bufpath .. " -> resync+restart", vim.log.levels.DEBUG)
					snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
					restart_watcher()
				end
			end
		end,
	})

	local id3 = vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		callback = function(args)
			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					notify(
						"File missing but buffer still open: " .. bufpath .. " -> resync+restart",
						vim.log.levels.DEBUG
					)
					snapshot_mod.resync_snapshot_for(client.id, root, snapshots, helpers)
					restart_watcher()
				end
			end
		end,
	})

	autocmds[client.id] = { id, id2, id3 }

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
