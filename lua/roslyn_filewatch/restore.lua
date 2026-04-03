---@class roslyn_filewatch.restore
---@field schedule_restore fun(project_path: string, on_complete?: fun(project_path: string))
---@field is_restoring fun(project_path: string): boolean

---@diagnostic disable: undefined-field, undefined-doc-name

local config = require("roslyn_filewatch.config")
local uv = vim.uv
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

-- Queue state
local restore_queue = {} -- List of { path: string, on_complete?: fun } entries
local queued_set = {} -- Set for O(1) deduplication
local processing_active = false -- Only one restore at a time (Sequential)
local total_batch_active = false -- Tracks if we are in a "batch" of restores (for notifications)

---@type table<string, uv.uv_timer_t>
local debounce_timers = {}
---@type table<string, fun(string)[]> Callbacks to call when restore completes for a project
local restore_callbacks = {}

---@type uv.uv_timer_t|nil Timer to settle multiple restore calls into a single batch
local settle_timer = nil

--- Notify user about batch status
---@param status "start" | "end"
local function notify_batch(status)
  if status == "start" then
    if not total_batch_active then
      total_batch_active = true
      vim.schedule(function()
        vim.notify("[roslyn-filewatch] Restoring dependencies...", vim.log.levels.INFO)
      end)
    end
  elseif status == "end" then
    if #restore_queue == 0 and not processing_active then
      if total_batch_active then
        total_batch_active = false
        vim.schedule(function()
          vim.notify("[roslyn-filewatch] All dependencies restored.", vim.log.levels.INFO)
        end)
      end
    end
  end
end

--- Process the next item in the queue
local function process_next()
  if #restore_queue == 0 then
    processing_active = false
    notify_batch("end")
    return
  end

  processing_active = true
  local queue_item = table.remove(restore_queue, 1)
  local project_path = queue_item.path
  queued_set[project_path] = nil
  local project_name = project_path:match("([^/]+)$") or project_path

  notify_batch("start")

  local function on_complete(code, err_msg)
    -- Always notify errors immediately
    if code ~= 0 then
      local msg = err_msg or "Unknown error"
      vim.schedule(function()
        vim.notify("[roslyn-filewatch] Restore failed for " .. project_name .. "\n" .. msg, vim.log.levels.ERROR)
      end)
    else
      -- Restore succeeded - call registered callbacks
      local callbacks = restore_callbacks[project_path]
      if callbacks then
        vim.schedule(function()
          for _, callback in ipairs(callbacks) do
            pcall(callback, project_path)
          end
          restore_callbacks[project_path] = nil
        end)
      end
    end

    -- Continue to next item regardless of success/failure
    vim.schedule(process_next)
  end

  -- Run dotnet restore
  if vim.system then
    vim.system({ "dotnet", "restore", project_path }, { text = true }, function(out)
      on_complete(out.code, out.stderr or out.stdout)
    end)
  else
    vim.fn.jobstart({ "dotnet", "restore", project_path }, {
      on_exit = function(_, code)
        on_complete(code, nil)
      end,
    })
  end
end

