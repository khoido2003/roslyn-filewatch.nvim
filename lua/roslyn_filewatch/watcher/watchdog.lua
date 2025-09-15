local uv = vim.uv or vim.loop

local M = {}

-- deps:
--  notify(fn), resync_snapshot(fn), restart_watcher(fn),
--  get_handle(fn) -> returns current fs_event handle, last_events(table), watchdog_idle(number)
function M.start(client, root, snapshots, deps)
	deps = deps or {}
	local notify = deps.notify
	local resync_snapshot = deps.resync_snapshot
	local restart_watcher = deps.restart_watcher
	local get_handle = deps.get_handle
	local last_events = deps.last_events
	local watchdog_idle = deps.watchdog_idle or 60 -- seconds

	-- If the caller explicitly passes use_fs_event = false (poller-only),
	-- NOT treat a missing fs_event handle as an error. Default is true if nil.
	local use_fs_event = true
	if deps.use_fs_event ~= nil then
		use_fs_event = deps.use_fs_event
	end

	local t = uv.new_timer()
	local ok, err = pcall(function()
		-- fire every 15s
		t:start(15000, 15000, function()
			-- only act when client is alive
			if not client.is_stopped() then
				local last = (last_events and last_events[client.id]) or 0

				-- idle detection
				if os.time() - last > watchdog_idle then
					if notify then
						pcall(notify, "Idle " .. watchdog_idle .. "s, recycling watcher", vim.log.levels.DEBUG)
					end
					if resync_snapshot then
						pcall(resync_snapshot)
					end
					if restart_watcher then
						pcall(restart_watcher)
					end
					return
				end

				-- detect dead / closed handle
				-- Only consider missing/closed handle an error when expected a fs_event handle.
				local h = get_handle and get_handle()
				if use_fs_event and (not h or (h.is_closing and h:is_closing())) then
					if notify then
						pcall(notify, "Watcher handle missing/closed, restarting", vim.log.levels.DEBUG)
					end
					if resync_snapshot then
						pcall(resync_snapshot)
					end
					if restart_watcher then
						pcall(restart_watcher)
					end
				end
			end
		end)
	end)

	if not ok then
		-- try to close timer in case of error
		pcall(function()
			if t and not t:is_closing() then
				t:stop()
				t:close()
			end
		end)
		return nil, err
	end

	return t
end

return M
