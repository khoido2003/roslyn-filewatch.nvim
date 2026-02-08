---@class roslyn_filewatch.regen_detector
---@field on_event fun(client_id: number)
---@field is_regenerating fun(client_id: number): boolean
---@field clear fun(client_id: number)

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

local M = {}

local DEFAULT_BURST_THRESHOLD = 10
local DEFAULT_BURST_WINDOW_MS = 300
local DEFAULT_QUIET_PERIOD_MS = 3000
local DEFAULT_MAX_REGEN_DURATION_MS = 120000

---@type fun(client_id: number)|nil
local on_regen_start_callback = nil

function M.set_on_regen_start(callback)
  on_regen_start_callback = callback
end

---@class RegenState
---@field events number[]
---@field is_regenerating boolean
---@field regen_start_time number|nil
---@field quiet_timer uv_timer_t|nil
---@field last_event_time number

---@type table<number, RegenState>
local client_states = {}

local function get_config()
  local opts = config.options or {}
  return opts.regen_burst_threshold or DEFAULT_BURST_THRESHOLD,
    opts.regen_burst_window_ms or DEFAULT_BURST_WINDOW_MS,
    opts.regen_quiet_period_ms or DEFAULT_QUIET_PERIOD_MS,
    opts.regen_max_duration_ms or DEFAULT_MAX_REGEN_DURATION_MS
end

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

local function now_ms()
  local sec, nsec = uv.gettimeofday()
  return sec * 1000 + math.floor(nsec / 1000)
end

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

local function start_regen_mode(client_id, state)
  if state.is_regenerating then
    return
  end

  state.is_regenerating = true
  state.regen_start_time = now_ms()

  if on_regen_start_callback then
    pcall(on_regen_start_callback, client_id)
  end

  local ok, notify_mod = pcall(require, "roslyn_filewatch.watcher.notify")
  if ok and notify_mod and notify_mod.user then
    pcall(notify_mod.user, "[REGEN] Detected file regeneration burst, pausing", vim.log.levels.DEBUG)
  end
end

local function stop_regen_mode(client_id, state)
  if not state.is_regenerating then
    return
  end

  state.is_regenerating = false
  state.regen_start_time = nil
  state.events = {}

  if state.quiet_timer and not state.quiet_timer:is_closing() then
    pcall(state.quiet_timer.stop, state.quiet_timer)
    pcall(state.quiet_timer.close, state.quiet_timer)
  end
  state.quiet_timer = nil

  local ok, notify_mod = pcall(require, "roslyn_filewatch.watcher.notify")
  if ok and notify_mod and notify_mod.user then
    pcall(notify_mod.user, "[REGEN] Regeneration complete, resuming", vim.log.levels.DEBUG)
  end
end

local function schedule_quiet_exit(client_id, state, quiet_period_ms)
  local timer = state.quiet_timer
  if timer and not timer:is_closing() then
    pcall(timer.stop, timer)
  else
    timer = uv.new_timer()
    if not timer then
      return
    end
    state.quiet_timer = timer
  end

  timer:start(quiet_period_ms, 0, function()
    if state.is_regenerating then
      local time_since_last = now_ms() - state.last_event_time
      if time_since_last >= quiet_period_ms then
        vim.schedule(function()
          stop_regen_mode(client_id, state)
        end)
      end
    end
  end)
end

function M.on_event(client_id)
  local state = get_state(client_id)
  local burst_threshold, burst_window_ms, quiet_period_ms, max_duration_ms = get_config()

  if config.options.regen_detection_enabled == false then
    return
  end

  local current_time = now_ms()
  state.last_event_time = current_time

  cleanup_old_events(state, current_time, burst_window_ms)
  table.insert(state.events, current_time)

  if #state.events >= burst_threshold then
    start_regen_mode(client_id, state)
  end

  if state.is_regenerating then
    schedule_quiet_exit(client_id, state, quiet_period_ms)

    if state.regen_start_time and (current_time - state.regen_start_time) >= max_duration_ms then
      stop_regen_mode(client_id, state)
    end
  end
end

function M.is_regenerating(client_id)
  if config.options.regen_detection_enabled == false then
    return false
  end
  local state = client_states[client_id]
  return state and state.is_regenerating or false
end

function M.get_regen_remaining(client_id)
  local state = client_states[client_id]
  if not state or not state.is_regenerating or not state.regen_start_time then
    return nil
  end
  local _, _, _, max_duration_ms = get_config()
  local remaining = max_duration_ms - (now_ms() - state.regen_start_time)
  return remaining > 0 and remaining or 0
end

function M.clear(client_id)
  local state = client_states[client_id]
  if state and state.quiet_timer and not state.quiet_timer:is_closing() then
    pcall(state.quiet_timer.stop, state.quiet_timer)
    pcall(state.quiet_timer.close, state.quiet_timer)
  end
  client_states[client_id] = nil
end

function M.force_exit(client_id)
  local state = client_states[client_id]
  if state then
    stop_regen_mode(client_id, state)
  end
end

return M
