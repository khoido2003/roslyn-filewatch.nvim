local config = require("roslyn_filewatch.config")
local watcher = require("roslyn_filewatch.watcher")

local M = {}

M.setup = function(opts)
	config.setup(opts)

	vim.api.nvim_create_autocmd("LspAttach", {
		callback = function(args)
			local client = vim.lsp.get_client_by_id(args.data.client_id)
			if client and (client.name == "roslyn" or client.name == "roslyn_ls") then
				watcher.start(client)
			end
		end,
	})
end

return M
