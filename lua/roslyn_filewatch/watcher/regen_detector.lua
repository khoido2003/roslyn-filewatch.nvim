---@class roslyn_filewatch.regen_detector
---@field on_event fun(client_id: number) Record an event
---@field is_regenerating fun(client_id: number): boolean Check if in regeneration mode
---@field clear fun(client_id: number) Clear state for a client

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

local M = {}

-- Configuration defaults (can be overridden via config)
local DEFAULT_BURST_THRESHOLD = 30 -- Events in window to trigger regeneration mode
local DEFAULT_BURST_WINDOW_MS = 500 -- Time window for burst detection
local DEFAULT_QUIET_PERIOD_MS = 2000 -- Quiet time before exiting regeneration mode
local DEFAULT_MAX_REGEN_DURATION_MS = 60000 -- Maximum regeneration mode duration (1 minute)

---@class RegenState
---@field events number[] Timestamps of recent events (ms)
---@field is_regenerating boolean Currently in regeneration mode
---@field regen_start_time number|nil When regeneration mode started
---@field quiet_timer uv_timer_t|nil Timer for detecting quiet period
---@field last_event_time number Last event timestamp

---@type table<number, RegenState>
local client_states = {}

--- Get config values with defaults
---@return number burst_threshold
---@return number burst_window_ms
---@return number quiet_period_ms
---@return number max_duration_ms
local function get_config()
  local opts = config.options or {}
  return opts.regen_burst_threshold or DEFAULT_BURST_THRESHOLD,
    opts.regen_burst_window_ms or DEFAULT_BURST_WINDOW_MS,
    opts.regen_quiet_period_ms or DEFAULT_QUIET_PERIOD_MS,
    opts.regen_max_duration_ms or DEFAULT_MAX_REGEN_DURATION_MS
end

--- Get or create client state
---@param client_id number
---@return RegenState
local function get_state(client_id)
  if not client_states[client_id] then
    client_states[client_id] = {
      events = {},
      is_regenerating = false,
      regen_start_time = nil,
      quiet_timer = nil,
      last_event_time = 0,
    }
  end
  return client_states[client_id]
end

--- Get current time in milliseconds
---@return number
local function now_ms()
  local sec, nsec = uv.gettimeofday()
  return sec * 1000 + math.floor(nsec / 1000)
end

--- Clean up old events outside the burst window
---@param state RegenState
---@param current_time number
---@param window_ms number
local function cleanup_old_events(state, current_time, window_ms)
  local cutoff = current_time - window_ms
  local new_events = {}
  for _, ts in ipairs(state.events) do
    if ts >= cutoff then
      table.insert(new_events, ts)
    end
  end
  state.events = new_events
end

--- Start regeneration mode for a client
---@param client_id number
---@param state RegenState
local function start_regen_mode(client_id, state)
  if state.is_regenerating then
    return
  end

  state.is_regenerating = true
  state.regen_start_time = now_ms()

  -- Log at debug level
  local notify_fn = nil
  pcall(function()
    local notify_mod = require("roslyn_filewatch.watcher.notify")
    if notify_mod and notify_mod.user then
      notify_fn = notify_mod.user
    end
  end)

  if notify_fn then
    pcall(notify_fn, "[REGEN] Detected file regeneration burst, pausing event processing", vim.log.levels.DEBUG)
  end
end

--- Stop regeneration mode for a client
---@param client_id number
---@param state RegenState
local function stop_regen_mode(client_id, state)
  if not state.is_regenerating then
    return
  end

  state.is_regenerating = false
  state.regen_start_time = nil
  state.events = {}

  -- Stop quiet timer
  if state.quiet_timer then
    pcall(function()
      if not state.quiet_timer:is_closing() then
        state.quiet_timer:stop()
        state.quiet_timer:close()
      end
    end)
    state.quiet_timer = nil
  end

  -- Log at debug level
  local notify_fn = nil
  pcall(function()
    local notify_mod = require("roslyn_filewatch.watcher.notify")
    if notify_mod and notify_mod.user then
      notify_fn = notify_mod.user
    end
  end)

  if notify_fn then
    pcall(notify_fn, "[REGEN] Regeneration complete, resuming normal event processing", vim.log.levels.DEBUG)
  end
