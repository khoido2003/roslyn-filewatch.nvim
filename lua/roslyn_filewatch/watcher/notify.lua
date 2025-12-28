---@class roslyn_filewatch.notify
---@field user fun(msg: string, level?: number)
---@field roslyn_changes fun(changes: roslyn_filewatch.FileChange[])
---@field roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])

---@class roslyn_filewatch.FileChange
---@field uri string File URI
---@field type number 1=Created, 2=Changed, 3=Deleted

---@class roslyn_filewatch.RenameEntry
---@field old string Old path
---@field new string New path
---@field oldUri? string Optional pre-computed old URI
---@field newUri? string Optional pre-computed new URI

local M = {}

local config = require("roslyn_filewatch.config")

--- Get the configured log level
---@return number
local function configured_log_level()
	local ok, lvl = pcall(function()
		return config and config.options and config.options.log_level
	end)
	if not ok or lvl == nil then
		-- fallback to WARN if something unexpected happens
		if vim.log and vim.log.levels and vim.log.levels.WARN then
			return vim.log.levels.WARN
		end
		return 3
	end
	return lvl
end

--- Check whether a message at 'level' should be shown given configured threshold
---@param level? number
---@return boolean
local function should_emit(level)
	level = level or (vim.log and vim.log.levels and vim.log.levels.INFO) or 2
	local cfg_level = configured_log_level()
	-- vim.log.levels are numeric where smaller = more verbose (TRACE=0,...,ERROR=4)
	-- show messages whose level is >= cfg_level.
	return level >= cfg_level
end

--- Send a notification to the user
---@param msg string
---@param level? number vim.log.levels value
function M.user(msg, level)
	level = level or (vim.log and vim.log.levels and vim.log.levels.INFO) or 2
	if not should_emit(level) then
		return
	end
	vim.schedule(function()
		local notify_fn = vim.notify or print
		pcall(function()
			notify_fn("[roslyn-filewatch] " .. tostring(msg), level)
		end)
	end)
end

--- Send workspace/didChangeWatchedFiles to all matching Roslyn clients
---@param changes roslyn_filewatch.FileChange[]
function M.roslyn_changes(changes)
	if not changes or #changes == 0 then
		return
	end

	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			pcall(function()
				client.notify("workspace/didChangeWatchedFiles", { changes = changes })
			end)
		end
	end
end

--- Send workspace/didRenameFiles to all matching Roslyn clients
---@param files roslyn_filewatch.RenameEntry[]
function M.roslyn_renames(files)
	if not files or #files == 0 then
		return
	end

	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			---@type { files: { oldUri: string, newUri: string }[] }
			local payload = { files = {} }
			for _, p in ipairs(files) do
				table.insert(payload.files, {
					oldUri = p.oldUri or vim.uri_from_fname(p.old),
					newUri = p.newUri or vim.uri_from_fname(p["new"]),
				})
			end
			vim.schedule(function()
				pcall(function()
					client.notify("workspace/didRenameFiles", payload)
				end)
			end)
		end
	end
end

return M
