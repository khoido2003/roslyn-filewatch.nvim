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
		"Build",
		"Builds",
		"UserSettings",
		"MemoryCaptures",
		"CrashReports",
	},

	watch_extensions = {
		".cs",
		".csproj",
		".sln",
		".props",
		".targets",
		".editorconfig",
		".razor",
		".config",
		".json",
	},

	--- Which LSP client names should trigger watching
	client_names = { "roslyn", "roslyn_ls" },

	--- Poller interval in ms (used for fallback resync scan)
	poll_interval = 3000,

	--- If poller detects changes while fs_event was quiet for this many seconds,
	--- we restart the watcher (heals silent-death cases).
	poller_restart_threshold = 2,

	--- If absolutely no fs activity for this many seconds, restart watcher (safety).
	watchdog_idle = 60,
}

M.setup = function(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
