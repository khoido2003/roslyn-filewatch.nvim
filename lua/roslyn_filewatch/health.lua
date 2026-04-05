---@class roslyn_filewatch.health

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_fn = health.error or health.report_error
local info = health.info or health.report_info

local config = require("roslyn_filewatch.config")

local function check_neovim()
  local v = vim.version()
  local str = string.format("%d.%d.%d", v.major, v.minor, v.patch)

  if v.major > 0 or (v.major == 0 and v.minor >= 10) then
    ok("Neovim " .. str)
  elseif v.major == 0 and v.minor >= 9 then
    warn("Neovim " .. str .. " (0.10+ recommended)")
  else
    error_fn("Neovim " .. str .. " (0.9+ required)")
  end
end

local function check_platform()
  local uv = vim.uv or vim.loop
  local uname = uv.os_uname()
  local sysname = uname and uname.sysname or "unknown"

  if sysname == "Linux" then
    local handle = io.open("/proc/sys/fs/inotify/max_user_watches", "r")
    if handle then
      local limit = tonumber(handle:read("*a"))
      handle:close()
      if limit and limit < 524288 then
        warn("inotify max_user_watches: " .. tostring(limit) .. " (recommend >= 524288)")
      else
        ok("inotify limit: " .. tostring(limit))
      end
    end
  else
    ok("Platform: " .. sysname)
  end
end

local function check_tools()
  -- Rust module
  local rs_ok, rs = pcall(require, "roslyn_filewatch_rs")
  if rs_ok and rs and rs.fast_snapshot then
    ok("Rust native module: found")
  else
    warn("Rust native module: missing")
  end

  -- fd
  if vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1 then
    ok("fd/fdfind: found")
  else
    warn("fd/fdfind: missing")
  end

  -- Watcher backends
  local backends = {}
  if vim.fn.executable("watchman") == 1 then
    table.insert(backends, "watchman")
  end
  if vim.fn.executable("fswatch") == 1 then
    table.insert(backends, "fswatch")
  end
  if #backends > 0 then
    ok("External tools: " .. table.concat(backends, ", "))
  else
    info("External tools: none")
  end

  -- dotnet
  if vim.fn.executable("dotnet") == 1 then
    ok("dotnet: found")
  else
    warn("dotnet: missing (autorestore disabled)")
  end
end

local function check_configuration()
  local opts = config.options or {}

  local function report_bool(name, val)
    if val then
      ok(name .. ": enabled")
    else
      info(name .. ": disabled")
    end
  end

  report_bool("solution_aware", opts.solution_aware ~= false)
  report_bool("respect_gitignore", opts.respect_gitignore ~= false)
  report_bool("batching", opts.batching and opts.batching.enabled)
  report_bool("autorestore", opts.enable_autorestore ~= false)

  if opts.force_polling then
    warn("force_polling: enabled (performance impact)")
  end
end

local function check_active_clients()
  local clients = vim.lsp.get_clients()
  local roslyn_clients = {}
  local names = config.options.client_names or {}

  for _, c in ipairs(clients) do
    if vim.tbl_contains(names, c.name) then
      table.insert(roslyn_clients, string.format("%s (id: %d)", c.name, c.id))
    end
  end

  if #roslyn_clients > 0 then
    ok("LSP Clients: " .. table.concat(roslyn_clients, ", "))
  else
    warn("LSP Clients: none active")
  end
end

local function check_watcher_logic()
  local backend_mod_ok, backend_mod = pcall(require, "roslyn_filewatch.watcher.backends.init")
  if not backend_mod_ok then
    error_fn("Backend module load failed")
    return
  end

  local force_polling = config.options.force_polling
  local best_backend, best_name = backend_mod.get_best_backend()

  if force_polling then
    warn("Backend Strategy: FORCED POLLING")
  elseif best_backend then
    ok("Backend Strategy: " .. best_name:upper() .. " (preferred)")
  else
    warn("Backend Strategy: POLLING (fallback, native tools missing)")
  end

  local status_mod_ok, status_mod = pcall(require, "roslyn_filewatch.status")
  if status_mod_ok and status_mod.get_status then
    local status = status_mod.get_status()
    for _, c in ipairs(status.clients) do
      local backend = c.backend or "unknown"
      ok(string.format("Client %d (%s) Active Backend: %s", c.id, c.name, backend:upper()))
    end
  end

  local rs_ok, rs = pcall(require, "roslyn_filewatch_rs")
  if rs_ok and rs and rs.fast_snapshot then
    ok("Active Scanner: RUST NATIVE")
  elseif vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1 then
    ok("Active Scanner: FD ASYNC")
  else
    info("Active Scanner: LUA (fallback)")
  end
end

function M.check()
  start("roslyn-filewatch: System")
  check_neovim()
  check_platform()
  check_tools()

  start("roslyn-filewatch: Runtime")
  check_active_clients()
  check_watcher_logic()

  start("roslyn-filewatch: Configuration")
  check_configuration()
end

return M
