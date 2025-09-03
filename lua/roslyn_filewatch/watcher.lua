local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

local M = {}

local watchers = {}
local pollers = {}
local batch_queues = {}
local watchdogs = {}
local snapshots = {} -- client_id -> { [path]=mtime_ns }
local last_events = {} -- client_id -> os.time()
local restart_scheduled = {} -- client_id -> true
local autocmds = {} -- client_id -> autocmd id

-- Tunables
local POLL_INTERVAL = (config.options and config.options.poll_interval) or 3000 -- ms
local POLLER_RESTART_THRESHOLD = (config.options and config.options.poller_restart_threshold) or 2 -- seconds
local WATCHDOG_IDLE = (config.options and config.options.watchdog_idle) or 60 -- seconds

local function notify(msg, level)
	vim.schedule(function()
		vim.notify("[roslyn-filewatch] " .. msg, level or vim.log.levels.INFO)
	end)
end

local function notify_roslyn(changes)
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			client.notify("workspace/didChangeWatchedFiles", { changes = changes })
		end
	end
end

local function should_watch(path)
	for _, dir in ipairs(config.options.ignore_dirs) do
		if path:find("[/\\]" .. dir .. "[/\\]") then
			return false
		end
	end
	for _, ext in ipairs(config.options.watch_extensions) do
		if path:sub(-#ext) == ext then
			return true
		end
	end
	return false
end

local function mtime_ns(stat)
	if not stat or not stat.mtime then
		return 0
	end
	return (stat.mtime.sec or 0) * 1e9 + (stat.mtime.nsec or 0)
end

-- ================================================================
-- Helper: close buffers for deleted files
-- ================================================================

local function close_deleted_buffers(path)
	vim.schedule(function()
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(bufnr) then
				if vim.api.nvim_buf_get_name(bufnr) == path then
					pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
					notify("Closed buffer for deleted file: " .. path, vim.log.levels.DEBUG)
				end
			end
		end
	end)
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
				queue.timer:stop()
				queue.timer:close()
				queue.timer = nil
				if #changes > 0 then
					vim.schedule(function()
						notify_roslyn(changes)
					end)
				end
			end)
		end
	else
		notify_roslyn(evs)
	end
end

-- ================================================================
-- Directory scan (for poller snapshot)
-- ================================================================
local function scan_tree(root, out_map)
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
			local fullpath = path .. "/" .. name
			if typ == "directory" then
				local skip = false
				for _, dir in ipairs(config.options.ignore_dirs) do
					if fullpath:find("[/\\]" .. dir .. "$") then
						skip = true
						break
					end
				end
				if not skip then
					scan_dir(fullpath)
				end
			elseif typ == "file" then
				if should_watch(fullpath) then
					local st = uv.fs_stat(fullpath)
					if st then
						out_map[fullpath] = mtime_ns(st)
					end
				end
			end
		end
	end
	scan_dir(root)
end

