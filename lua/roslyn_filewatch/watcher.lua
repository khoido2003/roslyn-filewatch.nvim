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
	-- uv.fs_stat on Windows provides { sec, nsec }
	return (stat.mtime.sec or 0) * 1e9 + (stat.mtime.nsec or 0)
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
				-- skip ignored directories
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
	end

	local function restart_watcher()
		if restart_scheduled[client.id] then
			return -- debounce
		end
		restart_scheduled[client.id] = true
		vim.defer_fn(function()
			restart_scheduled[client.id] = nil
			cleanup()
			if not client.is_stopped() then
				notify("Restarting watcher for client " .. client.name, vim.log.levels.DEBUG)
				M.start(client)
			end
		end, 300) -- debounce 300ms
	end

	-- -------- fs_event (fine-grained events) --------
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
				notify("Watcher invalidated (filename=nil), restarting...", vim.log.levels.DEBUG)
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
					-- Changed
					snapshots[client.id][fullpath] = mtime_ns(st)
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
				else
					-- Deleted
					snapshots[client.id][fullpath] = nil
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
					-- do NOT restart here; poller & fs_event will recover if still live
				end
			elseif events.rename then
				if st then
					-- Created (or moved in)
					snapshots[client.id][fullpath] = mtime_ns(st)
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
				else
					-- Deleted (or moved out)
					snapshots[client.id][fullpath] = nil
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
				end
				-- Avoid immediate restart; rely on poller if fs_event dies silently
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

	-- Initialize snapshot for poller
	snapshots[client.id] = {}
	scan_tree(root, snapshots[client.id])

	-- -------- fs_poll (snapshot diff / resync) --------
	local poller = uv.new_fs_poll()
	-- 3000ms is a good balance for Unity projects
	poller:start(root, 3000, function(errp, prev, curr)
		if errp then
			notify("Poller error: " .. tostring(errp), vim.log.levels.ERROR)
			return
		end

		-- If the root directory's identity changed (replacement), a restart helps.
		if
			prev
			and curr
			and (prev.mtime ~= curr.mtime)
			and (prev.mtime and curr.mtime)
			and (prev.mtime.sec ~= curr.mtime.sec or prev.mtime.nsec ~= curr.mtime.nsec)
		then
			notify("Poller detected directory metadata change; restarting watcher", vim.log.levels.DEBUG)
			restart_watcher()
			return
		end

		-- Build new snapshot and diff with previous
		local new_map = {}
		scan_tree(root, new_map)

		local old_map = snapshots[client.id] or {}
		local evs = {}

		-- Detect Created / Changed
		for path, mt in pairs(new_map) do
			local old_mt = old_map[path]
			if not old_mt then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 }) -- Created
			elseif old_mt ~= mt then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 }) -- Changed
			end
		end

		-- Detect Deleted
		for path, _ in pairs(old_map) do
			if new_map[path] == nil then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 }) -- Deleted
			end
		end

		if #evs > 0 then
			snapshots[client.id] = new_map
			queue_events(client.id, evs)
			last_events[client.id] = os.time()
		else
			-- Keep the snapshot fresh even if no diffs (handles timestamp-only drift)
			snapshots[client.id] = new_map
		end
	end)
	pollers[client.id] = poller

	-- -------- watchdog timer (safety) --------
	local watchdog = uv.new_timer()
	watchdog:start(15000, 15000, function()
		if watchers[client.id] and not client.is_stopped() then
			local last = last_events[client.id] or 0
			-- If absolutely nothing has happened for a long while, recycle.
			if os.time() - last > 60 then
				notify("No fs activity for 60s, recycling watcher (safety)", vim.log.levels.DEBUG)
				restart_watcher()
			end
		end
	end)
	watchdogs[client.id] = watchdog

	notify("Watcher started for client " .. client.name .. " at root: " .. root, vim.log.levels.DEBUG)

	vim.api.nvim_create_autocmd("LspDetach", {
		once = true,
		callback = function(args)
			if args.data.client_id == client.id then
				if snapshots[client.id] then
					snapshots[client.id] = nil
				end
				if restart_scheduled[client.id] then
					restart_scheduled[client.id] = nil
				end
				cleanup()
				notify("LspDetach: Watcher stopped for client " .. client.name, vim.log.levels.DEBUG)
			end
		end,
	})
end

return M