--- Schedule a restore with debounce
---@param project_path string
---@param on_complete? fun(project_path: string)|number Callback or delay_ms
---@param delay_ms? number Delay in ms (default 2000)
function M.schedule_restore(project_path, on_complete, delay_ms)
  if not project_path or project_path == "" then
    return
  end

  -- Normalize path once
  project_path = utils.normalize_path(project_path)

  if type(on_complete) == "number" then
    delay_ms = on_complete
    on_complete = nil
  end

  delay_ms = delay_ms or (config.options.restore_debounce_ms or 1000)

  -- Add callback to registry early so it's not lost if already debouncing or queued
  if on_complete then
    if not restore_callbacks[project_path] then
      restore_callbacks[project_path] = {}
    end
    table.insert(restore_callbacks[project_path], on_complete)
  end

  -- If already in queue, just wait for it to process
  if queued_set[project_path] then
    return
  end

  -- Debounce per project path
  if debounce_timers[project_path] then
    local old_timer = debounce_timers[project_path]
    if not old_timer:is_closing() then
      old_timer:stop()
      old_timer:close()
    end
    debounce_timers[project_path] = nil
  end

  local timer = uv.new_timer()
  if not timer then
    return
  end

  debounce_timers[project_path] = timer

  timer:start(delay_ms, 0, function()
    -- Cleanup timer handle
    local t = debounce_timers[project_path]
    if t then
      pcall(t.stop, t)
      pcall(t.close, t)
    end
    debounce_timers[project_path] = nil

    -- Re-check if already queued (unlikely but safe)
    if queued_set[project_path] then
      return
    end

    -- If we are scheduling a solution, we can potentially skip pending project restores
    -- that are likely covered by this solution restore.
    if project_path:match("%.sln$") then
      local root_dir = project_path:match("^(.+)/[^/]+$")
      if root_dir then
        local to_remove = {}
        for i, item in ipairs(restore_queue) do
          if item.path:match("%.csproj$") or item.path:match("%.vbproj$") or item.path:match("%.fsproj$") then
            if utils.path_starts_with(item.path, root_dir) then
              table.insert(to_remove, i)
              queued_set[item.path] = nil
            end
          end
        end
        for i = #to_remove, 1, -1 do
          table.remove(restore_queue, to_remove[i])
        end
      end
    end

    -- Add to queue
    table.insert(restore_queue, { path = project_path })
    queued_set[project_path] = true

    -- If already processing, it will pick it up eventually
    if processing_active then
      return
    end

    -- Settle batch before starting processing
    if settle_timer then
      pcall(settle_timer.stop, settle_timer)
      pcall(settle_timer.close, settle_timer)
    end

    settle_timer = uv.new_timer()
    if settle_timer then
      settle_timer:start(100, 0, function()
        pcall(settle_timer.stop, settle_timer)
        pcall(settle_timer.close, settle_timer)
        settle_timer = nil
        vim.schedule(process_next)
      end)
    else
      -- Fallback if timer creation fails
      vim.schedule(process_next)
    end
  end)
end

--- Check if restore is in progress (in queue or processing)
---@param project_path string
---@return boolean
function M.is_restoring(project_path)
  project_path = utils.normalize_path(project_path)
  return queued_set[project_path] == true or (processing_active and total_batch_active)
end

--- Clear all timers and callbacks for paths under a given root
--- Called when a client stops to prevent memory leaks
---@param root string Root directory path (normalized with forward slashes)
function M.clear_for_root(root)
  if not root or root == "" then
    return
  end

  -- Normalize root for comparison
  root = utils.normalize_path(root)

  -- Clear debounce timers for paths under this root
  local timers_to_remove = {}
  for path, timer in pairs(debounce_timers) do
    if utils.path_starts_with(path, root) then
      table.insert(timers_to_remove, path)
      pcall(function()
        if timer and not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end)
    end
  end
  for _, path in ipairs(timers_to_remove) do
    debounce_timers[path] = nil
  end

  -- Clear callbacks for paths under this root
  local callbacks_to_remove = {}
  for path, _ in pairs(restore_callbacks) do
    if utils.path_starts_with(path, root) then
      table.insert(callbacks_to_remove, path)
    end
  end
  for _, path in ipairs(callbacks_to_remove) do
    restore_callbacks[path] = nil
  end

  -- Clear queued items for paths under this root
  local queue_to_remove = {}
  for i, item in ipairs(restore_queue) do
    if utils.path_starts_with(item.path, root) then
      table.insert(queue_to_remove, i)
      queued_set[item.path] = nil
    end
  end
  -- Remove in reverse order to maintain indices
  for i = #queue_to_remove, 1, -1 do
    table.remove(restore_queue, queue_to_remove[i])
  end
end

return M
