---@class roslyn_filewatch.watcher
---@field start fun(client: vim.lsp.Client)
---@field stop fun(client: vim.lsp.Client)

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")
local notify_mod = require("roslyn_filewatch.watcher.notify")
local snapshot_mod = require("roslyn_filewatch.watcher.snapshot")
local rename_mod = require("roslyn_filewatch.watcher.rename")
local fs_event_mod = require("roslyn_filewatch.watcher.fs_event")
local fs_poll_mod = require("roslyn_filewatch.watcher.fs_poll")
local watchdog_mod = require("roslyn_filewatch.watcher.watchdog")
local autocmds_mod = require("roslyn_filewatch.watcher.autocmds")

local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat
local same_file_info = utils.same_file_info
local normalize_path = utils.normalize_path
local scan_tree = snapshot_mod.scan_tree

local notify = notify_mod.user
local notify_roslyn = notify_mod.roslyn_changes
local notify_roslyn_renames = notify_mod.roslyn_renames

local M = {}

---@type table<number, uv_fs_event_t>
local watchers = {}
---@type table<number, uv_fs_poll_t>
local pollers = {}
---@type table<number, { events: roslyn_filewatch.FileChange[], timer: uv_timer_t|nil }>
local batch_queues = {}
---@type table<number, uv_timer_t>
local watchdogs = {}
---@type table<number, table<string, roslyn_filewatch.SnapshotEntry>>
local snapshots = {}
---@type table<number, number>
local last_events = {}
---@type table<number, boolean>
local restart_scheduled = {}
---@type table<number, number>
local restart_backoff_until = {}
---@type table<number, number[]>
local autocmds = {}
---@type table<number, number>
local fs_event_disabled_until = {}

-- Incremental scanning: track directories that need rescanning
---@type table<number, table<string, boolean>>
local dirty_dirs = {}
-- Force full scan on next poll (set on startup, watchdog restart, errors)
---@type table<number, boolean>
local needs_full_scan = {}
-- Threshold: if more than this many dirty dirs, do full scan instead
local DIRTY_DIRS_THRESHOLD = 10

-- Track solution file mtime per client for change detection
---@type table<number, { path: string, mtime: number }>
local sln_mtimes = {}
-- Timer for polling solution file changes (separate from fs_poll)
---@type table<number, uv_timer_t>
local sln_poll_timers = {}

-- Register state references with status module for RoslynFilewatchStatus command
pcall(function()
	local status_mod = require("roslyn_filewatch.status")
	if status_mod and status_mod.register_refs then
		status_mod.register_refs({
			watchers = watchers,
			pollers = pollers,
			watchdogs = watchdogs,
			snapshots = snapshots,
			last_events = last_events,
			dirty_dirs = dirty_dirs,
		})
	end
end)

------------------------------------------------------
-- Incremental scanning helpers
------------------------------------------------------

--- Mark a directory as needing rescan
---@param client_id number
---@param path string File or directory path that changed
local function mark_dirty_dir(client_id, path)
	if not path or path == "" then
		return
	end

	-- Initialize if needed
	if not dirty_dirs[client_id] then
		dirty_dirs[client_id] = {}
	end

	-- Get parent directory of the path
	local normalized = normalize_path(path)
	local parent = normalized:match("^(.+)/[^/]+$")
	if parent then
		dirty_dirs[client_id][parent] = true
	else
		-- Path is a root-level item, mark root
		dirty_dirs[client_id][normalized] = true
	end
end

--- Get and clear dirty directories for a client
---@param client_id number
---@return string[] dirs List of dirty directories
local function get_and_clear_dirty_dirs(client_id)
	local dirs = {}
	if dirty_dirs[client_id] then
		for dir, _ in pairs(dirty_dirs[client_id]) do
			table.insert(dirs, dir)
		end
		dirty_dirs[client_id] = {}
	end
	return dirs
end

