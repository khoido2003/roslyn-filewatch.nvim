-- roslyn_filewatch/watcher.lua
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
local autocmds = {} -- client_id -> { id_main = ..., id_early = ..., id_extra = ... }

-- helper: compute mtime in nanoseconds
local function mtime_ns(stat)
	if not stat or not stat.mtime then
		return 0
	end
	return (stat.mtime.sec or 0) * 1e9 + (stat.mtime.nsec or 0)
end

local function same_file_info(a, b)
	if not a or not b then
		return false
	end
	return a.mtime == b.mtime and a.size == b.size
end

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

-- ================================================================
-- Path normalization (help comparing Windows/Unix slashes & drive case)
-- ================================================================
local function normalize_path(p)
	if not p or p == "" then
		return p
	end
	-- unify separators
	p = p:gsub("\\", "/")
	-- remove trailing slashes
	p = p:gsub("/+$", "")
	-- lowercase drive letter on Windows-style "C:/..."
	local drive = p:match("^([A-Za-z]):/")
	if drive then
		p = drive:lower() .. p:sub(2)
	end
	return p
end

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
-- Directory scan (for poller snapshot) — writes normalized paths into out_map
-- ================================================================
local function scan_tree(root, out_map)
	root = normalize_path(root)
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
			local fullpath = normalize_path(path .. "/" .. name)
			if typ == "directory" then
				local skip = false
				for _, dir in ipairs(config.options.ignore_dirs) do
					-- match "/dir/" or "/dir$" in normalized path
					if fullpath:find("/" .. dir .. "/") or fullpath:find("/" .. dir .. "$") then
						skip = true
						break
					end
				end
				if not skip then
					scan_dir(fullpath)
				end
			elseif typ == "file" then
				if
					(function(p)
						-- reuse should_watch-like logic but on normalized path
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
					end)(fullpath)
				then
					local st = uv.fs_stat(fullpath)
					if st then
						out_map[fullpath] = { mtime = mtime_ns(st), size = st.size }
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

	-- read tunables at start-time (so config.setup can be called before M.start)
	local POLL_INTERVAL = (config.options and config.options.poll_interval) or 3000 -- ms
	local POLLER_RESTART_THRESHOLD = (config.options and config.options.poller_restart_threshold) or 2 -- seconds
	local WATCHDOG_IDLE = (config.options and config.options.watchdog_idle) or 60 -- seconds

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

	local function resync_snapshot()
		local new_map = {}
		scan_tree(root, new_map)

		if not snapshots[client.id] then
			snapshots[client.id] = {}
		end

		local old_map = vim.deepcopy(snapshots[client.id])
		local evs = {}
		local saw_delete = false

		-- detect deletes
		for path, _ in pairs(old_map) do
			if new_map[path] == nil then
				saw_delete = true
				close_deleted_buffers(path)
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
			end
		end

		-- detect creates / changes
		for path, mt in pairs(new_map) do
			if old_map[path] == nil then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
			elseif not same_file_info(old_map[path], new_map[path]) then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
			end
		end

		if #evs > 0 then
			notify("Resynced " .. #evs .. " changes from snapshot", vim.log.levels.DEBUG)
			queue_events(client.id, evs)
			-- if deletes were found, restart to ensure fs_event isn't left in a bad state
			if saw_delete then
				restart_watcher()
			end
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
				resync_snapshot()
				restart_watcher()
				return
			end
			if not filename then
				notify("fs_event filename=nil -> resync + restart", vim.log.levels.DEBUG)
				resync_snapshot()
				restart_watcher()
				return
			end

			local fullpath = normalize_path(root .. "/" .. filename)
			-- check ignore list and watched extensions
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
			if not should_watch_path(fullpath) then
				return
			end

			last_events[client.id] = os.time()

			local st = uv.fs_stat(fullpath)
			local evs = {}

			-- determine created / changed / deleted by comparing snapshot
			local prev_mt = snapshots[client.id] and snapshots[client.id][fullpath]
			if st then
				local mt = mtime_ns(st)
				snapshots[client.id][fullpath] = { mtime = mt, size = st.size }
				if not prev_mt then
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
				elseif not same_file_info(prev_mt, snapshots[client.id][fullpath]) then
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
				end
			else
				if prev_mt then
					snapshots[client.id][fullpath] = nil
					close_deleted_buffers(fullpath)
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
					-- restart to be safe if a delete happened in fast-path
					restart_watcher()
				end
			end

			if #evs > 0 then
				queue_events(client.id, evs)
			end
		end)
	end)

	if not ok then
		notify("Failed to start watcher: " .. tostring(start_err), vim.log.levels.ERROR)
		-- ensure handle closed
		pcall(function()
			if handle and handle.close then
				handle:close()
			end
		end)
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

		for path, mt in pairs(new_map) do
			local old_mt = old_map[path]
			if not old_mt then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
			elseif not same_file_info(old_map[path], new_map[path]) then
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
			end
		end

		for path, _ in pairs(old_map) do
			if new_map[path] == nil then
				saw_delete = true
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
				resync_snapshot()
				restart_watcher()
				return
			end

			-- detect dead handle
			local h = watchers[client.id]
			if not h or (h.is_closing and h:is_closing()) then
				notify("Watcher handle missing/closed, restarting", vim.log.levels.DEBUG)
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
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					notify("Buffer closed for deleted file: " .. bufpath .. " -> resync+restart", vim.log.levels.DEBUG)
					resync_snapshot()
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
					resync_snapshot()
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
					resync_snapshot()
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
