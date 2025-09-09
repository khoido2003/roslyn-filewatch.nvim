local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat
local same_file_info = utils.same_file_info
local normalize_path = utils.normalize_path

local M = {}

local watchers = {}
local pollers = {}
local batch_queues = {}
local watchdogs = {}
local snapshots = {} -- client_id -> { [path]= { mtime, size, ino, dev } }
local last_events = {} -- client_id -> os.time()
local restart_scheduled = {} -- client_id -> true
local autocmds = {} -- client_id -> { id_main = ..., id_early = ..., id_extra = ... }

-- pending_deletes[client_id] = { map = { identity -> { path, uri, ts, stat_entry } }, timer = uv_timer }
local pending_deletes = {}

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

-- helper to notify renames (uses direct LSP "didRenameFiles")
local function notify_roslyn_renames(files)
	-- files: { { old = oldPath, new = newPath }, ... } OR items with oldUri/newUri already
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			local payload = { files = {} }
			for _, p in ipairs(files) do
				table.insert(payload.files, {
					oldUri = p.oldUri or vim.uri_from_fname(p.old),
					newUri = p.newUri or vim.uri_from_fname(p["new"]),
				})
			end
			-- schedule notify to be safe with event loop context
			vim.schedule(function()
				pcall(function()
					client.notify("workspace/didRenameFiles", payload)
				end)
			end)
		end
	end
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
						-- store additional fields for rename detection (ino/dev when available)
						out_map[fullpath] = {
							mtime = mtime_ns(st),
							size = st.size,
							ino = st.ino,
							dev = st.dev,
						}
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
		if pending_deletes[client.id] then
			pcall(function()
				local pd = pending_deletes[client.id]
				if pd.timer and not pd.timer:is_closing() then
					pd.timer:stop()
					pd.timer:close()
				end
			end)
			pending_deletes[client.id] = nil
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

	-- Resync snapshot with rename detection
	local function resync_snapshot()
		local new_map = {}
		scan_tree(root, new_map)

		if not snapshots[client.id] then
			snapshots[client.id] = {}
		end

		local old_map = vim.deepcopy(snapshots[client.id])
		local evs = {}
		local saw_delete = false
		local rename_pairs = {}

		-- build old identity map for quick lookup
		local old_id_map = {}
		for path, entry in pairs(old_map) do
			local id = identity_from_stat(entry)
			if id then
				old_id_map[id] = path
			end
		end

		-- detect creates / renames / changes
		for path, mt in pairs(new_map) do
			if old_map[path] == nil then
				-- possible create OR rename (match by identity)
				local id = identity_from_stat(mt)
				local oldpath = id and old_id_map[id]
				if oldpath then
					-- rename detected: remember it, and remove old_map entry so it won't be treated as delete
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

		-- detect deletes (remaining entries in old_map)
		for path, _ in pairs(old_map) do
			saw_delete = true
			close_deleted_buffers(path)
			table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
		end

		-- send rename notifications first (if any)
		if #rename_pairs > 0 then
			notify("Resynced and detected " .. #rename_pairs .. " renames", vim.log.levels.DEBUG)
			-- send renames via LSP
			notify_roslyn_renames(rename_pairs)
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

	-- ********** helper to flush pending deletes (single-shot timer created per first pending delete) **********
	local function schedule_pending_delete_flush()
		if pending_deletes[client.id] and pending_deletes[client.id].timer then
			return
		end
		local t = uv.new_timer()
		-- one-shot after RENAME_WINDOW_MS
		t:start(RENAME_WINDOW_MS, 0, function()
			-- collect and flush all pending deletes for this client
			local pd = pending_deletes[client.id]
			if not pd or not pd.map then
				pcall(function()
					if t and not t:is_closing() then
						t:stop()
						t:close()
					end
				end)
				pending_deletes[client.id] = nil
				return
			end

			local evs = {}
			for id, ent in pairs(pd.map) do
				-- remove from snapshot and queue delete events
				if snapshots[client.id] and snapshots[client.id][ent.path] then
					snapshots[client.id][ent.path] = nil
				end
				close_deleted_buffers(ent.path)
				table.insert(evs, { uri = ent.uri, type = 3 })
			end

			-- cleanup
			pcall(function()
				if t and not t:is_closing() then
					t:stop()
					t:close()
				end
			end)
			pending_deletes[client.id] = nil

			if #evs > 0 then
				vim.schedule(function()
					queue_events(client.id, evs)
				end)
			end
		end)
		pending_deletes[client.id] = pending_deletes[client.id] or {}
		pending_deletes[client.id].timer = t
		pending_deletes[client.id].map = pending_deletes[client.id].map or {}
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
				-- created or changed
				local mt = mtime_ns(st)
				-- prepare snapshot entry for new file
				local new_entry = { mtime = mt, size = st.size, ino = st.ino, dev = st.dev }

				-- rename-detection: try match against pending deletes (identity)
				local id = identity_from_stat(st)
				local matched = false
				if
					id
					and pending_deletes[client.id]
					and pending_deletes[client.id].map
					and pending_deletes[client.id].map[id]
				then
					-- Treat as rename
					local del_ent = pending_deletes[client.id].map[id]
					-- remove pending delete
					pending_deletes[client.id].map[id] = nil

					-- cleanup timer if empty
					if pending_deletes[client.id].map and next(pending_deletes[client.id].map) == nil then
						if pending_deletes[client.id].timer and not pending_deletes[client.id].timer:is_closing() then
							pcall(function()
								pending_deletes[client.id].timer:stop()
								pending_deletes[client.id].timer:close()
							end)
						end
						pending_deletes[client.id] = nil
					end

					-- update snapshot: move old -> new
					if snapshots[client.id] then
						snapshots[client.id][del_ent.path] = nil
					end
					snapshots[client.id][fullpath] = new_entry

					-- send rename notification
					notify("Detected rename: " .. del_ent.path .. " -> " .. fullpath, vim.log.levels.DEBUG)
					notify_roslyn_renames({ { old = del_ent.path, ["new"] = fullpath } })

					matched = true
					-- do not insert a create event
				end

				if not matched then
					-- not a rename -> normal behavior
					snapshots[client.id][fullpath] = new_entry
					if not prev_mt then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
					elseif not same_file_info(prev_mt, snapshots[client.id][fullpath]) then
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
					end
				end
			else
				-- path gone -> buffer the delete so we can match a possible near-future create (rename)
				if prev_mt then
					-- compute identity from snapshot entry
					local id = identity_from_stat(prev_mt)
					if id then
						-- add to pending deletes map
						pending_deletes[client.id] = pending_deletes[client.id] or { map = {} }
						pending_deletes[client.id].map = pending_deletes[client.id].map or {}
						pending_deletes[client.id].map[id] = {
							path = fullpath,
							uri = vim.uri_from_fname(fullpath),
							ts = uv.hrtime(),
							stat = prev_mt,
						}
						-- schedule flush after the window
						schedule_pending_delete_flush()
						-- do not remove snapshot yet; flush will remove it if not matched
					else
						-- fallback: if we can't compute identity, behave as before (immediate delete)
						if snapshots[client.id] then
							snapshots[client.id][fullpath] = nil
						end
						close_deleted_buffers(fullpath)
						table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
						-- restart to be safe if a delete happened in fast-path
						restart_watcher()
					end
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