--- Check if full scan is needed
---@param client_id number
---@return boolean
local function should_full_scan(client_id)
	-- Check explicit flag
	if needs_full_scan[client_id] then
		needs_full_scan[client_id] = nil
		return true
	end

	-- Check dirty dirs count threshold
	if dirty_dirs[client_id] then
		local count = 0
		for _ in pairs(dirty_dirs[client_id]) do
			count = count + 1
			if count > DIRTY_DIRS_THRESHOLD then
				return true
			end
		end
	end

	return false
end

--- Request full scan on next poll
---@param client_id number
local function request_full_scan(client_id)
	needs_full_scan[client_id] = true
end

------------------------------------------------------

--- Close buffers for deleted files (safe: runs in scheduled context)
---@param path string
local function close_deleted_buffers(path)
	-- BUG FIX: Guard against empty/nil path
	if not path or path == "" then
		return
	end

	path = normalize_path(path)

	local ok_uri, uri = pcall(vim.uri_from_fname, path)
	if not ok_uri or not uri then
		return
	end

	vim.defer_fn(function()
		local ok, st = pcall(function()
			return uv.fs_stat(path)
		end)
		if ok and st then
			-- File exists -> nothing to do
			return
		end

		vim.schedule(function()
			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(bufnr) then
					local bname = vim.api.nvim_buf_get_name(bufnr)
					if bname ~= "" then
						local ok_bufuri, bufuri = pcall(vim.uri_from_fname, normalize_path(bname))
						if ok_bufuri and bufuri == uri then
							pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
							notify("Closed buffer for deleted file: " .. path, vim.log.levels.DEBUG)
							break
						end
					end
				end
			end
		end)
	end, 200)
end

------------------------------------------------------

--- Queue and batch flush events
---@param client_id number
---@param evs roslyn_filewatch.FileChange[]
local function queue_events(client_id, evs)
	if not evs or #evs == 0 then
		return
	end

	if config.options.batching and config.options.batching.enabled then
		if not batch_queues[client_id] then
			batch_queues[client_id] = { events = {}, timer = nil }
		end
		local queue = batch_queues[client_id]
		vim.list_extend(queue.events, evs)

		if not queue.timer then
			local t = uv.new_timer()
			queue.timer = t
			t:start((config.options.batching.interval or 300), 0, function()
				local changes = queue.events
				queue.events = {}
				pcall(function()
					if queue.timer and not queue.timer:is_closing() then
						queue.timer:stop()
						queue.timer:close()
					end
				end)
				queue.timer = nil
				if #changes > 0 then
					vim.schedule(function()
						pcall(notify_roslyn, changes)
					end)
				end
			end)
		end
	else
		vim.schedule(function()
			pcall(notify_roslyn, evs)
		end)
	end
end

-------------------------------------------------

--- Cleanup all resources for a client
---@param client_id number
local function cleanup_client(client_id)
	-- Clear fs_event internal timers for this client (if any)
	pcall(function()
		if fs_event_mod and fs_event_mod.clear then
			pcall(fs_event_mod.clear, client_id)
		end
	end)

	if watchers[client_id] then
		pcall(function()
			local h = watchers[client_id]
			pcall(function()
				if h and not (h.is_closing and h:is_closing()) then
					if h.stop then
						pcall(h.stop, h)
					end
					if h.close then
						pcall(h.close, h)
					end
				end
			end)
		end)
		watchers[client_id] = nil
	end

	if pollers[client_id] then
		pcall(function()
			local p = pollers[client_id]
			if p then
				if p.stop then
					pcall(p.stop, p)
				end
				if p.close then
					pcall(p.close, p)
				end
			end
		end)
		pollers[client_id] = nil
	end

	if watchdogs[client_id] then
		pcall(function()
			local w = watchdogs[client_id]
			if w and not (w.is_closing and w:is_closing()) then
				pcall(function()
					w:stop()
					w:close()
				end)
			end
		end)
		watchdogs[client_id] = nil
	end

	if batch_queues[client_id] then
		if batch_queues[client_id].timer then
			pcall(function()
				if not batch_queues[client_id].timer:is_closing() then
					batch_queues[client_id].timer:stop()
					batch_queues[client_id].timer:close()
				end
			end)
		end
		batch_queues[client_id] = nil
	end

	-- Stop solution file poll timer
	if sln_poll_timers[client_id] then
		pcall(function()
			local t = sln_poll_timers[client_id]
			if t and not (t.is_closing and t:is_closing()) then
				t:stop()
				t:close()
			end
		end)
		sln_poll_timers[client_id] = nil
	end

	-- Clear rename buffers
	pcall(function()
		rename_mod.clear(client_id)
	end)

	-- Clear autocmds (the augroup will be auto-cleared when recreated)
	if autocmds[client_id] then
		-- Also try to delete the augroup
		pcall(function()
			vim.api.nvim_del_augroup_by_name("RoslynFilewatch_" .. client_id)
		end)
		autocmds[client_id] = nil
	end
