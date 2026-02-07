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

    -- Check inotify limits
    local handle = io.open("/proc/sys/fs/inotify/max_user_watches", "r")
    if handle then
      local content = handle:read("*a")
      handle:close()
      local limit = tonumber(content)
      if limit and limit < 524288 then
        warn("Low fs.inotify.max_user_watches: " .. tostring(limit))
        info("Suggest increasing limit for large projects:")
        info("echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf && sudo sysctl -p")
      else
        ok("fs.inotify.max_user_watches: " .. tostring(limit))
      end
    end
  end
end

--- Check external tools
local function check_external_tools()
  if vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1 then
    ok("fd found (accelerated scanning enabled)")
  else
    info("fd not found (using standard Lua scanning)")
    info("Install 'sharkdp/fd' for significantly faster startup on huge projects")
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

  -- Solution-aware watching status
  if opts.solution_aware ~= false then
    ok("Solution-aware watching enabled (parses .sln/.slnx/.slnf for project scope)")
  else
    info("Solution-aware watching disabled (scanning entire root)")
  end

  -- Gitignore support status
  if opts.respect_gitignore ~= false then
    ok("Gitignore support enabled (respects .gitignore patterns)")
  else
    info("Gitignore support disabled")
  end

  info("Ignored directories: " .. #(opts.ignore_dirs or {}) .. " configured")
  info("Watch extensions: " .. #(opts.watch_extensions or {}) .. " configured")

  local log_level = opts.log_level or 3
  local level_names = { [0] = "TRACE", [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }
  info("Log level: " .. (level_names[log_level] or tostring(log_level)))
end

--- Check recovery and watchdog status
local function check_recovery()
  local config = require("roslyn_filewatch.config")
  local client_names = config.options.client_names or {}

  -- Try to get watchdog recovery states
  local watchdog_ok, watchdog_mod = pcall(require, "roslyn_filewatch.watcher.watchdog")
  if not watchdog_ok or not watchdog_mod then
    info("Watchdog module not loaded (no active watchers)")
    return
  end

  local recovery_states = watchdog_mod.get_all_states and watchdog_mod.get_all_states() or {}
  local clients = vim.lsp.get_clients()

  local has_active_clients = false
  for _, client in ipairs(clients) do
    if vim.tbl_contains(client_names, client.name) then
      has_active_clients = true
      local state = recovery_states[client.id]

      info("Client: " .. client.name .. " (id: " .. client.id .. ")")

      if state then
        -- Health status
        local status = state.health_status or "unknown"
        if status == "healthy" then
          ok("  Status: " .. status)
        elseif status == "recovering" then
          warn("  Status: " .. status)
        elseif status == "degraded" then
          warn("  Status: " .. status .. " (snapshot may be stale)")
        else
          info("  Status: " .. status)
        end

        -- Consecutive failures
        local failures = state.consecutive_failures or 0
        local max_retries = config.options.recovery_max_retries or 5
        if failures == 0 then
          ok("  Consecutive failures: 0")
        elseif failures < max_retries then
          warn("  Consecutive failures: " .. failures .. "/" .. max_retries)
        else
          error_fn("  Consecutive failures: " .. failures .. "/" .. max_retries .. " (escalation threshold)")
        end

        -- Current backoff
        local backoff = state.current_backoff_ms or (config.options.recovery_initial_delay_ms or 300)
        local max_backoff = config.options.recovery_max_delay_ms or 30000
        if backoff <= (config.options.recovery_initial_delay_ms or 300) then
          info("  Backoff delay: " .. backoff .. "ms (initial)")
        elseif backoff >= max_backoff then
          warn("  Backoff delay: " .. backoff .. "ms (at maximum)")
        else
          info("  Backoff delay: " .. backoff .. "ms")
        end

        -- Stale detections
        local stale = state.stale_detections or 0
        if stale > 0 then
          warn("  Stale snapshot detections: " .. stale)
        end

        -- Last restart
        local last_restart = state.last_restart_time or 0
        if last_restart > 0 then
          local ago = os.time() - last_restart
          info("  Last restart: " .. ago .. "s ago")
        end

        -- Last deep check
        local last_deep = state.last_deep_check or 0
        if last_deep > 0 then
          local deep_ago = os.time() - last_deep
          info("  Last deep check: " .. deep_ago .. "s ago")
        end
      else
        info("  Recovery state: not initialized (watcher may be starting)")
      end
    end
  end

  if not has_active_clients then
    info("No active Roslyn clients. Recovery status will appear when a C# file is opened.")
  end

  -- Notification stats
  local notify_ok, notify_mod = pcall(require, "roslyn_filewatch.watcher.notify")
  if notify_ok and notify_mod and notify_mod.get_stats then
    local stats = notify_mod.get_stats()
    info("")
    info("Notification Statistics:")
    info("  Total notifications sent: " .. (stats.total_notifications or 0))
    if stats.last_success_time and stats.last_success_time > 0 then
      local ago = os.time() - stats.last_success_time
      if ago < 60 then
        ok("  Last successful: " .. ago .. "s ago")
      else
        info("  Last successful: " .. ago .. "s ago")
      end
    else
      info("  Last successful: never")
    end
  end

  -- Configuration summary
  info("")
  info("Recovery Configuration:")
  info("  Verify enabled: " .. tostring(config.options.recovery_verify_enabled ~= false))
  info("  Max retries: " .. (config.options.recovery_max_retries or 5))
  info("  Initial delay: " .. (config.options.recovery_initial_delay_ms or 300) .. "ms")
  info("  Max delay: " .. (config.options.recovery_max_delay_ms or 30000) .. "ms")
  info("  Fast check interval: " .. (config.options.watchdog_fast_interval_ms or 5000) .. "ms")
  info("  Deep check interval: " .. (config.options.watchdog_deep_interval_ms or 30000) .. "ms")
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

  start("External Tools")
  check_external_tools()

  start("Configuration")
  check_config()

  start("Recovery & Watchdog Status")
  check_recovery()
end

return M
