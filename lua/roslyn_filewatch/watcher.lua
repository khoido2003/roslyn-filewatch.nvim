local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

local M = {}

local watchers = {}
local batch_queues = {}

-- ///////////////////////////////////////////////////////////
-- HELPERS
-- ///////////////////////////////////////////////////////////

local function notify(msg, level)
	-- use nvim-notify if available
	vim.schedule(function()
		vim.notify("[roslyn-filewatch] " .. msg, level or vim.log.levels.INFO)
	end)
end

--- Send file changes to Roslyn
local function notify_roslyn(changes)
	local clients = vim.lsp.get_clients()
	local sent = false
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			client.notify("workspace/didChangeWatchedFiles", { changes = changes })
			sent = true
		end
	end
	if not sent then
		notify("No matching LSP client to notify", vim.log.levels.WARN)
	end
end

--- Check if path should be watched
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

-- ///////////////////////////////////////////////////////////
-- CORE WATCH LOGIC
-- ///////////////////////////////////////////////////////////

M.start = function(client)
	if watchers[client.id] then
		notify("Watcher already running for client " .. client.name)
		return
	end

	local root = client.config.root_dir
	if not root then
		notify("No root_dir for client " .. client.name, vim.log.levels.ERROR)
		return
	end

	local handle, err = uv.new_fs_event()
	if not handle then
		notify("Failed to create fs_event: " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	local ok, start_err = pcall(function()
		handle:start(root, { recursive = true }, function(err, filename, events)
			if err then
				notify("Error in watcher: " .. tostring(err), vim.log.levels.ERROR)
				return
			end

			if not filename then
				notify("Watcher invalidated, restarting...", vim.log.levels.WARN)
				handle:stop()
				watchers[client.id] = nil
				vim.schedule(function()
					if not client.is_stopped() then
						M.start(client)
					end
				end)
				return
			end

			local fullpath = root .. "/" .. filename
			if not should_watch(fullpath) then
				return
			end

			local evs = {}
			if events.change then
				table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 2 })
			elseif events.rename then
				table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 1 })
				table.insert(evs, { uri = vim.uri_from_fname(fullpath), type = 3 })
			end

			if #evs == 0 then
				return
			end

			if config.options.batching.enabled then
				if not batch_queues[client.id] then
					batch_queues[client.id] = { events = {}, timer = nil }
				end
				local queue = batch_queues[client.id]
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
								notify("Sending " .. #changes .. " file changes to Roslyn")
								notify_roslyn(changes)
							end)
						end
					end)
				end
			else
				notify("Sending " .. #evs .. " file change(s) to Roslyn")
				notify_roslyn(evs)
			end
		end)
	end)

	if not ok then
		notify("Failed to start watcher: " .. tostring(start_err), vim.log.levels.ERROR)
		return
	end

	watchers[client.id] = handle
	notify("Watcher started for client " .. client.name .. " at root: " .. root)

	vim.api.nvim_create_autocmd("LspDetach", {
		once = true,
		callback = function(args)
			if args.data.client_id == client.id then
				handle:stop()
				watchers[client.id] = nil
				if batch_queues[client.id] then
					if batch_queues[client.id].timer then
						batch_queues[client.id].timer:stop()
						batch_queues[client.id].timer:close()
					end
					batch_queues[client.id] = nil
				end
				notify("Watcher stopped for client " .. client.name)
			end
		end,
	})
end

return M