end

-- //////////////////////////////////////////////////
-- /////////////////////////////////////////////////

--- Stop watcher for a client
---@param client vim.lsp.Client
function M.stop(client)
	if not client then
		return
	end
	local cid = client.id
	-- Clear snapshot & restart state
	snapshots[cid] = nil
	restart_scheduled[cid] = nil
	restart_backoff_until[cid] = nil
	fs_event_disabled_until[cid] = nil
	last_events[cid] = nil
	sln_mtimes[cid] = nil
	sln_poll_timers[cid] = nil
	-- Clear incremental scanning state
	dirty_dirs[cid] = nil
	needs_full_scan[cid] = nil
	-- Cleanup handles/timers
	cleanup_client(cid)
	notify("Watcher stopped for client " .. (client.name or "<unknown>"), vim.log.levels.DEBUG)
end

--- Force resync for all active clients
--- Clears snapshots and sets needs_full_scan flag for next poll cycle
function M.resync()
	local clients = vim.lsp.get_clients()
	local resynced = 0

	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			local cid = client.id
			-- Clear snapshot to force full scan
			snapshots[cid] = {}
			-- Set full scan flag
			needs_full_scan[cid] = true
			-- Clear dirty dirs
			dirty_dirs[cid] = {}
			-- Update last event time
			last_events[cid] = os.time()
			resynced = resynced + 1
			notify("Resync triggered for client " .. client.name, vim.log.levels.INFO)
		end
	end

	if resynced > 0 then
		vim.notify("[roslyn-filewatch] Resync triggered for " .. resynced .. " client(s)", vim.log.levels.INFO)
	else
		vim.notify("[roslyn-filewatch] No active Roslyn clients to resync", vim.log.levels.WARN)
	end
end

-- /////////////////////////////////////////////////
-- /////////////////////////////////////////////////

