local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

local M = {}

local watchers = {}
local pollers = {}
local batch_queues = {}
local watchdogs = {}

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

	-- -------- fs_event (changes + rename) --------
	local handle, err = uv.new_fs_event()
	if not handle then
		notify("Failed to create fs_event: " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	local function restart_watcher()
		handle:stop()
		watchers[client.id] = nil
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
		vim.schedule(function()
			if not client.is_stopped() then
				M.start(client)
			end
		end)
	end

	local ok, start_err = pcall(function()
		handle:start(root, { recursive = true }, function(err, filename, events)
			if err then
				notify("Watcher error: " .. tostring(err), vim.log.levels.ERROR)
				restart_watcher()
				return
			end

			if not filename then
				notify("Watcher invalidated, restarting...", vim.log.levels.DEBUG)
				restart_watcher()
				return
			end

			local fullpath = root .. "/" .. filename
			if not should_watch(fullpath) then
				return
			end

			local stat = uv.fs_stat(fullpath)
			local evs = {}

			if events.change then
				if stat then
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 }) -- Changed
				else
					-- Deleted externally while buffer still open → restart
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 }) -- Deleted
					notify("File deleted, restarting watcher", vim.log.levels.DEBUG)
					restart_watcher()
				end
			elseif events.rename then
				if stat then
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 }) -- Created
				else
					table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 }) -- Deleted
				end
				notify("Rename detected, restarting watcher", vim.log.levels.DEBUG)
				restart_watcher()
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

	-- -------- fs_poll (create/delete fallback) --------
	local poller = uv.new_fs_poll()
	poller:start(root, 2000, function(err, prev, curr)
		if err then
			notify("Poller error: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		if not prev or not curr then
			return
		end
		-- Directory replaced or recreated
		if prev.mtime ~= curr.mtime then
			restart_watcher()
		end
	end)
	pollers[client.id] = poller

	-- -------- watchdog timer (safety) --------
	local watchdog = uv.new_timer()
	watchdog:start(10000, 10000, function()
		if watchers[client.id] and not client.is_stopped() then
			notify("No fs events for 10s, restarting watcher (safety)", vim.log.levels.DEBUG)
			restart_watcher()
		end
	end)
	watchdogs[client.id] = watchdog

	notify("Watcher started for client " .. client.name .. " at root: " .. root, vim.log.levels.DEBUG)

	vim.api.nvim_create_autocmd("LspDetach", {
		once = true,
		callback = function(args)
			if args.data.client_id == client.id then
				handle:stop()
				watchers[client.id] = nil
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
				notify("LspDetach: Watcher stopped for client " .. client.name, vim.log.levels.DEBUG)
			end
		end,
	})
end

return M
