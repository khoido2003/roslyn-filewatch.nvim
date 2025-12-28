---@class roslyn_filewatch.config
---@field options roslyn_filewatch.Options
---@field setup fun(opts?: roslyn_filewatch.Options)

---@class roslyn_filewatch.Options
---@field batching? roslyn_filewatch.BatchingOptions
---@field ignore_dirs? string[] Directories to ignore (exact segment match)
---@field watch_extensions? string[] File extensions to watch (with dots)
---@field client_names? string[] LSP client names to trigger watching
---@field poll_interval? number Poller interval in ms
---@field poller_restart_threshold? number Seconds threshold for poller restart
---@field watchdog_idle? number Seconds of idle before restarting watcher
---@field rename_detection_ms? number Window for rename detection
---@field processing_debounce_ms? number Debounce for processing events
---@field log_level? number vim.log.levels value
---@field force_polling? boolean Force polling mode (disable fs_event)

---@class roslyn_filewatch.BatchingOptions
---@field enabled? boolean Enable event batching
---@field interval? number Batch interval in ms

local M = {}

---@type roslyn_filewatch.Options
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
		"node_modules",
		"packages",
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
	---
	--- Valid values: vim.log.levels.TRACE, DEBUG, INFO, WARN, ERROR
	-- Example:
	--   require("roslyn_filewatch").setup({ log_level = vim.log.levels.ERROR })
	log_level = vim.log and vim.log.levels and vim.log.levels.WARN or 3,

	--- Force polling mode (disable fs_event entirely)
	--- Set to true if you experience issues with native file watching
	force_polling = false,
}

--- Setup the configuration with user options
---@param opts? roslyn_filewatch.Options
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
