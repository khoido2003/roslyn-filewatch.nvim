local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

local M = {}

local watchers = {}
local batch_queues = {}

-- ///////////////////////////////////////////////////////////
-- HELPERS
-- ///////////////////////////////////////////////////////////

--- Send file changes to Roslyn (or any configured C# server)
---@param changes table
local function notify_roslyn(changes)
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			client.notify("workspace/didChangeWatchedFiles", {
				changes = changes,
			})
		end
	end
end

--- Check if path should be watched
---@param path string
---@return boolean
local function should_watch(path)
	-- skip ignored dirs
	for _, dir in ipairs(config.options.ignore_dirs) do
		if path:find("[/\\]" .. dir .. "[/\\]") then
			return false
		end
	end

	-- allow listed extensions
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

--- Start watching for file changes
---@param client table LSP client
M.start = function(client)
	if watchers[client.id] then
		return
	end

	local root = client.config.root_dir
	if not root then
		return
	end

	local handle = uv.new_fs_event()

	handle:start(root, { recursive = true }, function(err, filename, events)
		if err then
			return
		end

		-- watcher invalidated (common on Linux after deletes)
		if not filename then
			handle:stop()
			watchers[client.id] = nil
			vim.schedule(function()
				if client.is_stopped() then
					return
				end
				M.start(client)
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
							notify_roslyn(changes)
						end)
					end
				end)
			end
		else
			notify_roslyn(evs)
		end
	end)

	watchers[client.id] = handle

	-- cleanup
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
			end
		end,
	})
end

return M