--- Start watcher for a client
---@param client vim.lsp.Client
function M.start(client)
	if not client then
		return
	end

	-- If client already stopped, nothing to do
	if client.is_stopped and client.is_stopped() then
		return
	end

	-- Prevent duplicate starts. Check all handles so poller-only case doesn't start duplicates.
	if watchers[client.id] or pollers[client.id] or watchdogs[client.id] then
		return -- already running
	end

	-- Tunables
	local POLL_INTERVAL = (config.options and config.options.poll_interval) or 3000
	local POLLER_RESTART_THRESHOLD = (config.options and config.options.poller_restart_threshold) or 2
	local WATCHDOG_IDLE = (config.options and config.options.watchdog_idle) or 60
	local RENAME_WINDOW_MS = (config.options and config.options.rename_detection_ms) or 300

	local root = client.config and client.config.root_dir
	if not root then
		notify("No root_dir for client " .. (client.name or "<unknown>"), vim.log.levels.ERROR)
		return
	end
	root = normalize_path(root)

	--- Restart watcher with backoff and optional fs_event disable flag
	---@param reason? string
	---@param delay_ms? number
	---@param disable_fs_event? boolean
	local function restart_watcher(reason, delay_ms, disable_fs_event)
		delay_ms = delay_ms or 300

		-- BUG FIX: Set restart_scheduled IMMEDIATELY to prevent race condition
		if restart_scheduled[client.id] then
			return
		end
		restart_scheduled[client.id] = true

		local now = os.time()
		local until_ts = restart_backoff_until[client.id] or 0
		if now < until_ts then
			notify("Restart suppressed due to backoff for client " .. client.name, vim.log.levels.DEBUG)
			restart_scheduled[client.id] = nil
			return
		end

		if disable_fs_event then
			-- Disable fs_event attempts for a short window (avoid re-creating broken handle)
			fs_event_disabled_until[client.id] = now + 5 -- 5 seconds
		end

		restart_backoff_until[client.id] = now + math.ceil(delay_ms / 1000)

		vim.defer_fn(function()
			restart_scheduled[client.id] = nil

			if client.is_stopped() then
				return
			end

			notify(
				"Restarting watcher for client "
					.. client.name
					.. " (reason: "
					.. tostring(reason or "unspecified")
					.. ")",
				vim.log.levels.DEBUG
			)

			-- LIGHTWEIGHT RESTART: Only recreate fs_event handle, preserve snapshot
			-- This avoids the expensive full tree scan that was causing freezes

			-- Stop old fs_event handle if exists
			if watchers[client.id] then
				pcall(function()
					local h = watchers[client.id]
					if h and not (h.is_closing and h:is_closing()) then
						if h.stop then
							pcall(h.stop, h)
						end
						if h.close then
							pcall(h.close, h)
						end
					end
				end)
				watchers[client.id] = nil
			end

			-- Recreate fs_event handle (if not disabled)
			local use_fs_event = not config.options.force_polling
			if fs_event_disabled_until[client.id] and os.time() < fs_event_disabled_until[client.id] then
				use_fs_event = false
			end

			if use_fs_event then
				local handle, err = fs_event_mod.start(client, root, snapshots, {
					notify = notify,
					queue_events = queue_events,
					notify_roslyn_renames = notify_roslyn_renames,
					restart_watcher = restart_watcher,
					mark_dirty_dir = mark_dirty_dir,
				})
				if handle then
					watchers[client.id] = handle
				else
					notify("Failed to recreate fs_event: " .. tostring(err), vim.log.levels.DEBUG)
				end
			end

			-- Note: Snapshot is preserved, no full scan needed
			-- The poller will continue with incremental scanning using dirty_dirs
		end, delay_ms)
	end

	---@type roslyn_filewatch.Helpers
	local helpers = {
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		queue_events = queue_events,
		close_deleted_buffers = close_deleted_buffers,
		restart_watcher = restart_watcher,
		last_events = last_events,
	}

	-- Choose whether to attempt native fs_event
	-- IMPROVEMENT: Enable fs_event on Windows since error handling is robust
	local force_polling = (config.options and config.options.force_polling) or false
	local disabled_until = fs_event_disabled_until[client.id] or 0
	local now = os.time()
	local use_fs_event = not force_polling and now >= disabled_until

	if use_fs_event then
		local handle, start_err = fs_event_mod.start(client, root, snapshots, {
			config = config,
			rename_mod = rename_mod,
			snapshot_mod = snapshot_mod,
			notify = notify,
			notify_roslyn_renames = notify_roslyn_renames,
			queue_events = queue_events,
			close_deleted_buffers = close_deleted_buffers,
			restart_watcher = restart_watcher,
			mark_dirty_dir = mark_dirty_dir,
			mtime_ns = mtime_ns,
			identity_from_stat = identity_from_stat,
			same_file_info = same_file_info,
			normalize_path = normalize_path,
			last_events = last_events,
			rename_window_ms = RENAME_WINDOW_MS,
		})

		if not handle then
			-- If native start failed, temporarily disable attempts and continue with poller
			notify("Failed to create fs_event: " .. tostring(start_err), vim.log.levels.WARN)
			fs_event_disabled_until[client.id] = os.time() + 5
			use_fs_event = false
		else
			watchers[client.id] = handle
			last_events[client.id] = os.time()
		end
	else
		local is_win = utils.is_windows()
		notify(
			"Using poller-only mode for client "
				.. client.name
				.. " (force_polling="
				.. tostring(force_polling)
				.. ", disabled_until="
				.. tostring(disabled_until > now)
				.. ")",
			vim.log.levels.DEBUG
		)

		-- Prime last_events so the watchdog does not immediately treat this as idle
		last_events[client.id] = os.time()
	end

	-- Always create poller fallback (keeps snapshot reliable)
	-- Request full scan on startup
	needs_full_scan[client.id] = true

	-- Capture initial solution file mtime for change detection
	-- This is used to detect when Unity modifies .slnx and adds new projects
	if config.options.solution_aware then
		local ok, sln_parser = pcall(require, "roslyn_filewatch.watcher.sln_parser")
		if ok and sln_parser and sln_parser.get_sln_info then
			local sln_info = sln_parser.get_sln_info(root)
			if sln_info then
				-- Capture initial list of csproj files
				local initial_csproj = {}
				local csproj_files = vim.fn.glob(root .. "/*.csproj", false, true)
				for _, csproj in ipairs(csproj_files or {}) do
					local p = normalize_path(csproj)
					local st = uv.fs_stat(p)
					initial_csproj[p] = st and st.mtime.sec or 0
				end

				sln_mtimes[client.id] = {
					path = sln_info.path,
					mtime = sln_info.mtime,
					csproj_files = initial_csproj,
				}
			else
				vim.schedule(function()
					vim.notify("[roslyn-filewatch] No solution file found in: " .. root, vim.log.levels.WARN)
				end)
			end
		else
			vim.schedule(function()
				vim.notify("[roslyn-filewatch] Failed to load sln_parser", vim.log.levels.WARN)
			end)
		end
	else
		notify("[SLN] solution_aware is disabled", vim.log.levels.DEBUG)
	end

	--- Check if solution file has changed since last poll
	---@param cid number Client ID
	---@param croot string Root path
	---@return boolean changed True if solution file mtime changed
	local function check_sln_changed(cid, croot)
		if not config.options.solution_aware then
			return false
		end

		local cached = sln_mtimes[cid]
		if not cached then
			return false
		end

		-- Get current mtime of solution file
		local ok, sln_parser = pcall(require, "roslyn_filewatch.watcher.sln_parser")
		if not ok or not sln_parser or not sln_parser.get_sln_info then
			return false
		end

		local current_info = sln_parser.get_sln_info(croot)
		if not current_info then
			return false
		end

		-- Check if mtime changed
		if current_info.mtime ~= cached.mtime then
			-- notify("[SLN] mtime changed: " .. tostring(cached.mtime) .. " -> " .. tostring(current_info.mtime), vim.log.levels.INFO)
			-- Update cached mtime, but PRESERVE the project tracking set!
			local old_csproj = cached.csproj_files
			sln_mtimes[cid] = { path = current_info.path, mtime = current_info.mtime, csproj_files = old_csproj }
			return true
		end

		return false
	end

	local poller, poll_err = fs_poll_mod.start(client, root, snapshots, {
		scan_tree = scan_tree,
		partial_scan = snapshot_mod.partial_scan,
		get_dirty_dirs = get_and_clear_dirty_dirs,
		should_full_scan = should_full_scan,
		identity_from_stat = identity_from_stat,
		same_file_info = same_file_info,
		queue_events = queue_events,
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		close_deleted_buffers = close_deleted_buffers,
		restart_watcher = restart_watcher,
		last_events = last_events,
		poll_interval = POLL_INTERVAL,
		poller_restart_threshold = POLLER_RESTART_THRESHOLD,
		-- check_sln_changed = check_sln_changed, -- Disabled to prevent full scan freezes
	})

	if not poller then
		notify("Failed to create poller: " .. tostring(poll_err), vim.log.levels.ERROR)
		-- Close any fs_event to avoid leaking
		pcall(function()
			if watchers[client.id] and watchers[client.id].close then
				watchers[client.id]:close()
			end
		end)
		return
	end
	pollers[client.id] = poller

	-- Create a separate timer to check for solution file changes
	-- This is needed because fs_poll only fires when root directory stat changes,
	-- not when files inside (like .slnx) are modified
	if config.options.solution_aware and sln_mtimes[client.id] then
		local sln_timer = uv.new_timer()
		if sln_timer then
			-- vim.schedule(function()
			-- 	vim.notify("[roslyn-filewatch] Started solution file watcher (poll: " .. POLL_INTERVAL .. "ms)", vim.log.levels.INFO)
			-- end)
			sln_timer:start(POLL_INTERVAL, POLL_INTERVAL, function()
				-- Safety check: stop if client stopped
				if client.is_stopped and client.is_stopped() then
					pcall(function()
						sln_timer:stop()
						sln_timer:close()
					end)
					sln_poll_timers[client.id] = nil
					return
				end

				-- ASYNC Solution File Check
				-- Use cached path directly - NO directory scan!
				local cached = sln_mtimes[client.id]
				if not cached or not cached.path then
					return
				end

				-- Async stat the solution file
				uv.fs_stat(cached.path, function(err, stat)
					if err or not stat then
						return
					end

					-- Calculate mtime in nanoseconds for precision
					local current_mtime = stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)
					
					-- Check if mtime changed
					if current_mtime == cached.mtime then
						return -- No change, skip
					end

					-- Update cached mtime (preserve csproj_files)
					local old_csproj = cached.csproj_files
					sln_mtimes[client.id] = { 
						path = cached.path, 
						mtime = current_mtime, 
						csproj_files = old_csproj 
					}

					-- Solution changed! Trigger async project scan
					vim.schedule(function()
						local sln_info = sln_mtimes[client.id]
						if not sln_info or not sln_info.path then
							return
						end

						-- HELPER: Ensure path is canonical for Roslyn on Windows
						local function to_roslyn_path(p)
							p = normalize_path(p)
							if vim.loop.os_uname().sysname == "Windows_NT" then
								p = p:gsub("^(%a):", function(l)
									return l:upper() .. ":"
								end)
								p = p:gsub("/", "\\")
							end
							return p
						end

						-- Scan csproj files (glob is fast for root-level files)
						local csproj_files = vim.fn.glob(root .. "/*.csproj", false, true)
						local previous_csproj = sln_info.csproj_files or {}

						-- Async Collection State
						local pending = 0
						local collected_mtimes = {}
						
						-- Completion Handler
						local function check_done()
							if pending == 0 then
								vim.schedule(function()
									local new_projects_list = {}
									local current_csproj_set = {}
									local new_projects_count = 0

									for internal_path, current_mtime_sec in pairs(collected_mtimes) do
										current_csproj_set[internal_path] = current_mtime_sec
										
										local old_mtime_sec = previous_csproj[internal_path]
										if sln_info.csproj_files and (not old_mtime_sec or old_mtime_sec ~= current_mtime_sec) then
											local roslyn_path = to_roslyn_path(internal_path)
											table.insert(new_projects_list, roslyn_path)
											new_projects_count = new_projects_count + 1
										end
									end
									
									-- Init check
									if not sln_info.csproj_files then
										sln_mtimes[client.id].csproj_files = current_csproj_set
										return
									end
									
									-- Update tracking set
									sln_mtimes[client.id].csproj_files = current_csproj_set

									-- Notify Roslyn if needed
									if new_projects_count > 0 then
										local clients_list = vim.lsp.get_clients()
										for _, c in ipairs(clients_list) do
											if vim.tbl_contains(config.options.client_names, c.name) then
												local project_uris = vim.tbl_map(function(p)
													return vim.uri_from_fname(p)
												end, new_projects_list)

												pcall(function()
													c:notify("project/open", {
														projects = project_uris,
													})
												end)
												
												-- Trigger diagnostic refresh
												vim.defer_fn(function()
													if c.is_stopped and c.is_stopped() then return end
													local attached_bufs = vim.lsp.get_buffers_by_client_id(c.id)
													for _, buf in ipairs(attached_bufs or {}) do
														if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
															pcall(function()
																c:request(
																	vim.lsp.protocol.Methods.textDocument_diagnostic,
																	{ textDocument = vim.lsp.util.make_text_document_params(buf) },
																	nil,
																	buf
																)
															end)
														end
													end
												end, 2000)
											end
										end
									end
								end)
							end
						end

						-- Launch Async Stats for csproj files
						for _, csproj in ipairs(csproj_files or {}) do
							local internal_path = normalize_path(csproj)
							pending = pending + 1
							uv.fs_stat(internal_path, function(csproj_err, csproj_st)
								if not csproj_err and csproj_st then
									collected_mtimes[internal_path] = csproj_st.mtime.sec
								else
									collected_mtimes[internal_path] = 0
								end
								pending = pending - 1
								check_done()
							end)
						end
						
						-- Handle empty list case
						check_done()
					end)
				end)
			end)
			sln_poll_timers[client.id] = sln_timer
		else
			vim.schedule(function()
				vim.notify("[roslyn-filewatch] Failed to create solution timer", vim.log.levels.ERROR)
			end)
		end
	else
		if not config.options.solution_aware then
			notify("[SLN] Timer not started: solution_aware disabled", vim.log.levels.DEBUG)
		elseif not sln_mtimes[client.id] then
			vim.schedule(function()
				vim.notify("[roslyn-filewatch] Timer not started: no solution file tracked", vim.log.levels.WARN)
			end)
		end
	end

	-- Watchdog
	local watchdog, watchdog_err = watchdog_mod.start(client, root, snapshots, {
		notify = notify,
		restart_watcher = restart_watcher,
		get_handle = function()
			return watchers[client.id]
		end,
		last_events = last_events,
		watchdog_idle = WATCHDOG_IDLE,
		use_fs_event = use_fs_event,
	})
	if not watchdog then
		notify("Failed to start watchdog: " .. tostring(watchdog_err), vim.log.levels.ERROR)
		pcall(function()
			if pollers[client.id] and pollers[client.id].close then
				pollers[client.id]:close()
			end
			if watchers[client.id] and watchers[client.id].close then
				watchers[client.id]:close()
			end
		end)
		return
	end
	watchdogs[client.id] = watchdog

	-- Autocmds to keep editor <-> fs state coherent
	local autocmd_ids = autocmds_mod.start(client, root, snapshots, {
		notify = notify,
		restart_watcher = restart_watcher,
		normalize_path = normalize_path,
		queue_events = queue_events,
	})
	autocmds[client.id] = autocmd_ids

	notify("Watcher started for client " .. client.name .. " at root: " .. root, vim.log.levels.DEBUG)

	vim.api.nvim_create_autocmd("LspDetach", {
		callback = function(args)
			if args.data.client_id == client.id then
				-- Clear snapshot + state
				snapshots[client.id] = nil
				restart_scheduled[client.id] = nil
				restart_backoff_until[client.id] = nil
				fs_event_disabled_until[client.id] = nil
				last_events[client.id] = nil
				sln_mtimes[client.id] = nil
				-- Clear incremental scanning state
				dirty_dirs[client.id] = nil
				needs_full_scan[client.id] = nil
				-- Cleanup handles & timers
				cleanup_client(client.id)
				notify("LspDetach: Watcher stopped for client " .. client.name, vim.log.levels.DEBUG)
				return true -- Remove this autocmd after cleanup
			end
		end,
	})
end

return M
