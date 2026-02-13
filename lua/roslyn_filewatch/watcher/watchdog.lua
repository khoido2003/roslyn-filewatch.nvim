---@class roslyn_filewatch.watchdog
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, deps: roslyn_filewatch.WatchdogDeps): uv_timer_t|nil, string|nil

---@class roslyn_filewatch.WatchdogDeps
---@field notify fun(msg: string, level?: number)
---@field restart_watcher fun(reason?: string, delay_ms?: number, disable_fs_event?: boolean)
---@field get_handle fun(): uv_fs_event_t|nil
---@field get_poller? fun(): uv_fs_poll_t|nil
---@field last_events table<number, number>
---@field watchdog_idle number Seconds of idle before restarting
---@field use_fs_event boolean Whether fs_event is expected to be active
---@field get_snapshot? fun(): table<string, roslyn_filewatch.SnapshotEntry>|nil
---@field mark_needs_full_scan? fun()

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

local M = {}

------------------------------------------------------
-- RECOVERY STATE (per-client)
------------------------------------------------------

---@class WatchdogRecoveryState
---@field consecutive_failures number Number of consecutive restart failures
---@field last_restart_time number Timestamp of last restart attempt
---@field current_backoff_ms number Current backoff delay in ms
---@field last_deep_check number Timestamp of last deep health check
---@field last_event_count number Event count at last check (for flow detection)
---@field stale_detections number Number of stale state detections
---@field health_status string Current health status: "healthy", "degraded", "recovering"

---@type table<number, WatchdogRecoveryState>
local recovery_states = {}

--- Get or create recovery state for a client
---@param client_id number
---@return WatchdogRecoveryState
local function get_recovery_state(client_id)
  if not recovery_states[client_id] then
    recovery_states[client_id] = {
      consecutive_failures = 0,
      last_restart_time = 0,
      current_backoff_ms = config.options.recovery_initial_delay_ms or 300,
      last_deep_check = 0,
      last_event_count = 0,
      stale_detections = 0,
      health_status = "healthy",
    }
  end
  return recovery_states[client_id]
end

--- Clear recovery state for a client
---@param client_id number
function M.clear(client_id)
  recovery_states[client_id] = nil
end

--- Get recovery state for health check display
---@param client_id number
---@return WatchdogRecoveryState|nil
function M.get_state(client_id)
  return recovery_states[client_id]
end

--- Get all recovery states (for health check)
---@return table<number, WatchdogRecoveryState>
function M.get_all_states()
  return recovery_states
end

------------------------------------------------------
-- EXPONENTIAL BACKOFF
------------------------------------------------------

--- Calculate next backoff delay with jitter
---@param state WatchdogRecoveryState
---@return number delay_ms
local function calculate_backoff(state)
  local initial = config.options.recovery_initial_delay_ms or 300
  local max_delay = config.options.recovery_max_delay_ms or 30000

  -- Exponential: 2^failures * initial, capped at max
  local base_delay = math.min(initial * math.pow(2, state.consecutive_failures), max_delay)

  -- Add jitter (±20%) to prevent thundering herd
  local jitter = base_delay * 0.2 * (math.random() * 2 - 1)
  local final_delay = math.floor(base_delay + jitter)

  return math.max(initial, math.min(final_delay, max_delay))
end

--- Record a recovery attempt
---@param client_id number
---@param success boolean
local function record_recovery_attempt(client_id, success)
  local state = get_recovery_state(client_id)
  local now = os.time()

  if success then
    -- Reset on success
    state.consecutive_failures = 0
    state.current_backoff_ms = config.options.recovery_initial_delay_ms or 300
    state.health_status = "healthy"
  else
    state.consecutive_failures = state.consecutive_failures + 1
    state.current_backoff_ms = calculate_backoff(state)
    state.health_status = "recovering"
  end

  state.last_restart_time = now
end

--- Check if we should escalate (too many failures)
---@param client_id number
---@return boolean should_escalate
local function should_escalate(client_id)
  local state = get_recovery_state(client_id)
  local max_retries = config.options.recovery_max_retries or 5
  return state.consecutive_failures >= max_retries
end

------------------------------------------------------
-- ASYNC SNAPSHOT VERIFICATION
------------------------------------------------------

