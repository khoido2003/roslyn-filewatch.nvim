---@class roslyn_filewatch
---@field setup fun(opts?: roslyn_filewatch.Options)

local config = require("roslyn_filewatch.config")
local watcher = require("roslyn_filewatch.watcher")

local M = {}

--- Setup the roslyn-filewatch plugin
---@param opts? roslyn_filewatch.Options Configuration options
function M.setup(opts)
	config.setup(opts)

	vim.api.nvim_create_autocmd("LspAttach", {
		group = vim.api.nvim_create_augroup("RoslynFilewatch_LspAttach", { clear = true }),
		callback = function(args)
			local client = vim.lsp.get_client_by_id(args.data.client_id)
			if client and vim.tbl_contains(config.options.client_names, client.name) then
				watcher.start(client)
			end
		end,
	})
end

return M
