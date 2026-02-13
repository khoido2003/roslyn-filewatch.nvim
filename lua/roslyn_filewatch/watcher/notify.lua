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

local pending_opens = {}
local open_timer = nil

local function schedule_project_open(client, csproj_path)
  local utils = require("roslyn_filewatch.watcher.utils")
  local path = utils.to_roslyn_path(csproj_path)

  if not pending_opens[client.id] then
    pending_opens[client.id] = {}
  end
  pending_opens[client.id][path] = true

  if open_timer then
    return
  end

  open_timer = vim.defer_fn(function()
    open_timer = nil
    for client_id, paths in pairs(pending_opens) do
      local c = vim.lsp.get_client_by_id(client_id)
      if c and not (c.is_stopped and c.is_stopped()) then
        local project_list = {}
        for p in pairs(paths) do
          table.insert(project_list, p)
        end
        if #project_list > 0 then
          pcall(c.notify, "project/open", { projects = project_list })
        end
      end
    end
    pending_opens = {}
  end, 500)
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

---@param source_files string[]
---@param additional_changes table
---@return table seen_csproj
local function find_csproj_changes(source_files, additional_changes)
  local seen_csproj = {}
  local checked_dirs = {}

  for _, source_file in ipairs(source_files) do
    local dir = source_file:match("^(.+)[/\\][^/\\]+$")
    if dir and not checked_dirs[dir] then
      checked_dirs[dir] = true

      -- Efficient upward search for .csproj using vim.fs.find
      local found = vim.fs.find(function(name)
        return name:match("%.csproj$")
      end, { path = dir, upward = true, limit = 2, type = "file" })

      for _, path in ipairs(found) do
        local normalized = path:gsub("\\", "/")
        if not seen_csproj[normalized] then
          seen_csproj[normalized] = true
          table.insert(additional_changes, { uri = vim.uri_from_fname(normalized), type = 2 })
        end
      end
    end
  end
  return seen_csproj
end

function M.roslyn_changes(changes)
  if not changes or type(changes) ~= "table" or #changes == 0 then
    return
  end

  local modified_source_files = {}
  for _, change in ipairs(changes) do
    if change.type == 1 or change.type == 3 then
      local path = vim.uri_to_fname(change.uri)
      if path:match("%.cs$") or path:match("%.vb$") or path:match("%.fs$") then
        table.insert(modified_source_files, path)
      end
    end
  end

  local additional_changes = {}
  local seen_csproj = {}

  if #modified_source_files > 0 then
    seen_csproj = find_csproj_changes(modified_source_files, additional_changes)
  end

  local all_changes = vim.list_extend({}, changes)
  vim.list_extend(all_changes, additional_changes)

  local clients = vim.lsp.get_clients()
  for _, client in ipairs(clients) do
    if vim.tbl_contains(config.options.client_names, client.name) then
      notify_stats.last_notification_time = os.time()
      notify_stats.total_notifications = notify_stats.total_notifications + 1

      local success = pcall(client.notify, "workspace/didChangeWatchedFiles", { changes = all_changes })
      if success then
        notify_stats.last_success_time = os.time()
      end

      if #modified_source_files > 0 and #additional_changes > 0 then
        for csproj_path in pairs(seen_csproj or {}) do
          schedule_project_open(client, csproj_path)
        end
      end
    end
  end
end

function M.roslyn_renames(files)
  if not files or #files == 0 then
    return
  end

  local modified_source_files = {}
  for _, p in ipairs(files) do
    if p.old:match("%.cs$") or p.old:match("%.vb$") or p.old:match("%.fs$") then
      table.insert(modified_source_files, p.old)
    end
    if p.new_path:match("%.cs$") or p.new_path:match("%.vb$") or p.new_path:match("%.fs$") then
      table.insert(modified_source_files, p.new_path)
    end
  end

  local additional_changes = {}
  local seen_csproj = find_csproj_changes(modified_source_files, additional_changes)

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
        pcall(client.notify, "workspace/didRenameFiles", payload)
        if #additional_changes > 0 then
          pcall(client.notify, "workspace/didChangeWatchedFiles", { changes = additional_changes })
        end

        if #modified_source_files > 0 and #additional_changes > 0 then
          for csproj_path in pairs(seen_csproj or {}) do
            schedule_project_open(client, csproj_path)
          end
        end
      end)
    end
  end
end

return M