--- Verify a sample of snapshot entries asynchronously
---@param snapshot table<string, roslyn_filewatch.SnapshotEntry>|nil
---@param callback fun(stale_ratio: number, checked: number)
local function verify_snapshot_sample_async(snapshot, callback)
  if not snapshot or vim.tbl_count(snapshot) == 0 then
    callback(0, 0)
    return
  end

  local sample_size = config.options.recovery_sample_size or 5
  local paths = vim.tbl_keys(snapshot)

  -- Shuffle and take sample
  for i = #paths, 2, -1 do
    local j = math.random(i)
    paths[i], paths[j] = paths[j], paths[i]
  end

  local sample = {}
  for i = 1, math.min(sample_size, #paths) do
    table.insert(sample, paths[i])
  end

  if #sample == 0 then
    callback(0, 0)
    return
  end

  local pending = #sample
  local stale_count = 0
  local checked = 0

  for _, path in ipairs(sample) do
    local entry = snapshot[path]
    if not entry then
      pending = pending - 1
      if pending == 0 then
        local ratio = checked > 0 and (stale_count / checked) or 0
        callback(ratio, checked)
      end
    else
      uv.fs_stat(path, function(err, stat)
        checked = checked + 1

        if err or not stat then
          -- File no longer exists but we have it in snapshot = stale
          stale_count = stale_count + 1
        else
          -- Compare mtime
          local snapshot_mtime = entry.mtime or 0
          local disk_mtime = stat.mtime and (stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)) or 0

          if math.abs(snapshot_mtime - disk_mtime) > 1e9 then -- 1 second tolerance
            stale_count = stale_count + 1
          end
        end

        pending = pending - 1
        if pending == 0 then
          local ratio = checked > 0 and (stale_count / checked) or 0
          vim.schedule(function()
            callback(ratio, checked)
          end)
        end
      end)
    end
  end
end

------------------------------------------------------
-- HEALTH CHECK LEVELS
------------------------------------------------------

---@class HealthCheckResult
---@field level number 1=handle, 2=flow, 3=snapshot
---@field healthy boolean
---@field reason string|nil

--- Level 1: Handle health check (fast, ~1ms)
---@param deps roslyn_filewatch.WatchdogDeps
---@return HealthCheckResult
local function check_handle_health(deps)
  local use_fs_event = deps.use_fs_event

  if use_fs_event then
    local h = deps.get_handle and deps.get_handle()
    if not h then
      return { level = 1, healthy = false, reason = "fs_event handle missing" }
    end
    if h.is_closing and h:is_closing() then
      return { level = 1, healthy = false, reason = "fs_event handle closing" }
    end
  end

  -- Check poller if available
  if deps.get_poller then
    local p = deps.get_poller()
    if not p then
      return { level = 1, healthy = false, reason = "poller handle missing" }
    end
    if p.is_closing and p:is_closing() then
      return { level = 1, healthy = false, reason = "poller handle closing" }
    end
  end

  return { level = 1, healthy = true }
end

--- Level 2: Event flow check (fast, ~1ms)
---@param client_id number
---@param deps roslyn_filewatch.WatchdogDeps
---@return HealthCheckResult
local function check_event_flow(client_id, deps)
  local last_event = deps.last_events and deps.last_events[client_id] or 0
  local now = os.time()
  local idle_threshold = deps.watchdog_idle or 60

  if now - last_event > idle_threshold then
    return { level = 2, healthy = false, reason = "idle timeout (" .. idle_threshold .. "s)" }
  end

  return { level = 2, healthy = true }
end

------------------------------------------------------
-- MAIN WATCHDOG
------------------------------------------------------

