---@class roslyn_filewatch.watchdog
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, deps: roslyn_filewatch.WatchdogDeps): uv_timer_t|nil, string|nil

---@class roslyn_filewatch.WatchdogDeps
---@field notify fun(msg: string, level?: number)
---@field resync_snapshot fun()
---@field restart_watcher fun(reason?: string, delay_ms?: number, disable_fs_event?: boolean)
---@field get_handle fun(): uv_fs_event_t|nil
---@field last_events table<number, number>
---@field watchdog_idle number Seconds of idle before restarting
---@field use_fs_event boolean Whether fs_event is expected to be active

local uv = vim.uv or vim.loop

local M = {}

--- Watchdog check interval in milliseconds
local WATCHDOG_INTERVAL_MS = 15000

--- Start a watchdog timer for the watcher
---@param client vim.lsp.Client LSP client
---@param root string Root directory (for logging)
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Snapshots table (unused but kept for API consistency)
---@param deps roslyn_filewatch.WatchdogDeps Dependencies
---@return uv_timer_t|nil timer The watchdog timer, or nil on error
---@return string|nil error Error message if failed
function M.start(client, root, snapshots, deps)
	deps = deps or {}
	local notify = deps.notify
	local resync_snapshot = deps.resync_snapshot
	local restart_watcher = deps.restart_watcher
	local get_handle = deps.get_handle
	local last_events = deps.last_events
	local watchdog_idle = deps.watchdog_idle or 60 -- seconds

	-- If the caller explicitly passes use_fs_event = false (poller-only),
	-- do NOT treat a missing fs_event handle as an error. Default is true if nil.
	local use_fs_event = true
	if deps.use_fs_event ~= nil then
		use_fs_event = deps.use_fs_event
	end

	local t = uv.new_timer()
	if not t then
		return nil, "failed to create timer"
	end

	local ok, err = pcall(function()
		t:start(WATCHDOG_INTERVAL_MS, WATCHDOG_INTERVAL_MS, function()
			-- Only act when client is alive
			if client.is_stopped and client.is_stopped() then
				return
			end

			local last = (last_events and last_events[client.id]) or 0
			local now = os.time()

			-- Idle detection
			if now - last > watchdog_idle then
				if notify then
					pcall(notify, "Idle " .. watchdog_idle .. "s, recycling watcher", vim.log.levels.DEBUG)
				end
				-- NOTE: Removed resync_snapshot - causes full tree scan and lag
				if restart_watcher then
					pcall(restart_watcher, "idle_timeout")
				end
				return
			end

			-- Detect dead / closed handle
			-- Only consider missing/closed handle an error when fs_event is expected
			if use_fs_event then
				local h = get_handle and get_handle()
				if not h or (h.is_closing and h:is_closing()) then
					if notify then
						pcall(notify, "Watcher handle missing/closed, restarting", vim.log.levels.DEBUG)
					end
					-- NOTE: Removed resync_snapshot - causes full tree scan and lag
					if restart_watcher then
						pcall(restart_watcher, "handle_closed")
					end
				end
			end
		end)
	end)

	if not ok then
		-- Try to close timer in case of error
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
