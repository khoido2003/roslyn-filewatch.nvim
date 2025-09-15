local M = {}

M.options = {
	batching = {
		enabled = true,
		interval = 300,
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

	--- Window (ms) used to detect renames by buffering deletes and matching by identity.
	rename_detection_ms = 300,

	--- Debounce (ms) used to aggregate high-frequency fs events before processing.
	processing_debounce_ms = 80,

	--- Logging level for plugin notifications (controls what gets passed to vim.notify).
	--- Default: WARN (show only warnings and errors). Set to vim.log.levels.INFO or DEBUG
	--- to get more verbose notifications.
	--
	--- Valid values: vim.log.levels.TRACE, DEBUG, INFO, WARN, ERROR
	-- Example:
	--   require("roslyn_filewatch").setup({ log_level = vim.log.levels.ERROR })
	log_level = vim.log and vim.log.levels and vim.log.levels.WARN or 3,
}

M.setup = function(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
