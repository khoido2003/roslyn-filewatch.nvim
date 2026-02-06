---@class roslyn_filewatch.restore
---@field schedule_restore fun(project_path: string, on_complete?: fun(project_path: string))
---@field is_restoring fun(project_path: string): boolean

local config = require("roslyn_filewatch.config")
local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

-- Queue state
local restore_queue = {} -- List of { path: string, on_complete?: fun } entries
local queued_set = {} -- Set for O(1) deduplication
local processing_active = false -- Only one restore at a time (Sequential)
local total_batch_active = false -- Tracks if we are in a "batch" of restores (for notifications)

---@type table<string, uv_timer_t>
local debounce_timers = {}
---@type table<string, fun(string)[]> Callbacks to call when restore completes for a project
local restore_callbacks = {}

--- Notify user about batch status
---@param status "start" | "end"
local function notify_batch(status)
  if status == "start" then
    if not total_batch_active then
      total_batch_active = true
      vim.notify("[roslyn-filewatch] Restoring dependencies...", vim.log.levels.INFO)
    end
  elseif status == "end" then
    -- Only notify end if queue is empty and nothing is processing
    if #restore_queue == 0 and not processing_active then
      total_batch_active = false
      vim.notify("[roslyn-filewatch] All dependencies restored.", vim.log.levels.INFO)
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
  local on_complete_callback = queue_item.on_complete
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

      -- Call the per-restore callback if provided
      if on_complete_callback then
        vim.schedule(function()
          pcall(on_complete_callback, project_path)
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
  -- Handle argument overloading: schedule_restore(path, delay_ms)
  if type(on_complete) == "number" then
    delay_ms = on_complete
    on_complete = nil
  end

  if not config.options.enable_autorestore then
    -- If autorestore is disabled, call callback immediately
    if on_complete then
      vim.schedule(function()
        pcall(on_complete, project_path)
      end)
    end
    return
  end

  -- Normalize path
  project_path = utils.normalize_path(project_path)

  -- Cancel existing debounce timer for this file
  if debounce_timers[project_path] then
    pcall(function()
      if not debounce_timers[project_path]:is_closing() then
        debounce_timers[project_path]:stop()
        debounce_timers[project_path]:close()
      end
    end)
    debounce_timers[project_path] = nil
  end

  local t = uv.new_timer()
  if not t then
    return
  end
  debounce_timers[project_path] = t

  -- Debounce (default 2000ms, or custom delay)
  -- For Unity, we often want a longer delay (e.g. 5000ms) to let regeneration finish
  local delay = delay_ms or 2000

  t:start(delay, 0, function()
    debounce_timers[project_path] = nil
    pcall(function()
      if not t:is_closing() then
        t:stop()
        t:close()
      end
    end)

    vim.schedule(function()
      -- Store callback even if project is already queued
      -- (so we can notify when the existing restore completes)
      if on_complete then
        if not restore_callbacks[project_path] then
          restore_callbacks[project_path] = {}
        end
        table.insert(restore_callbacks[project_path], on_complete)
      end

      -- Add to queue if not already there
      if not queued_set[project_path] then
        table.insert(restore_queue, { path = project_path, on_complete = nil })
        queued_set[project_path] = true

        -- Kick off processing if idle
        if not processing_active then
          process_next()
        end
      end
      -- If already queued, the callback will be called when the existing restore completes
    end)
  end)
end

--- Check if restore is in progress (in queue or processing)
---@param project_path string
---@return boolean
function M.is_restoring(project_path)
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
