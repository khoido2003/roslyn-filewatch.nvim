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
local restore_mod = require("roslyn_filewatch.restore")

local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat
local same_file_info = utils.same_file_info
local normalize_path = utils.normalize_path
local scan_tree = snapshot_mod.scan_tree

local notify = notify_mod.user
local notify_roslyn = notify_mod.roslyn_changes
local notify_roslyn_renames = notify_mod.roslyn_renames

--- Async helper: scan root directory recursively for .csproj files and get their mtimes
--- This replaces blocking vim.fn.glob() calls
---@param root string Root directory to scan
---@param callback fun(csproj_map: table<string, number>) Called with path -> mtime.sec map
local function scan_csproj_async(root, callback)
	root = normalize_path(root)

	-- Use vim.fs.find for recursive search (more reliable than manual recursion)
	-- This matches the approach used in sln_parser.find_csproj_files
	local csproj_files = vim.fs.find(function(name, _)
		return name:match("%.csproj$") or name:match("%.vbproj$") or name:match("%.fsproj$")
	end, {
		path = root,
		limit = 50, -- reasonable limit to avoid scanning huge monorepos
		type = "file",
	})

	if not csproj_files or #csproj_files == 0 then
		vim.schedule(function()
			callback({})
		end)
		return
	end

	-- Normalize paths
	local csproj_paths = {}
	for _, path in ipairs(csproj_files) do
		table.insert(csproj_paths, normalize_path(path))
	end

	-- Async stat each csproj file
	local results = {}
	local pending = #csproj_paths

	if pending == 0 then
		vim.schedule(function()
			callback({})
		end)
		return
	end

	for _, path in ipairs(csproj_paths) do
		uv.fs_stat(path, function(stat_err, stat)
			if not stat_err and stat then
				results[path] = stat.mtime.sec
			else
				results[path] = 0
			end

			pending = pending - 1
			if pending == 0 then
				vim.schedule(function()
					callback(results)
				end)
			end
		end)
	end
end

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
-- Track pending csproj reload notifications per client to avoid duplicates
---@type table<number, { timer: uv_timer_t|nil, pending: boolean }>
local csproj_reload_pending = {}

-- Deferred loading state: pending project/open notifications
---@type table<number, { projects: string[], root: string }>
local deferred_projects = {}
-- Track if deferred loading has been triggered for a client
---@type table<number, boolean>
local deferred_triggered = {}

-- Diagnostics module (lazy loaded)
local diagnostics_mod = nil
local function get_diagnostics_mod()
	if not diagnostics_mod then
		local ok, mod = pcall(require, "roslyn_filewatch.diagnostics")
		if ok then
			diagnostics_mod = mod
		end
	end
	return diagnostics_mod