end

--- Schedule quiet timer to exit regeneration mode
---@param client_id number
---@param state RegenState
---@param quiet_period_ms number
local function schedule_quiet_exit(client_id, state, quiet_period_ms)
  -- Cancel existing timer
  if state.quiet_timer then
    pcall(function()
      if not state.quiet_timer:is_closing() then
        state.quiet_timer:stop()
        state.quiet_timer:close()
      end
    end)
    state.quiet_timer = nil
  end

  -- Create new timer
  local timer = uv.new_timer()
  if timer then
    state.quiet_timer = timer
    timer:start(quiet_period_ms, 0, function()
      state.quiet_timer = nil
      -- Check if still in regen mode and enough quiet time has passed
      if state.is_regenerating then
        local current = now_ms()
        local time_since_last = current - state.last_event_time
        if time_since_last >= quiet_period_ms then
          vim.schedule(function()
            stop_regen_mode(client_id, state)
          end)
        end
      end
      -- Clean up timer
      pcall(function()
        if timer and not timer:is_closing() then
          timer:close()
        end
      end)
    end)
  end
end

--- Record an event for burst detection
--- Call this for every file system event
---@param client_id number
function M.on_event(client_id)
  local state = get_state(client_id)
  local burst_threshold, burst_window_ms, quiet_period_ms, max_duration_ms = get_config()

  -- Check if regeneration detection is enabled
  if config.options.regen_detection_enabled == false then
    return
  end

  local current_time = now_ms()
  state.last_event_time = current_time

  -- Clean up old events
  cleanup_old_events(state, current_time, burst_window_ms)

  -- Add current event
  table.insert(state.events, current_time)

  -- Check for burst
  if #state.events >= burst_threshold then
    start_regen_mode(client_id, state)
  end

  -- If in regeneration mode, schedule quiet exit and check max duration
  if state.is_regenerating then
    schedule_quiet_exit(client_id, state, quiet_period_ms)

    -- Check max duration
    if state.regen_start_time then
      local duration = current_time - state.regen_start_time
      if duration >= max_duration_ms then
        stop_regen_mode(client_id, state)
      end
    end
  end
end

--- Check if currently in regeneration mode
--- When in regeneration mode, file watching should be paused or throttled
---@param client_id number
---@return boolean
function M.is_regenerating(client_id)
  -- Check if regeneration detection is enabled
  if config.options.regen_detection_enabled == false then
    return false
  end

  local state = client_states[client_id]
  if not state then
    return false
  end
  return state.is_regenerating
end

--- Get time remaining in regeneration mode (for UI/debugging)
---@param client_id number
---@return number|nil ms_remaining, nil if not in regeneration mode
function M.get_regen_remaining(client_id)
  local state = client_states[client_id]
  if not state or not state.is_regenerating or not state.regen_start_time then
    return nil
  end

  local _, _, _, max_duration_ms = get_config()
  local elapsed = now_ms() - state.regen_start_time
  local remaining = max_duration_ms - elapsed

  return remaining > 0 and remaining or 0
end

--- Clear state for a client (call on cleanup)
---@param client_id number
function M.clear(client_id)
  local state = client_states[client_id]
  if state then
    if state.quiet_timer then
      pcall(function()
        if not state.quiet_timer:is_closing() then
          state.quiet_timer:stop()
          state.quiet_timer:close()
        end
      end)
    end
  end
  client_states[client_id] = nil
end

--- Force exit regeneration mode (for manual override/testing)
---@param client_id number
function M.force_exit(client_id)
  local state = client_states[client_id]
  if state then
    stop_regen_mode(client_id, state)
  end
end

return M