-- ================================================================
-- Core Watch Logic
-- ================================================================
M.start = function(client)
	if watchers[client.id] then
		return -- already running
	end

	local root = client.config.root_dir
	if not root then
		notify("No root_dir for client " .. client.name, vim.log.levels.ERROR)
		return
	end

	local function cleanup()
		if watchers[client.id] then
			watchers[client.id]:stop()
			watchers[client.id] = nil
		end
		if pollers[client.id] then
			pollers[client.id]:stop()
			pollers[client.id]:close()
			pollers[client.id] = nil
		end
		if watchdogs[client.id] then
			watchdogs[client.id]:stop()
			watchdogs[client.id]:close()
			watchdogs[client.id] = nil
		end
		if batch_queues[client.id] then
			if batch_queues[client.id].timer then
				batch_queues[client.id].timer:stop()
				batch_queues[client.id].timer:close()
			end
			batch_queues[client.id] = nil
		end
		if autocmds[client.id] then
			pcall(vim.api.nvim_del_autocmd, autocmds[client.id])
			autocmds[client.id] = nil
		end
		if autocmds[client.id .. "_earlycheck"] then
			pcall(vim.api.nvim_del_autocmd, autocmds[client.id .. "_earlycheck"])
			autocmds[client.id .. "_earlycheck"] = nil
		end
		if autocmds[client.id .. "_extra"] then
			pcall(vim.api.nvim_del_autocmd, autocmds[client.id .. "_extra"])
			autocmds[client.id .. "_extra"] = nil
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

				-- backfill deletes
				local new_map = {}
				scan_tree(client.config.root_dir, new_map)

				local evs = {}
				for path, _ in pairs(old_snapshot) do
					if new_map[path] == nil then
						close_deleted_buffers(path)
						table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
					end
				end
				if #evs > 0 then
					notify("Backfilled " .. #evs .. " deletes after restart", vim.log.levels.DEBUG)
					queue_events(client.id, evs)
				end

				snapshots[client.id] = new_map
			end
		end, 300)
	end

	local function resync_snapshot()
		local new_map = {}
		scan_tree(root, new_map)

		if not snapshots[client.id] then
			snapshots[client.id] = {}
		end

		local old_map = vim.deepcopy(snapshots[client.id])
		local evs = {}

		-- detect deletes
		for path, _ in pairs(old_map) do
			if new_map[path] == nil then
				close_deleted_buffers(path)
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
			end
		end

		-- detect creates
		for path, mt in pairs(new_map) do
			if old_map[path] == nil then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
			end
		end

		if #evs > 0 then
			notify("Resynced " .. #evs .. " changes from snapshot", vim.log.levels.DEBUG)
			queue_events(client.id, evs)
		end

		-- replace snapshot
		snapshots[client.id] = new_map
		last_events[client.id] = os.time()
	end

	-- -------- fs_event --------
	local handle, err = uv.new_fs_event()
	if not handle then
		notify("Failed to create fs_event: " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	local ok, start_err = pcall(function()
		handle:start(root, { recursive = true }, function(err2, filename, events)
			if err2 then
				notify("Watcher error: " .. tostring(err2), vim.log.levels.ERROR)
				restart_watcher()
				return
			end
			if not filename then
				notify("fs_event filename=nil -> resync + restart", vim.log.levels.DEBUG)
				resync_snapshot()
				restart_watcher()
				return
			end

			local fullpath = root .. "/" .. filename
			if not should_watch(fullpath) then
				return
			end

			last_events[client.id] = os.time()

			local st = uv.fs_stat(fullpath)
			local evs = {}

			if events.change then
				if st then
					snapshots[client.id][fullpath] = mtime_ns(st)
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
				else
					snapshots[client.id][fullpath] = nil
					close_deleted_buffers(fullpath)
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
				end
			elseif events.rename then
				if st then
					snapshots[client.id][fullpath] = mtime_ns(st)
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
				else
					snapshots[client.id][fullpath] = nil
					close_deleted_buffers(fullpath)
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
				end
			end

			if #evs > 0 then
				queue_events(client.id, evs)
			end
		end)
	end)

	if not ok then
		notify("Failed to start watcher: " .. tostring(start_err), vim.log.levels.ERROR)
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

		for path, mt in pairs(new_map) do
			local old_mt = old_map[path]
			if not old_mt then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
			elseif old_mt ~= mt then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
			end
		end

		for path, _ in pairs(old_map) do
			if new_map[path] == nil then
				close_deleted_buffers(path)
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
			end
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
		else
			snapshots[client.id] = new_map
		end
	end)
	pollers[client.id] = poller

	-- -------- watchdog --------
	local watchdog = uv.new_timer()
	watchdog:start(15000, 15000, function()
		if watchers[client.id] and not client.is_stopped() then
			local last = last_events[client.id] or 0
			if os.time() - last > WATCHDOG_IDLE then
				notify("Idle " .. WATCHDOG_IDLE .. "s, recycling watcher", vim.log.levels.DEBUG)
				resync_snapshot()
				restart_watcher()
			end
		end
	end)
	watchdogs[client.id] = watchdog

	-- -------- autocmds --------
	local id = vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		callback = function(args)
			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and bufpath:sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					notify("Buffer closed for deleted file: " .. bufpath .. " -> resync snapshot", vim.log.levels.DEBUG)
					resync_snapshot()
				end
			end
		end,
	})
	autocmds[client.id] = id

	local id2 = vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FileChangedRO" }, {
		callback = function(args)
			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and bufpath:sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					notify(
						"File vanished while buffer open: " .. bufpath .. " -> resync snapshot",
						vim.log.levels.DEBUG
					)
					resync_snapshot()
				end
			end
		end,
	})
	autocmds[client.id .. "_earlycheck"] = id2

	-- extra check for open-but-deleted files
	local id3 = vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		callback = function(args)
			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and bufpath:sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					notify(
						"File missing but buffer still open: " .. bufpath .. " -> resync snapshot",
						vim.log.levels.DEBUG
					)
					resync_snapshot()
				end
			end
		end,
	})
	autocmds[client.id .. "_extra"] = id3

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