end

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

	-- AUTO-RESTORE: Check for .csproj changes in the event stream
	-- This catches ALL changes (fs_event, fs_poll) regardless of solution state
	if config.options.enable_autorestore then
		for _, ev in ipairs(evs) do
			local uri = ev.uri
			if uri and (uri:match("%.csproj$") or uri:match("%.vbproj$") or uri:match("%.fsproj$")) then
				local path = vim.uri_to_fname(uri)
				pcall(restore_mod.schedule_restore, path)
			end
		end
	end

	-- For csproj-only projects: Ensure project is opened when new .cs files are created
	-- This ensures the LSP recognizes new files even if project wasn't opened yet
	if config.options.solution_aware then
		local sln_info = sln_mtimes[client_id]
		if sln_info and sln_info.csproj_only and sln_info.csproj_files then
			local has_new_cs_file = false
			for _, ev in ipairs(evs) do
				local uri = ev.uri
				if uri and ev.type == 1 then -- Created file
					local path = vim.uri_to_fname(uri)
					if path:match("%.cs$") or path:match("%.vb$") or path:match("%.fs$") then
						has_new_cs_file = true
						break
					end
				end
			end

			if has_new_cs_file then
				-- Debounce csproj reload notifications to avoid constant restores
				-- Only trigger reload once per batch of file creations
				if not csproj_reload_pending[client_id] then
					csproj_reload_pending[client_id] = { timer = nil, pending = false }
				end
				local pending_state = csproj_reload_pending[client_id]

				-- Cancel existing timer if any
				if pending_state.timer then
					pcall(function()
						if not pending_state.timer:is_closing() then
							pending_state.timer:stop()
							pending_state.timer:close()
						end
					end)
					pending_state.timer = nil
				end

				-- Mark as pending
				pending_state.pending = true

				-- Create debounced timer (500ms debounce to batch multiple file creations)
				local timer = uv.new_timer()
				pending_state.timer = timer
				timer:start(500, 0, function()
					pending_state.timer = nil
					pending_state.pending = false

					vim.schedule(function()
						local clients_list = vim.lsp.get_clients()
						for _, c in ipairs(clients_list) do
							if vim.tbl_contains(config.options.client_names, c.name) and c.id == client_id then
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

								-- Collect all csproj paths
								local project_paths = {}
								for csproj_path, _ in pairs(sln_info.csproj_files) do
									table.insert(project_paths, to_roslyn_path(csproj_path))
								end

								if #project_paths > 0 then
									-- Function to send project/open notification
									local function send_project_open()
										local project_uris = vim.tbl_map(function(p)
											return vim.uri_from_fname(p)
										end, project_paths)

										pcall(function()
											c:notify("project/open", {
												projects = project_uris,
											})
										end)

										notify(
											"[CSPROJ] Sent project/open (" .. #project_paths .. " csproj file(s))",
											vim.log.levels.DEBUG
										)
									end

									-- Send csproj CHANGE events to trigger Roslyn project reload
									-- This is what happens when an old file is opened
									local csproj_change_events = {}
									for _, csproj_path in ipairs(project_paths) do
										table.insert(csproj_change_events, {
											uri = vim.uri_from_fname(csproj_path),
											type = 2, -- Changed
										})
									end

									-- Send csproj change events and project/open
									if #csproj_change_events > 0 then
										pcall(notify_roslyn, csproj_change_events)
										notify(
											"[CSPROJ] Sent csproj change events to trigger project reload ("
												.. #csproj_change_events
												.. " csproj file(s))",
											vim.log.levels.DEBUG
										)
									end
									send_project_open()

									-- Trigger restore if enabled (restore is already debounced internally)
									if config.options.enable_autorestore then
										-- Only restore once, even if multiple files are created
										local restore_triggered = false
										for _, csproj_path in ipairs(project_paths) do
											if not restore_triggered then
												restore_triggered = true
												-- Schedule restore with callback to send reload after completion
												pcall(restore_mod.schedule_restore, csproj_path, function(restored_path)
													-- After restore completes, send reload notifications
													vim.defer_fn(function()
														if c.is_stopped and c.is_stopped() then
															return
														end
														-- Send csproj change events again to force reload
														if #csproj_change_events > 0 then
															pcall(notify_roslyn, csproj_change_events)
														end
														send_project_open()
														-- Request diagnostics refresh
														vim.defer_fn(function()
															if c.is_stopped and c.is_stopped() then
																return
															end
															local attached_bufs = vim.lsp.get_buffers_by_client_id(c.id)
															for _, buf in ipairs(attached_bufs or {}) do
																if
																	vim.api.nvim_buf_is_valid(buf)
																	and vim.api.nvim_buf_is_loaded(buf)
																then
																	pcall(function()
																		c:request(
																			vim.lsp.protocol.Methods.textDocument_diagnostic,
																			{
																				textDocument = vim.lsp.util.make_text_document_params(
																					buf
																				),
																			},
																			nil,
																			buf
																		)
																	end)
																end
															end
														end, 500)
													end, 500)
												end)
											end
										end
									end
								end
								break
							end
						end
					end)
				end)
			end
		end
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
	-- Clear csproj reload pending state
	if csproj_reload_pending[cid] then
		if csproj_reload_pending[cid].timer then
			pcall(function()
				if not csproj_reload_pending[cid].timer:is_closing() then
					csproj_reload_pending[cid].timer:stop()
					csproj_reload_pending[cid].timer:close()
				end
			end)
		end
		csproj_reload_pending[cid] = nil
	end
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
	local POLL_INTERVAL = (config.options and config.options.poll_interval) or 5000 -- VS Code-like: poll less frequently
	local POLLER_RESTART_THRESHOLD = (config.options and config.options.poller_restart_threshold) or 2
	local WATCHDOG_IDLE = (config.options and config.options.watchdog_idle) or 60
	local RENAME_WINDOW_MS = (config.options and config.options.rename_detection_ms) or 300
	local ACTIVITY_QUIET_PERIOD = (config.options and config.options.activity_quiet_period) or 5

	local root = client.config and client.config.root_dir
	if not root then
		notify("No root_dir for client " .. (client.name or "<unknown>"), vim.log.levels.ERROR)
		return
	end
	root = normalize_path(root)

	-- Apply preset based on project type (Unity, console, large)
	config.apply_preset_for_root(root)
	local applied_preset = config.options._applied_preset
	if applied_preset then
		notify("[PRESET] Applied '" .. applied_preset .. "' preset for project", vim.log.levels.DEBUG)
	end

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
				-- Initialize with empty csproj_files, then populate asynchronously
				sln_mtimes[client.id] = {
					path = sln_info.path,
					mtime = sln_info.mtime,
					csproj_files = nil, -- Will be populated async
				}

				-- Async scan csproj files (non-blocking)
				scan_csproj_async(root, function(initial_csproj)
					if sln_mtimes[client.id] then
						sln_mtimes[client.id].csproj_files = initial_csproj
					end
				end)
			else
				-- No solution file found - check for csproj-only project
				-- This handles simple C# console projects without .sln files
				notify("[SLN] No solution file found, checking for csproj-only project", vim.log.levels.DEBUG)

				-- Async scan for csproj files and set up tracking
				scan_csproj_async(root, function(csproj_files)
					if not csproj_files or vim.tbl_count(csproj_files) == 0 then
						vim.schedule(function()
							vim.notify(
								"[roslyn-filewatch] No solution or csproj files found in: " .. root,
								vim.log.levels.WARN
							)
						end)
						return
					end

					-- Set up csproj tracking (csproj_only mode - no solution path)
					sln_mtimes[client.id] = {
						path = nil, -- No solution file
						mtime = 0,
						csproj_files = csproj_files,
						csproj_only = true, -- Flag to identify csproj-only mode
					}

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

					-- Collect all csproj paths for project/open notification
					local project_paths = {}
					for csproj_path, _ in pairs(csproj_files) do
						table.insert(project_paths, to_roslyn_path(csproj_path))
					end

					if #project_paths > 0 then
						vim.schedule(function()
							-- Find matching Roslyn clients and send project/open
							local clients_list = vim.lsp.get_clients()
							for _, c in ipairs(clients_list) do
								if vim.tbl_contains(config.options.client_names, c.name) then
									local project_uris = vim.tbl_map(function(p)
										return vim.uri_from_fname(p)
									end, project_paths)

									pcall(function()
										c:notify("project/open", {
											projects = project_uris,
										})
									end)

									notify(
										"[CSPROJ] Sent project/open for " .. #project_paths .. " csproj file(s)",
										vim.log.levels.DEBUG
									)

									-- Trigger diagnostic refresh after a delay
									vim.defer_fn(function()
										if c.is_stopped and c.is_stopped() then
											return
										end
										local attached_bufs = vim.lsp.get_buffers_by_client_id(c.id)
										for _, buf in ipairs(attached_bufs or {}) do
											if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
												pcall(function()
													c:request(vim.lsp.protocol.Methods.textDocument_diagnostic, {
														textDocument = vim.lsp.util.make_text_document_params(buf),
													}, nil, buf)
												end)
											end
										end
									end, 2000)
								end
							end
						end)
					end
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
		scan_tree_async = snapshot_mod.scan_tree_async, -- NEW: Async non-blocking scan
		is_scanning = snapshot_mod.is_scanning, -- NEW: Check scan in progress
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
		activity_quiet_period = ACTIVITY_QUIET_PERIOD,
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

	-- Create a separate timer to check for solution/csproj file changes
	-- This is needed because fs_poll only fires when root directory stat changes,
	-- not when files inside (like .slnx or .csproj) are modified
	if config.options.solution_aware and sln_mtimes[client.id] then
		local sln_timer = uv.new_timer()
		if sln_timer then
			local is_csproj_only = sln_mtimes[client.id].csproj_only == true
			notify(
				"[PROJECT] Started project watcher (mode: " .. (is_csproj_only and "csproj-only" or "solution") .. ")",
				vim.log.levels.DEBUG
			)

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

				local cached = sln_mtimes[client.id]
				if not cached then
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

				-- CSPROJ-ONLY MODE: Just poll for new csproj files
				if cached.csproj_only then
					-- Async scan for new csproj files
					scan_csproj_async(root, function(collected_mtimes)
						local sln_info = sln_mtimes[client.id]
						if not sln_info then
							return
						end

						local previous_csproj = sln_info.csproj_files or {}
						local new_projects_list = {}
						local current_csproj_set = {}
						local new_projects_count = 0

						for internal_path, current_mtime_sec in pairs(collected_mtimes) do
							current_csproj_set[internal_path] = current_mtime_sec

							local old_mtime_sec = previous_csproj[internal_path]
							if not old_mtime_sec or old_mtime_sec ~= current_mtime_sec then
								local roslyn_path = to_roslyn_path(internal_path)
								table.insert(new_projects_list, roslyn_path)
								new_projects_count = new_projects_count + 1

								-- AUTO-RESTORE: If existing project changed, trigger restore
								if old_mtime_sec and old_mtime_sec ~= current_mtime_sec then
									pcall(restore_mod.schedule_restore, internal_path)
								end
							end
						end

						-- Update tracking set
						if sln_mtimes[client.id] then
							sln_mtimes[client.id].csproj_files = current_csproj_set
						end

						-- Notify Roslyn if new projects found
						if new_projects_count > 0 then
							vim.schedule(function()
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

										notify(
											"[CSPROJ] Detected " .. new_projects_count .. " new/changed csproj file(s)",
											vim.log.levels.DEBUG
										)

										-- Trigger diagnostic refresh
										vim.defer_fn(function()
											if c.is_stopped and c.is_stopped() then
												return
											end
											local attached_bufs = vim.lsp.get_buffers_by_client_id(c.id)
											for _, buf in ipairs(attached_bufs or {}) do
												if
													vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
												then
													pcall(function()
														c:request(vim.lsp.protocol.Methods.textDocument_diagnostic, {
															textDocument = vim.lsp.util.make_text_document_params(buf),
														}, nil, buf)
													end)
												end
											end
										end, 2000)
									end
								end
							end)
						end
					end)
					return -- Early return for csproj-only mode
				end

				-- SOLUTION MODE: Check solution file first, then scan csproj
				if not cached.path then
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
						csproj_files = old_csproj,
					}

					-- Solution changed! Trigger async project scan
					vim.schedule(function()
						local sln_info = sln_mtimes[client.id]
						if not sln_info or not sln_info.path then
							return
						end

						local previous_csproj = sln_info.csproj_files or {}

						-- Use async csproj scanning (non-blocking)
						scan_csproj_async(root, function(collected_mtimes)
							local new_projects_list = {}
							local current_csproj_set = {}
							local new_projects_count = 0

							for internal_path, current_mtime_sec in pairs(collected_mtimes) do
								current_csproj_set[internal_path] = current_mtime_sec

								local old_mtime_sec = previous_csproj[internal_path]
								if
									sln_info.csproj_files and (not old_mtime_sec or old_mtime_sec ~= current_mtime_sec)
								then
									local roslyn_path = to_roslyn_path(internal_path)
									table.insert(new_projects_list, roslyn_path)
									new_projects_count = new_projects_count + 1

									-- AUTO-RESTORE: If existing project changed, trigger restore
									if old_mtime_sec and old_mtime_sec ~= current_mtime_sec then
										pcall(restore_mod.schedule_restore, internal_path)
									end
								end
							end

							-- Init check - first time populating csproj_files
							if not sln_info.csproj_files then
								if sln_mtimes[client.id] then
									sln_mtimes[client.id].csproj_files = current_csproj_set
								end
								return
							end

							-- Update tracking set
							if sln_mtimes[client.id] then
								sln_mtimes[client.id].csproj_files = current_csproj_set
							end

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
											if c.is_stopped and c.is_stopped() then
												return
											end
											local attached_bufs = vim.lsp.get_buffers_by_client_id(c.id)
											for _, buf in ipairs(attached_bufs or {}) do
												if
													vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
												then
													pcall(function()
														c:request(vim.lsp.protocol.Methods.textDocument_diagnostic, {
															textDocument = vim.lsp.util.make_text_document_params(buf),
														}, nil, buf)
													end)
												end
											end
										end, 2000)
									end
								end
							end
						end)
					end)
				end)
			end)
			sln_poll_timers[client.id] = sln_timer
		else
			vim.schedule(function()
				vim.notify("[roslyn-filewatch] Failed to create project timer", vim.log.levels.ERROR)
			end)
		end
	else
		if not config.options.solution_aware then
			notify("[SLN] Timer not started: solution_aware disabled", vim.log.levels.DEBUG)
		elseif not sln_mtimes[client.id] then
			-- This should no longer happen since we now set sln_mtimes for csproj-only projects
			notify("[PROJECT] Timer not started: no project files tracked", vim.log.levels.DEBUG)
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
		sln_mtimes = sln_mtimes,
		restore_mod = restore_mod,
	})
	autocmds[client.id] = autocmd_ids

	notify("Watcher started for client " .. client.name .. " at root: " .. root, vim.log.levels.DEBUG)

	-- NEW: Project warm-up for faster Roslyn initialization
	local ok_warmup, warmup_mod = pcall(require, "roslyn_filewatch.project_warmup")
	if ok_warmup and warmup_mod and warmup_mod.warmup then
		warmup_mod.warmup(client)
	end

	-- NEW: Game engine context setup (Unity analyzers, Godot settings, etc.)
	local ok_context, context_mod = pcall(require, "roslyn_filewatch.game_context")
	if ok_context and context_mod and context_mod.setup then
		context_mod.setup(client)
	end

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
				-- Clear deferred loading state
				deferred_projects[client.id] = nil
				deferred_triggered[client.id] = nil
				-- Clear diagnostics state
				local diag_mod = get_diagnostics_mod()
				if diag_mod and diag_mod.clear_client then
					pcall(diag_mod.clear_client, client.id)
				end
				-- Clear project warmup state
				local ok_warmup, warmup_mod = pcall(require, "roslyn_filewatch.project_warmup")
				if ok_warmup and warmup_mod and warmup_mod.clear_client then
					pcall(warmup_mod.clear_client, client.id)
				end
				-- Cleanup handles & timers
				cleanup_client(client.id)
				notify("LspDetach: Watcher stopped for client " .. client.name, vim.log.levels.DEBUG)
				return true -- Remove this autocmd after cleanup
			end
		end,
	})
