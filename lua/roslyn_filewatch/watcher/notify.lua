local M = {}

local config = require("roslyn_filewatch.config")

-- helper: read configured log level
local function configured_log_level()
	local ok, lvl = pcall(function()
		return (config and config.options and config.options.log_level)
	end)
	if not ok or lvl == nil then
		-- fallback to INFO if something unexpected happens
		if vim.log and vim.log.levels and vim.log.levels.INFO then
			return vim.log.levels.INFO
		end
		return 2
	end
	return lvl
end

-- check whether a message at 'level' should be shown given configured threshold
local function should_emit(level)
	level = level or (vim.log and vim.log.levels and vim.log.levels.INFO) or 2
	local cfg_level = configured_log_level()
	-- vim.log.levels are numeric where smaller = more verbose (TRACE=0,...,ERROR=4)
	-- show messages whose level is >= cfg_level.
	return level >= cfg_level
end

function M.user(msg, level)
	level = level or (vim.log and vim.log.levels and vim.log.levels.INFO) or 2
	if not should_emit(level) then
		return
	end
	vim.schedule(function()
		local notify = vim.notify or print
		pcall(function()
			notify("[roslyn-filewatch] " .. tostring(msg), level)
		end)
	end)
end

-- send workspace/didChangeWatchedFiles
function M.roslyn_changes(changes)
	local config = require("roslyn_filewatch.config")
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			pcall(function()
				client.notify("workspace/didChangeWatchedFiles", { changes = changes })
			end)
		end
	end
end

-- send workspace/didRenameFiles
function M.roslyn_renames(files)
	local config = require("roslyn_filewatch.config")
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
			vim.schedule(function()
				pcall(function()
					client.notify("workspace/didRenameFiles", payload)
				end)
			end)
		end
	end
end

return M
