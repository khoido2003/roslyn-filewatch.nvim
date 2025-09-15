local M = {}

function M.user(msg, level)
	vim.schedule(function()
		vim.notify("[roslyn-filewatch] " .. msg, level or vim.log.levels.INFO)
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
