---@class roslyn_filewatch.health
---Healthcheck module for roslyn-filewatch.nvim

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_fn = health.error or health.report_error
local info = health.info or health.report_info

--- Check Neovim version
local function check_neovim_version()
	local version = vim.version()
	local version_str = string.format("%d.%d.%d", version.major, version.minor, version.patch)

	if version.major >= 0 and version.minor >= 10 then
		ok("Neovim version: " .. version_str .. " (>= 0.10 recommended)")
	elseif version.major >= 0 and version.minor >= 9 then
		warn("Neovim version: " .. version_str .. " (0.10+ recommended for best experience)")
	else
		error_fn("Neovim version: " .. version_str .. " (0.9+ required)")
	end
end

--- Check libuv availability
local function check_libuv()
	local uv = vim.uv or vim.loop
	if uv then
		ok("libuv available via " .. (vim.uv and "vim.uv" or "vim.loop"))
	else
		error_fn("libuv not available - file watching will not work")
		return
	end

	-- Check fs_event capability
	local test_handle = uv.new_fs_event()
	if test_handle then
		ok("uv.new_fs_event() available")
		pcall(function()
			test_handle:close()
		end)
	else
		warn("uv.new_fs_event() failed - plugin will use polling fallback")
	end

	-- Check fs_poll capability
	local test_poll = uv.new_fs_poll()
	if test_poll then
		ok("uv.new_fs_poll() available")
		pcall(function()
			test_poll:close()
		end)
	else
		error_fn("uv.new_fs_poll() failed - polling fallback not available")
	end
end

--- Check platform
local function check_platform()
	local utils = require("roslyn_filewatch.watcher.utils")
	local is_win = utils.is_windows()

	local uv = vim.uv or vim.loop
	local uname = uv.os_uname()
	local sysname = uname and uname.sysname or "unknown"

	info("Platform: " .. sysname)

	if is_win then
		info("Windows detected - fs_event enabled with EPERM error recovery")
	elseif sysname:match("Darwin") then
		info("macOS detected - FSEvents may have inherent latency (1-5 seconds)")
	elseif sysname:match("Linux") then
		ok("Linux detected - inotify should work well")
	end
end

--- Check Roslyn LSP clients
local function check_roslyn_clients()
	local config = require("roslyn_filewatch.config")
	local client_names = config.options.client_names or {}

	info("Configured client names: " .. vim.inspect(client_names))

	local clients = vim.lsp.get_clients()
	local found_roslyn = false

	for _, client in ipairs(clients) do
		if vim.tbl_contains(client_names, client.name) then
			found_roslyn = true
			ok("Found active Roslyn client: " .. client.name .. " (id: " .. client.id .. ")")

			if client.config and client.config.root_dir then
				info("  Root directory: " .. client.config.root_dir)
			end
		end
	end

	if not found_roslyn then
		if #clients > 0 then
			warn("No active Roslyn clients found. Active LSP clients:")
			for _, client in ipairs(clients) do
				info("  - " .. client.name .. " (id: " .. client.id .. ")")
			end
			info("Make sure your Roslyn LSP client name matches one of: " .. vim.inspect(client_names))
		else
			warn("No active LSP clients. Open a C# file to attach the Roslyn LSP.")
		end
	end
end

--- Check configuration
local function check_config()
	local config = require("roslyn_filewatch.config")
	local opts = config.options

	info("Batching: " .. (opts.batching and opts.batching.enabled and "enabled" or "disabled"))
	if opts.batching and opts.batching.enabled then
		info("  Interval: " .. (opts.batching.interval or 300) .. "ms")
	end

	info("Poll interval: " .. (opts.poll_interval or 3000) .. "ms")
	info("Watchdog idle timeout: " .. (opts.watchdog_idle or 60) .. "s")
	info("Rename detection window: " .. (opts.rename_detection_ms or 300) .. "ms")

	if opts.force_polling then
		warn("force_polling is enabled - native file watching is disabled")
	else
		ok("Native file watching enabled (with polling fallback)")
	end

	info("Ignored directories: " .. #(opts.ignore_dirs or {}) .. " configured")
	info("Watch extensions: " .. #(opts.watch_extensions or {}) .. " configured")

	local log_level = opts.log_level or 3
	local level_names = { [0] = "TRACE", [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }
	info("Log level: " .. (level_names[log_level] or tostring(log_level)))
end

--- Main health check function
function M.check()
	start("roslyn-filewatch.nvim")

	start("Neovim Version")
	check_neovim_version()

	start("libuv Capabilities")
	check_libuv()

	start("Platform Detection")
	check_platform()

	start("Roslyn LSP Clients")
	check_roslyn_clients()

	start("Configuration")
	check_config()
end

return M
