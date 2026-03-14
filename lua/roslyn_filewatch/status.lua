---@class roslyn_filewatch.status
---@field get_status fun(): roslyn_filewatch.StatusInfo
---@field show fun()

local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

---@class roslyn_filewatch.StatusInfo
---@field clients roslyn_filewatch.ClientStatus[]
---@field scanning_tier string
---@field watcher_backend string

---@class roslyn_filewatch.ClientStatus
---@field id number
---@field name string
---@field root string
---@field backend string
---@field has_watcher boolean
---@field has_poller boolean
---@field has_watchdog boolean
---@field file_count number
---@field last_event number|nil
---@field sln_file string|nil
---@field project_count number
---@field preset string|nil

local _watchers = nil
local _pollers = nil
local _watchdogs = nil
local _snapshots = nil
local _last_events = nil
local _sln_infos = nil
local _backend_names = nil

function M.register_refs(refs)
  _watchers = refs.watchers
  _pollers = refs.pollers
  _watchdogs = refs.watchdogs
  _snapshots = refs.snapshots
  _last_events = refs.last_events
  _sln_infos = refs.sln_infos
  _backend_names = refs.backend_names
end

--- Determine scanning tier in use
---@return string
local function get_scanning_tier()
  local rs_ok, rs = pcall(require, "roslyn_filewatch_rs")
  if rs_ok and rs and rs.fast_snapshot then
    return "rust"
  end
  if vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1 then
    return "fd"
  end
  return "lua"
end

---@param timestamp number|nil
---@return string
local function format_time_ago(timestamp)
  if not timestamp or timestamp == 0 then
    return "none"
  end
  local ago = os.time() - timestamp
  if ago < 2 then
    return "just now"
  elseif ago < 60 then
    return ago .. "s ago"
  elseif ago < 3600 then
    return math.floor(ago / 60) .. "m ago"
  else
    return math.floor(ago / 3600) .. "h ago"
  end
end

function M.get_status()
  local status = {
    clients = {},
    scanning_tier = get_scanning_tier(),
  }

  local clients = vim.lsp.get_clients()
  for _, client in ipairs(clients) do
    if vim.tbl_contains(config.options.client_names or {}, client.name) then
      local cs = {
        id = client.id,
        name = client.name,
        root = utils.normalize_path(client.config and client.config.root_dir or "unknown"),
        backend = (_backend_names and _backend_names[client.id]) or "unknown",
        has_watcher = _watchers and _watchers[client.id] ~= nil or false,
        has_poller = _pollers and _pollers[client.id] ~= nil or false,
        has_watchdog = _watchdogs and _watchdogs[client.id] ~= nil or false,
        file_count = 0,
        last_event = _last_events and _last_events[client.id] or nil,
        sln_file = nil,
        project_count = 0,
        preset = config.options._applied_preset,
      }

      if _snapshots and _snapshots[client.id] then
        cs.file_count = vim.tbl_count(_snapshots[client.id])
      end

      if _sln_infos and _sln_infos[client.id] then
        local sln = _sln_infos[client.id]
        if sln.path then
          cs.sln_file = sln.path:match("[^/\\]+$") or sln.path
        end
        if sln.csproj_files then
          cs.project_count = vim.tbl_count(sln.csproj_files)
        end
      end

      table.insert(status.clients, cs)
    end
  end

  return status
end

function M.show()
  local status = M.get_status()

  local lines = {}
  local hls = {}

  local function add(text, hl)
    table.insert(lines, { { text, hl or "Normal" } })
  end

  local function add_kv(key, value, val_hl)
    table.insert(lines, {
      { "  " .. key .. ": ", "Normal" },
      { tostring(value), val_hl or "Normal" },
    })
  end

  local function add_bool(key, enabled)
    local val = enabled and "on" or "off"
    local hl = enabled and "DiagnosticOk" or "WarningMsg"
    add_kv(key, val, hl)
  end

  -- Header
  add("")
  add("roslyn-filewatch", "Title")
  add(string.rep("─", 40), "Comment")

  -- Global info
  add_kv("Scanning", status.scanning_tier, "Identifier")

  if config.options._applied_preset then
    add_kv("Preset", config.options._applied_preset, "String")
  end

  -- Config
  add("")
  add("  Config", "Bold")
  add_bool("solution_aware", config.options.solution_aware ~= false)
  add_bool("respect_gitignore", config.options.respect_gitignore ~= false)
  add_bool("batching", config.options.batching and config.options.batching.enabled)
  add_bool("force_polling", config.options.force_polling)
  add_bool("autorestore", config.options.enable_autorestore ~= false)
  add_kv("poll_interval", (config.options.poll_interval or 5000) .. "ms")
  add_kv("log_level", config.options.log_level or "WARN")

  -- Clients
  if #status.clients == 0 then
    add("")
    add("  No active Roslyn clients", "WarningMsg")
  else
    for _, c in ipairs(status.clients) do
      add("")
      add(string.rep("─", 40), "Comment")
      table.insert(lines, {
        { "  " .. c.name, "Identifier" },
        { " #" .. c.id, "Number" },
      })
      add_kv("Root", c.root)
      add_kv("Backend", c.backend, "Identifier")

      -- Watcher state
      local state_parts = {}
      if c.has_watcher then
        table.insert(state_parts, "watcher")
      end
      if c.has_poller then
        table.insert(state_parts, "poller")
      end
      if c.has_watchdog then
        table.insert(state_parts, "watchdog")
      end
      add_kv(
        "Active",
        #state_parts > 0 and table.concat(state_parts, " + ") or "none",
        #state_parts > 0 and "DiagnosticOk" or "WarningMsg"
      )

      add_kv("Files", c.file_count, "Number")
      add_kv("Last event", format_time_ago(c.last_event))

      -- Solution
      if c.sln_file then
        add_kv("Solution", c.sln_file, "String")
        add_kv("Projects", c.project_count, "Number")
      elseif c.project_count > 0 then
        add_kv("Solution", "none (csproj-only mode)", "WarningMsg")
        add_kv("Projects", c.project_count, "Number")
      else
        add_kv("Solution", "none", "WarningMsg")
      end
    end
  end

  add("")

  -- Output
  for _, segs in ipairs(lines) do
    vim.api.nvim_echo(segs, true, {})
  end
end

return M
