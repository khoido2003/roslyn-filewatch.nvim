local M = {}

M.options = {
	batching = {
		enabled = true,
		interval = 100,
	},
	ignore_dirs = {
		"Library",
		"Temp",
		"Logs",
		"Obj",
		"Bin",
		".git",
		".idea",
		".vs",
	},
	watch_extensions = { ".cs", ".csproj", ".sln" },

	--- Which LSP client names should trigger watching
	client_names = { "roslyn", "roslyn_ls" },
}

M.setup = function(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