--- Start a watchdog timer for the watcher with multi-level health checks
---@param client vim.lsp.Client LSP client
---@param root string Root directory (for logging)
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Snapshots table
---@param deps roslyn_filewatch.WatchdogDeps Dependencies
---@return uv_timer_t|nil timer The watchdog timer, or nil on error
---@return string|nil error Error message if failed
function M.start(client, root, snapshots, deps)
  deps = deps or {}
  local notify = deps.notify or function() end
  local restart_watcher = deps.restart_watcher
  local last_events = deps.last_events
  local watchdog_idle = deps.watchdog_idle or 60

  local use_fs_event = true
  if deps.use_fs_event ~= nil then
    use_fs_event = deps.use_fs_event
  end

  -- Fast check interval (handle + flow)
  local fast_interval = config.options.watchdog_fast_interval_ms or 5000
  -- Deep check interval (snapshot verification)
  local deep_interval = config.options.watchdog_deep_interval_ms or 30000

  local t = uv.new_timer()
  if not t then
    return nil, "failed to create timer"
  end

  local recovery_state = get_recovery_state(client.id)

  local ok, err = pcall(function()
    t:start(fast_interval, fast_interval, function()
      -- Only act when client is alive
      if client.is_stopped and client.is_stopped() then
        return
      end

      -- LSP client health check: detect silent LSP death
      local client_check = vim.lsp.get_client_by_id(client.id)
      if not client_check then
        pcall(notify, "LSP client died silently, stopping watcher", vim.log.levels.WARN)
        pcall(function()
          if t and not t:is_closing() then
            t:stop()
            t:close()
          end
        end)
        if restart_watcher then
          pcall(restart_watcher, "lsp_client_died", 0)
        end
        return
      end

      local now = os.time()

      ----------------------------------------------
      -- LEVEL 1: Handle Health (every fast tick)
      ----------------------------------------------
      local handle_result = check_handle_health(deps)
      if not handle_result.healthy then
        pcall(notify, "Health check L1 failed: " .. (handle_result.reason or "unknown"), vim.log.levels.DEBUG)
        recovery_state.health_status = "recovering"

        if restart_watcher then
          local delay = recovery_state.current_backoff_ms
          pcall(
            notify,
            "Restarting with backoff: " .. delay .. "ms (attempt " .. (recovery_state.consecutive_failures + 1) .. ")",
            vim.log.levels.DEBUG
          )
          pcall(restart_watcher, handle_result.reason, delay)
          record_recovery_attempt(client.id, false)

          -- Check for escalation
          if should_escalate(client.id) then
            vim.schedule(function()
              vim.notify(
                "[roslyn-filewatch] Watcher recovery failed after "
                  .. (config.options.recovery_max_retries or 5)
                  .. " attempts. Run :checkhealth roslyn_filewatch",
                vim.log.levels.WARN
              )
            end)
            -- Reset to prevent spam
            recovery_state.consecutive_failures = 0
          end
        end
        return
      end

      ----------------------------------------------
      -- LEVEL 2: Event Flow (every fast tick)
      ----------------------------------------------
      local flow_result = check_event_flow(client.id, deps)
      if not flow_result.healthy then
        pcall(notify, "Health check L2: " .. (flow_result.reason or "idle"), vim.log.levels.DEBUG)

        if restart_watcher then
          local delay = recovery_state.current_backoff_ms
          pcall(restart_watcher, "idle_timeout", delay)
          -- Idle timeout is normal, don't count as failure
        end
        return
      end

      -- If we got here, fast checks passed - mark healthy if was recovering
      if recovery_state.health_status == "recovering" then
        record_recovery_attempt(client.id, true)
        pcall(notify, "Watcher recovered successfully", vim.log.levels.DEBUG)
      end

      ----------------------------------------------
      -- LEVEL 3: Deep Check (less frequent)
      ----------------------------------------------
      if now - recovery_state.last_deep_check >= (deep_interval / 1000) then
        recovery_state.last_deep_check = now

        -- Only do deep check if verification is enabled and we have snapshot access
        if config.options.recovery_verify_enabled and deps.get_snapshot then
          local snapshot = deps.get_snapshot()
          verify_snapshot_sample_async(snapshot, function(stale_ratio, checked)
            if checked == 0 then
              return
            end

            local threshold = config.options.recovery_stale_threshold or 0.5
            if stale_ratio >= threshold then
              recovery_state.stale_detections = recovery_state.stale_detections + 1
              recovery_state.health_status = "degraded"

              pcall(
                notify,
                string.format(
                  "Health check L3: %.0f%% stale (%d/%d files)",
                  stale_ratio * 100,
                  math.floor(stale_ratio * checked),
                  checked
                ),
                vim.log.levels.DEBUG
              )

              -- Request full scan instead of restart
              if deps.mark_needs_full_scan then
                pcall(deps.mark_needs_full_scan)
                pcall(notify, "Scheduled full rescan due to stale snapshot", vim.log.levels.DEBUG)
              end
            else
              -- Healthy deep check
              if recovery_state.stale_detections > 0 then
                recovery_state.stale_detections = 0
                recovery_state.health_status = "healthy"
                pcall(notify, "Snapshot verification passed", vim.log.levels.DEBUG)
              end
            end
          end)
        end
      end
    end)
  end)

  if not ok then
    pcall(function()
      if t and not t:is_closing() then
        t:stop()
        t:close()
      end
    end)
    return nil, err
  end

  return t, nil
end

return M