end

--- Reload all tracked projects for all active Roslyn clients
--- Forces Roslyn to refresh project information and diagnostics
function M.reload_projects()
	local clients = vim.lsp.get_clients()
	local reloaded = 0

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

	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			local cid = client.id
			local sln_info = sln_mtimes[cid]

			if sln_info and sln_info.csproj_files then
				local project_paths = {}
				for csproj_path, _ in pairs(sln_info.csproj_files) do
					table.insert(project_paths, to_roslyn_path(csproj_path))
				end

				if #project_paths > 0 then
					local project_uris = vim.tbl_map(function(p)
						return vim.uri_from_fname(p)
					end, project_paths)

					-- Send project/open notification
					pcall(function()
						client:notify("project/open", {
							projects = project_uris,
						})
					end)

					reloaded = reloaded + 1
					notify("[RELOAD] Sent project/open for " .. #project_paths .. " project(s)", vim.log.levels.DEBUG)

					-- Trigger diagnostic refresh after a delay
					vim.defer_fn(function()
						if client.is_stopped and client.is_stopped() then
							return
						end

						-- Use throttled diagnostics if available
						local diag_mod = get_diagnostics_mod()
						if diag_mod and diag_mod.request_visible_diagnostics then
							diag_mod.request_visible_diagnostics(cid)
						else
							-- Fallback: request diagnostics for attached buffers
							local attached_bufs = vim.lsp.get_buffers_by_client_id(cid)
							for _, buf in ipairs(attached_bufs or {}) do
								if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
									pcall(function()
										client:request(vim.lsp.protocol.Methods.textDocument_diagnostic, {
											textDocument = vim.lsp.util.make_text_document_params(buf),
										}, nil, buf)
									end)
								end
							end
						end
					end, 2000)
				end
			end
		end
	end

	if reloaded > 0 then
		vim.notify("[roslyn-filewatch] Reloaded projects for " .. reloaded .. " client(s)", vim.log.levels.INFO)
	else
		vim.notify("[roslyn-filewatch] No projects to reload", vim.log.levels.WARN)
	end
end

--- Trigger deferred project loading for a client
--- Called when first C# file is opened
---@param client_id number
local function trigger_deferred_loading(client_id)
	if deferred_triggered[client_id] then
		return -- Already triggered
	end

	local pending = deferred_projects[client_id]
	if not pending or #pending.projects == 0 then
		return
	end

	deferred_triggered[client_id] = true

	local delay = config.options.deferred_loading_delay_ms or 500

	vim.defer_fn(function()
		local client = vim.lsp.get_client_by_id(client_id)
		if not client or (client.is_stopped and client.is_stopped()) then
			return
		end

		local project_uris = vim.tbl_map(function(p)
			return vim.uri_from_fname(p)
		end, pending.projects)

		pcall(function()
			client:notify("project/open", {
				projects = project_uris,
			})
		end)

		notify("[DEFERRED] Sent project/open for " .. #pending.projects .. " project(s)", vim.log.levels.DEBUG)

		-- Trigger diagnostic refresh
		vim.defer_fn(function()
			if client.is_stopped and client.is_stopped() then
				return
			end
			local diag_mod = get_diagnostics_mod()
			if diag_mod and diag_mod.request_visible_diagnostics then
				diag_mod.request_visible_diagnostics(client_id)
			end
		end, 2000)
	end, delay)
end

--- Setup deferred loading autocmd for a client
---@param client_id number
---@param root string
local function setup_deferred_loading_autocmd(client_id)
	vim.api.nvim_create_autocmd("BufEnter", {
		group = vim.api.nvim_create_augroup("RoslynFilewatch_Deferred_" .. client_id, { clear = true }),
		pattern = "*.cs",
		callback = function()
			trigger_deferred_loading(client_id)
			-- Remove this autocmd after triggering
			if deferred_triggered[client_id] then
				pcall(function()
					vim.api.nvim_del_augroup_by_name("RoslynFilewatch_Deferred_" .. client_id)
				end)
			end
		end,
	})
end

return M
