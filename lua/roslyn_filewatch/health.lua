---@class roslyn_filewatch.health

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_fn = health.error or health.report_error
local info = health.info or health.report_info

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
  info("Platform: " .. sysname)

  if sysname == "Linux" then
    local handle = io.open("/proc/sys/fs/inotify/max_user_watches", "r")
    if handle then
      local limit = tonumber(handle:read("*a"))
      handle:close()
      if limit and limit < 524288 then
        warn("inotify max_user_watches: " .. tostring(limit) .. " (recommend >= 524288)")
      else
        ok("inotify max_user_watches: " .. tostring(limit))
      end
    end
  end
end

local function check_libuv()
  local uv = vim.uv or vim.loop
  if not uv then
    error_fn("libuv not available")
    return
  end
  ok("libuv: " .. (vim.uv and "vim.uv" or "vim.loop"))

  local test_handle = uv.new_fs_event()
  if test_handle then
    ok("uv.new_fs_event: available")
    pcall(test_handle.close, test_handle)
  else
    warn("uv.new_fs_event: unavailable (will use polling)")
  end

  local test_poll = uv.new_fs_poll()
  if test_poll then
    ok("uv.new_fs_poll: available")
    pcall(test_poll.close, test_poll)
  else
    error_fn("uv.new_fs_poll: unavailable")
  end
end

local function check_tools()
  -- Scanning tools (priority order)
  local rs_ok, rs = pcall(require, "roslyn_filewatch_rs")
  if rs_ok and rs and rs.fast_snapshot then
    ok("Rust module: loaded")
  else
    warn("Rust module: not loaded")
    info("  Build: :Lazy build roslyn-filewatch.nvim  OR  cd rust && cargo build --release")
    if not rs_ok then
      info("  Error: " .. tostring(rs))
    end
  end

  if vim.fn.executable("fd") == 1 then
    ok("fd: " .. vim.fn.exepath("fd"))
  elseif vim.fn.executable("fdfind") == 1 then
    ok("fdfind: " .. vim.fn.exepath("fdfind"))
  else
    warn("fd: not found")
    info("  https://github.com/sharkdp/fd#installation")
  end

  -- Watcher backends (priority order)
  if vim.fn.executable("watchman") == 1 then
    ok("watchman: " .. vim.fn.exepath("watchman"))
  else
    info("watchman: not found (optional)")
  end

  if vim.fn.executable("fswatch") == 1 then
    ok("fswatch: " .. vim.fn.exepath("fswatch"))
  else
    info("fswatch: not found (optional)")
  end

  -- dotnet CLI
  if vim.fn.executable("dotnet") == 1 then
    ok("dotnet: " .. vim.fn.exepath("dotnet"))
  else
    warn("dotnet: not found (auto-restore disabled)")
  end
end

local function check_active_tiers()
  local tiers = {}

  local rs_ok, rs = pcall(require, "roslyn_filewatch_rs")
  if rs_ok and rs and rs.fast_snapshot then
    table.insert(tiers, "✓ Rust native (active)")
  else
    table.insert(tiers, "✗ Rust native")
  end

  if vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1 then
    table.insert(tiers, "✓ fd async scan (available)")
  else
    table.insert(tiers, "✗ fd async scan")
  end

  table.insert(tiers, "✓ Lua scan (always available)")

  info("Scanning: " .. table.concat(tiers, " → "))

  -- Watcher backend
  local backend_ok, backend_mod = pcall(require, "roslyn_filewatch.watcher.backends.init")
  if backend_ok and backend_mod.get_best_backend then
    local _, name = backend_mod.get_best_backend()
    info("Watcher backend: " .. (name or "fs_event"))
  end
end

function M.check()
  start("roslyn-filewatch.nvim")

  start("Environment")
  check_neovim()
  check_platform()
  check_libuv()

  start("Tools")
  check_tools()

  start("Active Tiers")
  check_active_tiers()
end

return M
