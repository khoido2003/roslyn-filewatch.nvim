---@class roslyn_filewatch.notify
---@field user fun(msg: string, level?: number)
---@field roslyn_changes fun(changes: roslyn_filewatch.FileChange[])
---@field roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])

---@class roslyn_filewatch.FileChange
---@field uri string
---@field type number 1=Created, 2=Changed, 3=Deleted

---@class roslyn_filewatch.RenameEntry
---@field old string
---@field new_path string
---@field oldUri? string
---@field newUri? string

local M = {}

local config = require("roslyn_filewatch.config")

---@class NotifyStats
---@field last_success_time number
---@field total_notifications number Total number of notification attempts (regardless of success)
---@field last_notification_time number

---@type NotifyStats
local notify_stats = {
  last_success_time = 0,
  total_notifications = 0,
  last_notification_time = 0,
}

function M.get_stats()
  return notify_stats
end

function M.reset_stats()
  notify_stats.last_success_time = 0
  notify_stats.total_notifications = 0
  notify_stats.last_notification_time = 0
end

local function configured_log_level()
  local ok, lvl = pcall(function()
    return config and config.options and config.options.log_level
  end)
  if not ok or lvl == nil then
    return vim.log.levels.WARN or 3
  end
  return lvl
end

local function should_emit(level)
  level = level or vim.log.levels.INFO or 2
  return level >= configured_log_level()
end

function M.user(msg, level)
  level = level or vim.log.levels.INFO or 2
  if not should_emit(level) then
    return
  end
  vim.schedule(function()
    pcall(vim.notify, "[roslyn-filewatch] " .. tostring(msg), level)
  end)
end

function M.roslyn_changes(changes)
  if not changes or type(changes) ~= "table" or #changes == 0 then
    return
  end

  local clients = vim.lsp.get_clients()
  for _, client in ipairs(clients) do
    if vim.tbl_contains(config.options.client_names, client.name) then
      notify_stats.last_notification_time = os.time()
      notify_stats.total_notifications = notify_stats.total_notifications + 1

      local success = pcall(function()
        client:notify("workspace/didChangeWatchedFiles", { changes = changes })
      end)
      if success then
        notify_stats.last_success_time = os.time()
      end
    end
  end
end

function M.roslyn_renames(files)
  if not files or #files == 0 then
    return
  end

  local clients = vim.lsp.get_clients()
  for _, client in ipairs(clients) do
    if vim.tbl_contains(config.options.client_names, client.name) then
      local payload = { files = {} }
      for _, p in ipairs(files) do
        table.insert(payload.files, {
          oldUri = p.oldUri or vim.uri_from_fname(p.old),
          newUri = p.newUri or vim.uri_from_fname(p.new_path),
        })
      end

      vim.schedule(function()
        pcall(function()
          client:notify("workspace/didRenameFiles", payload)
        end)
      end)
    end
  end
end

return M
