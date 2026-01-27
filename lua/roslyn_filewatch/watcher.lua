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

-- Import shared utilities
local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat
local same_file_info = utils.same_file_info
local normalize_path = utils.normalize_path
local to_roslyn_path = utils.to_roslyn_path
local safe_close_handle = utils.safe_close_handle
local request_diagnostics_refresh = utils.request_diagnostics_refresh
local notify_project_open = utils.notify_project_open
local scan_tree = snapshot_mod.scan_tree

local notify = notify_mod.user
local notify_roslyn = notify_mod.roslyn_changes
local notify_roslyn_renames = notify_mod.roslyn_renames

local M = {}

------------------------------------------------------
-- CLIENT STATE
------------------------------------------------------

---@class ClientState
---@field watcher uv_fs_event_t|nil
---@field poller uv_fs_poll_t|nil
---@field watchdog uv_timer_t|nil
---@field sln_poll_timer uv_timer_t|nil
---@field batch_queue { events: roslyn_filewatch.FileChange[], timer: uv_timer_t|nil }|nil
---@field snapshot table<string, roslyn_filewatch.SnapshotEntry>
---@field last_event number Last event timestamp
---@field restart_scheduled boolean
---@field restart_backoff_until number
---@field fs_event_disabled_until number
---@field dirty_dirs table<string, boolean>
---@field needs_full_scan boolean
---@field sln_info { path: string|nil, mtime: number, csproj_files: table<string, number>|nil, csproj_only?: boolean }|nil
---@field csproj_reload_pending { timer: uv_timer_t|nil, pending: boolean }|nil
---@field root string|nil -- Root directory path for cleanup
---@field autocmd_ids number[]|nil

---@type table<number, ClientState>
local client_states = {}

-- Threshold: if more than this many dirty dirs, do full scan instead
local DIRTY_DIRS_THRESHOLD = 10

--- Get or create client state
---@param client_id number
---@return ClientState
local function get_client_state(client_id)
	if not client_states[client_id] then
		client_states[client_id] = {
			watcher = nil,
			poller = nil,
			watchdog = nil,
			sln_poll_timer = nil,
			batch_queue = nil,
			snapshot = {},
			last_event = 0,
			restart_scheduled = false,
			restart_backoff_until = 0,
			fs_event_disabled_until = 0,
			dirty_dirs = {},
			needs_full_scan = false,
			sln_info = nil,
			csproj_reload_pending = nil,
			autocmd_ids = nil,
			root = nil,
		}
	end
	return client_states[client_id]
end

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
		-- Create proxy tables that read from client_states
		local watchers_proxy = setmetatable({}, {
			__index = function(_, k)
				return client_states[k] and client_states[k].watcher
			end,
			__pairs = function()
				local result = {}
				for k, v in pairs(client_states) do
					if v.watcher then
						result[k] = v.watcher
					end
				end
				return pairs(result)
			end,
		})
		local pollers_proxy = setmetatable({}, {
			__index = function(_, k)
				return client_states[k] and client_states[k].poller
			end,
		})
		local watchdogs_proxy = setmetatable({}, {
			__index = function(_, k)
				return client_states[k] and client_states[k].watchdog
			end,
		})
		local snapshots_proxy = setmetatable({}, {
			__index = function(_, k)
				return client_states[k] and client_states[k].snapshot
			end,
			__newindex = function(_, k, v)
				if client_states[k] then
					client_states[k].snapshot = v
				end
			end,
		})
		local last_events_proxy = setmetatable({}, {
			__index = function(_, k)
				return client_states[k] and client_states[k].last_event
			end,
			__newindex = function(_, k, v)
				if client_states[k] then
					client_states[k].last_event = v
				end
			end,
		})
		local dirty_dirs_proxy = setmetatable({}, {
			__index = function(_, k)
				return client_states[k] and client_states[k].dirty_dirs
			end,
		})

		status_mod.register_refs({
			watchers = watchers_proxy,
			pollers = pollers_proxy,
			watchdogs = watchdogs_proxy,
			snapshots = snapshots_proxy,
			last_events = last_events_proxy,
			dirty_dirs = dirty_dirs_proxy,
		})
	end
end)

------------------------------------------------------
-- ASYNC HELPERS
------------------------------------------------------

--- Async helper: scan root directory recursively for .csproj files and get their mtimes
--- Uses fully async uv.fs_scandir to avoid blocking during Unity index regeneration
---@param root string Root directory to scan
---@param callback fun(csproj_map: table<string, number>) Called with path -> mtime.sec map
local function scan_csproj_async(root, callback)
	root = normalize_path(root)

	local results = {}
	local pending_dirs = 0
	local scan_complete = false

	local ignore_dirs = config.options.ignore_dirs or {}
	local ignore_set = {}
	for _, d in ipairs(ignore_dirs) do
		ignore_set[d:lower()] = true
	end

	local function finish_scan()
		if scan_complete then
			return
		end
		scan_complete = true
		vim.schedule(function()
			callback(results)
		end)
	end

	local function scan_dir_async(dir)
		pending_dirs = pending_dirs + 1

		uv.fs_scandir(dir, function(err, scanner)
			if err or not scanner then
				pending_dirs = pending_dirs - 1
				if pending_dirs == 0 then
					finish_scan()
				end
				return
			end

			local subdirs = {}
			local csproj_paths = {}

			-- Collect entries synchronously (fs_scandir_next is fast)
			while true do
				local name, typ = uv.fs_scandir_next(scanner)
				if not name then
					break
				end

				local fullpath = normalize_path(dir .. "/" .. name)

				if typ == "directory" then
					-- Skip ignored directories
					if not ignore_set[name:lower()] then
						table.insert(subdirs, fullpath)
					end
				elseif typ == "file" then
					if name:match("%.csproj$") or name:match("%.vbproj$") or name:match("%.fsproj$") then
						table.insert(csproj_paths, fullpath)
					end
				end
			end

			-- Stat csproj files asynchronously
			for _, csproj_path in ipairs(csproj_paths) do
				pending_dirs = pending_dirs + 1
				uv.fs_stat(csproj_path, function(stat_err, stat)
					if not stat_err and stat then
						results[csproj_path] = stat.mtime.sec
					else
						results[csproj_path] = 0
					end
					pending_dirs = pending_dirs - 1
					if pending_dirs == 0 then
						finish_scan()
					end
				end)
			end

			-- Recurse into subdirs asynchronously
			for _, subdir in ipairs(subdirs) do
				-- Use defer_fn to avoid stack overflow on deep trees
				vim.defer_fn(function()
					scan_dir_async(subdir)
				end, 0)
			end

			pending_dirs = pending_dirs - 1
			if pending_dirs == 0 then
				finish_scan()
			end
		end)
	end

	scan_dir_async(root)
end

------------------------------------------------------
-- INCREMENTAL SCANNING HELPERS
------------------------------------------------------

--- Mark a directory as needing rescan
---@param client_id number
---@param path string File or directory path that changed
local function mark_dirty_dir(client_id, path)
	if not path or path == "" then
		return
	end

	local state = get_client_state(client_id)

	local normalized = normalize_path(path)
	local parent = normalized:match("^(.+)/[^/]+$")
	if parent then
		state.dirty_dirs[parent] = true
	else
		state.dirty_dirs[normalized] = true
	end
end

--- Get and clear dirty directories for a client
---@param client_id number
---@return string[] dirs List of dirty directories
local function get_and_clear_dirty_dirs(client_id)
	local state = get_client_state(client_id)
	local dirs = {}
	for dir, _ in pairs(state.dirty_dirs) do
		table.insert(dirs, dir)
	end
	state.dirty_dirs = {}
	return dirs
end

--- Check if full scan is needed
---@param client_id number
---@return boolean
local function should_full_scan(client_id)
	local state = get_client_state(client_id)

	if state.needs_full_scan then
		state.needs_full_scan = false
		return true
	end

	local count = 0
	for _ in pairs(state.dirty_dirs) do
		count = count + 1
		if count > DIRTY_DIRS_THRESHOLD then
			return true
		end
	end

	return false
end

--- Request full scan on next poll
---@param client_id number
local function request_full_scan(client_id)
	local state = get_client_state(client_id)
	state.needs_full_scan = true
end

------------------------------------------------------
-- PROJECT NOTIFICATION HELPERS
------------------------------------------------------

--- Collect Roslyn-formatted paths from sln_info
---@param sln_info { csproj_files: table<string, number>|nil }|nil
---@return string[] project_paths
local function collect_roslyn_project_paths(sln_info)
	if not sln_info or not sln_info.csproj_files then
		return {}
	end

	local project_paths = {}
	for csproj_path, _ in pairs(sln_info.csproj_files) do
		table.insert(project_paths, to_roslyn_path(csproj_path))
	end
	return project_paths
end

--- Send csproj change events to trigger Roslyn project reload
---@param project_paths string[] List of Roslyn-formatted project paths
local function send_csproj_change_events(project_paths)
	if #project_paths == 0 then
		return
	end

	local csproj_change_events = {}
	for _, csproj_path in ipairs(project_paths) do
		table.insert(csproj_change_events, {
			uri = vim.uri_from_fname(csproj_path),
			type = 2, -- Changed
		})
	end

	pcall(notify_roslyn, csproj_change_events)
	notify("[CSPROJ] Sent csproj change events (" .. #csproj_change_events .. " file(s))", vim.log.levels.DEBUG)
end

--- Handle csproj reload for a client (debounced)
--- Called when new .cs files are created in csproj-only projects
---@param client vim.lsp.Client
---@param sln_info table
local function handle_csproj_reload(client, sln_info)
	local state = get_client_state(client.id)

	-- Initialize pending state if needed
	if not state.csproj_reload_pending then
		state.csproj_reload_pending = { timer = nil, pending = false }
	end
	local pending_state = state.csproj_reload_pending

	-- Cancel existing timer if any
	if pending_state.timer then
		safe_close_handle(pending_state.timer)
		pending_state.timer = nil
	end

	pending_state.pending = true

	-- Create debounced timer (500ms debounce to batch multiple file creations)
	local timer = uv.new_timer()
	pending_state.timer = timer
	timer:start(500, 0, function()
		pending_state.timer = nil
		pending_state.pending = false

		vim.schedule(function()
			-- Check if client is still valid
			if client.is_stopped and client.is_stopped() then
				return
			end

			local project_paths = collect_roslyn_project_paths(sln_info)
			if #project_paths == 0 then
				return
			end

			-- Send csproj change events and project/open
			send_csproj_change_events(project_paths)
			notify_project_open(client, project_paths, notify)

			-- Trigger restore if enabled
			if config.options.enable_autorestore then
				-- Only restore once for the first csproj
				local first_path = project_paths[1]
				if first_path then
					pcall(restore_mod.schedule_restore, first_path, function(_)
						-- After restore completes, send reload notifications again
						vim.defer_fn(function()
							if client.is_stopped and client.is_stopped() then
								return
							end
							send_csproj_change_events(project_paths)
							notify_project_open(client, project_paths, notify)
							request_diagnostics_refresh(client, 500)
						end, 500)
					end)
				end
			end
		end)
	end)
end

------------------------------------------------------
-- EVENT QUEUE AND BATCHING
------------------------------------------------------

--- Process auto-restore logic (csproj changes + Unity fallback)
---@param client_id number
---@param evs roslyn_filewatch.FileChange[]
---@param state ClientState
local function process_auto_restore(client_id, evs, state)
	if not config.options.enable_autorestore then
		return
	end

	local restore_triggered = false

	-- 1. Check for explicit .csproj/.vbproj/.fsproj changes
	for _, ev in ipairs(evs) do
		local uri = ev.uri
		if uri and (uri:match("%.csproj$") or uri:match("%.vbproj$") or uri:match("%.fsproj$")) then
			local path = vim.uri_to_fname(uri)
			-- Standard delay (2s) for explicit project file changes
			pcall(restore_mod.schedule_restore, path, 2000)
			restore_triggered = true
		end
	end

	-- 2. Fallback: Check for source file creation
	-- If we didn't see a project file change, but we see a new .cs file,
	-- it might be Unity creating a file in a new folder. Unity will eventually
	-- regenerate the .csproj, but we might miss that event or it might be delayed.
	-- We trigger a restore with a LONGER delay (5s) to allow Unity to finish.
	if not restore_triggered then
		for _, ev in ipairs(evs) do
			if ev.type == 1 and ev.uri then -- Created
				local path = vim.uri_to_fname(ev.uri)
				if path:match("%.cs$") or path:match("%.vb$") or path:match("%.fs$") then
					-- Find which project this file likely belongs to
					if state.sln_info and state.sln_info.csproj_files then
						for csproj_path, _ in pairs(state.sln_info.csproj_files) do
							-- Trigger restore with 5000ms delay
							-- This prevents racing with Unity's internal generation
							pcall(restore_mod.schedule_restore, csproj_path, 5000)
						end
						-- Only trigger once per batch
						break
					end
				end
			end
		end
	end
end

--- Process csproj-only mode reload logic
---@param client_id number
---@param evs roslyn_filewatch.FileChange[]
---@param state ClientState
local function process_csproj_only_reload(client_id, evs, state)
	if not config.options.solution_aware or not state.sln_info or not state.sln_info.csproj_only then
		return
	end

	for _, ev in ipairs(evs) do
		local uri = ev.uri
		if uri and ev.type == 1 then -- Created file
			local path = vim.uri_to_fname(uri)
			if path:match("%.cs$") or path:match("%.vb$") or path:match("%.fs$") then
				-- Find the client and trigger reload
				local clients_list = vim.lsp.get_clients()
				for _, c in ipairs(clients_list) do
					if vim.tbl_contains(config.options.client_names, c.name) and c.id == client_id then
						handle_csproj_reload(c, state.sln_info)
						break
					end
				end
				break
			end
		end
	end
end

--- Queue and batch flush events
---@param client_id number
---@param evs roslyn_filewatch.FileChange[]
local function queue_events(client_id, evs)
	if not evs or #evs == 0 then
		return
	end

	local state = get_client_state(client_id)

	-- Handle auto-restore (including Unity fallback)
	process_auto_restore(client_id, evs, state)

	-- Handle csproj-only project reload
	process_csproj_only_reload(client_id, evs, state)

	-- Batching logic
	if config.options.batching and config.options.batching.enabled then
		if not state.batch_queue then
			state.batch_queue = { events = {}, timer = nil }
		end
		local queue = state.batch_queue
		vim.list_extend(queue.events, evs)

		if not queue.timer then
			local t = uv.new_timer()
			queue.timer = t
			t:start((config.options.batching.interval or 300), 0, function()
				local changes = queue.events
				queue.events = {}
				safe_close_handle(queue.timer)
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

------------------------------------------------------
-- CLIENT CLEANUP
------------------------------------------------------

--- Cleanup all resources for a client
---@param client_id number
local function cleanup_client(client_id)
	local state = client_states[client_id]
	if not state then
		return
	end

	-- Clear fs_event internal timers
	pcall(function()
		if fs_event_mod and fs_event_mod.clear then
			fs_event_mod.clear(client_id)
		end
	end)

	-- Close all handles
	safe_close_handle(state.watcher)
	state.watcher = nil

	safe_close_handle(state.poller)
	state.poller = nil

	safe_close_handle(state.watchdog)
	state.watchdog = nil

	safe_close_handle(state.sln_poll_timer)
	state.sln_poll_timer = nil

	-- Close batch queue timer
	if state.batch_queue and state.batch_queue.timer then
		safe_close_handle(state.batch_queue.timer)
		state.batch_queue = nil
	end

	-- Close csproj reload timer
	if state.csproj_reload_pending and state.csproj_reload_pending.timer then
		safe_close_handle(state.csproj_reload_pending.timer)
		state.csproj_reload_pending = nil
	end

	-- Clear rename buffers
	pcall(function()
		rename_mod.clear(client_id)
	end)

	-- Clear autocmds
	if state.autocmd_ids then
		pcall(function()
			vim.api.nvim_del_augroup_by_name("RoslynFilewatch_" .. client_id)
		end)
		state.autocmd_ids = nil
	end

	-- Clear autocmd tracking state
	pcall(function()
		if autocmds_mod and autocmds_mod.clear_client then
			autocmds_mod.clear_client(client_id)
		end
	end)

	-- Clear restore module timers/callbacks for this root
	if state.root then
		pcall(function()
			restore_mod.clear_for_root(state.root)
		end)
	end
end

------------------------------------------------------
-- PUBLIC API
------------------------------------------------------

--- Stop watcher for a client
---@param client vim.lsp.Client
function M.stop(client)
	if not client then
		return
	end

	local cid = client.id
	cleanup_client(cid)
	client_states[cid] = nil

	notify("Watcher stopped for client " .. (client.name or "<unknown>"), vim.log.levels.DEBUG)
end

--- Force resync for all active clients
function M.resync()
	local clients = vim.lsp.get_clients()
	local resynced = 0

	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			local state = get_client_state(client.id)

			-- Reset internal state
			state.snapshot = {}
			state.needs_full_scan = true
			state.dirty_dirs = {}
			state.last_event = os.time()

			-- Clear the project open tracking state so next file triggers project/open
			pcall(function()
				autocmds_mod.clear_client(client.id)
			end)

			-- Send project/open notifications if we have project info
			if state.sln_info and state.sln_info.csproj_files then
				local project_paths = collect_roslyn_project_paths(state.sln_info)
				if #project_paths > 0 then
					notify_project_open(client, project_paths, notify)
					notify("[RESYNC] Sent project/open for " .. #project_paths .. " project(s)", vim.log.levels.DEBUG)

					-- Trigger restore if autorestore is enabled
					if config.options.enable_autorestore then
						local first_path = project_paths[1]
						if first_path then
							pcall(restore_mod.schedule_restore, first_path, 1000)
						end
					end

					-- Request diagnostics refresh
					request_diagnostics_refresh(client, 2000)
				end
			end

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

------------------------------------------------------
-- WATCHER START
------------------------------------------------------

--- Start watcher for a client
---@param client vim.lsp.Client
function M.start(client)
	if not client then
		return
	end

	if client.is_stopped and client.is_stopped() then
		return
	end

	local state = get_client_state(client.id)

	-- Prevent duplicate starts
	if state.watcher or state.poller or state.watchdog then
		return
	end

	-- Tunables
	local POLL_INTERVAL = (config.options and config.options.poll_interval) or 5000
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

	-- Store root in state for cleanup
	state.root = root

	-- Apply preset
	config.apply_preset_for_root(root)
	local applied_preset = config.options._applied_preset
	if applied_preset then
		notify("[PRESET] Applied '" .. applied_preset .. "' preset for project", vim.log.levels.DEBUG)
	end

	--- Restart watcher with backoff
	---@param reason? string
	---@param delay_ms? number
	---@param disable_fs_event? boolean
	local function restart_watcher(reason, delay_ms, disable_fs_event)
		delay_ms = delay_ms or 300

		if state.restart_scheduled then
			return
		end
		state.restart_scheduled = true

		local now = os.time()
		if now < state.restart_backoff_until then
			notify("Restart suppressed due to backoff for client " .. client.name, vim.log.levels.DEBUG)
			state.restart_scheduled = false
			return
		end

		if disable_fs_event then
			state.fs_event_disabled_until = now + 5
		end

		state.restart_backoff_until = now + math.ceil(delay_ms / 1000)

		vim.defer_fn(function()
			state.restart_scheduled = false

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

			-- Stop old fs_event handle
			if state.watcher then
				safe_close_handle(state.watcher)
				state.watcher = nil
			end

			-- Recreate fs_event handle (if not disabled)
			local use_fs_event = not config.options.force_polling
			if state.fs_event_disabled_until > 0 and os.time() < state.fs_event_disabled_until then
				use_fs_event = false
			end

			if use_fs_event then
				-- Create proxy for snapshots
				local snapshots_proxy = setmetatable({}, {
					__index = function(_, k)
						return client_states[k] and client_states[k].snapshot
					end,
					__newindex = function(_, k, v)
						if client_states[k] then
							client_states[k].snapshot = v
						end
					end,
				})

				local handle, err = fs_event_mod.start(client, root, snapshots_proxy, {
					notify = notify,
					queue_events = queue_events,
					notify_roslyn_renames = notify_roslyn_renames,
					restart_watcher = restart_watcher,
					mark_dirty_dir = mark_dirty_dir,
				})
				if handle then
					state.watcher = handle
				else
					notify("Failed to recreate fs_event: " .. tostring(err), vim.log.levels.DEBUG)
				end
			end
		end, delay_ms)
	end

	-- Create proxy tables for modules that expect the old structure
	local snapshots_proxy = setmetatable({}, {
		__index = function(_, k)
			return client_states[k] and client_states[k].snapshot
		end,
		__newindex = function(_, k, v)
			if client_states[k] then
				client_states[k].snapshot = v
			end
		end,
	})

	local last_events_proxy = setmetatable({}, {
		__index = function(_, k)
			return client_states[k] and client_states[k].last_event
		end,
		__newindex = function(_, k, v)
			if client_states[k] then
				client_states[k].last_event = v
			end
		end,
	})

	---@type roslyn_filewatch.Helpers
	local helpers = {
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		queue_events = queue_events,
		restart_watcher = restart_watcher,
		last_events = last_events_proxy,
	}

	-- Choose whether to use fs_event
	local force_polling = (config.options and config.options.force_polling) or false
	local now = os.time()
	local use_fs_event = not force_polling and now >= state.fs_event_disabled_until

	if use_fs_event then
		local handle, start_err = fs_event_mod.start(client, root, snapshots_proxy, {
			config = config,
			rename_mod = rename_mod,
			snapshot_mod = snapshot_mod,
			notify = notify,
			notify_roslyn_renames = notify_roslyn_renames,
			queue_events = queue_events,
			restart_watcher = restart_watcher,
			mark_dirty_dir = mark_dirty_dir,
			mtime_ns = mtime_ns,
			identity_from_stat = identity_from_stat,
			same_file_info = same_file_info,
			normalize_path = normalize_path,
			last_events = last_events_proxy,
			rename_window_ms = RENAME_WINDOW_MS,
		})

		if not handle then
			notify("Failed to create fs_event: " .. tostring(start_err), vim.log.levels.WARN)
			state.fs_event_disabled_until = os.time() + 5
			use_fs_event = false
		else
			state.watcher = handle
			state.last_event = os.time()
		end
	else
		notify(
			"Using poller-only mode for client " .. client.name .. " (force_polling=" .. tostring(force_polling) .. ")",
			vim.log.levels.DEBUG
		)
		state.last_event = os.time()
	end

	-- Request full scan on startup
	state.needs_full_scan = true

	-- Setup solution/csproj tracking
	if config.options.solution_aware then
		local ok, sln_parser = pcall(require, "roslyn_filewatch.watcher.sln_parser")
		if ok and sln_parser and sln_parser.get_sln_info then
			local sln_info = sln_parser.get_sln_info(root)
			if sln_info then
				state.sln_info = {
					path = sln_info.path,
					mtime = sln_info.mtime,
					csproj_files = nil,
				}

				scan_csproj_async(root, function(initial_csproj)
					if state.sln_info then
						state.sln_info.csproj_files = initial_csproj
					end
				end)
			else
				-- No solution file - check for csproj-only project
				notify("[SLN] No solution file found, checking for csproj-only project", vim.log.levels.DEBUG)

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

					state.sln_info = {
						path = nil,
						mtime = 0,
						csproj_files = csproj_files,
						csproj_only = true,
					}

					local project_paths = collect_roslyn_project_paths(state.sln_info)
					if #project_paths > 0 then
						vim.schedule(function()
							local clients_list = vim.lsp.get_clients()
							for _, c in ipairs(clients_list) do
								if vim.tbl_contains(config.options.client_names, c.name) then
									notify_project_open(c, project_paths, notify)
									request_diagnostics_refresh(c, 2000)
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

	-- Create poller
	local poller, poll_err = fs_poll_mod.start(client, root, snapshots_proxy, {
		scan_tree = scan_tree,
		scan_tree_async = snapshot_mod.scan_tree_async,
		is_scanning = snapshot_mod.is_scanning,
		partial_scan = snapshot_mod.partial_scan,
		get_dirty_dirs = get_and_clear_dirty_dirs,
		should_full_scan = should_full_scan,
		identity_from_stat = identity_from_stat,
		same_file_info = same_file_info,
		queue_events = queue_events,
		notify = notify,
		notify_roslyn_renames = notify_roslyn_renames,
		restart_watcher = restart_watcher,
		last_events = last_events_proxy,
		poll_interval = POLL_INTERVAL,
		poller_restart_threshold = POLLER_RESTART_THRESHOLD,
		activity_quiet_period = ACTIVITY_QUIET_PERIOD,
		-- Solution file change detection: triggers full rescan when .slnx/.sln/.slnf changes
		-- This ensures new project directories (and their source files) are detected
		check_sln_changed = function(client_id, poll_root)
			local poll_state = get_client_state(client_id)
			if not poll_state.sln_info or not poll_state.sln_info.path then
				return false
			end
			local stat = uv.fs_stat(poll_state.sln_info.path)
			if not stat then
				return false
			end
			local current_mtime = stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)
			if current_mtime ~= poll_state.sln_info.mtime then
				notify("[SLN] Solution file mtime changed, will trigger full rescan", vim.log.levels.DEBUG)
				poll_state.sln_info.mtime = current_mtime
				return true
			end
			return false
		end,
		on_sln_changed = function(client_id, poll_root)
			local poll_state = get_client_state(client_id)
			notify("[SLN] Solution file changed, rescanning csproj files", vim.log.levels.DEBUG)
			-- Force full scan on next poll cycle
			poll_state.needs_full_scan = true
			-- Rescan csproj files and send project/open notifications
			scan_csproj_async(poll_root, function(collected_mtimes)
				if not poll_state.sln_info then
					return
				end
				local previous_csproj = poll_state.sln_info.csproj_files or {}
				local new_projects_list = {}
				local current_csproj_set = {}

				for internal_path, current_mtime_sec in pairs(collected_mtimes) do
					current_csproj_set[internal_path] = current_mtime_sec
					local old_mtime_sec = previous_csproj[internal_path]
					if not old_mtime_sec then
						table.insert(new_projects_list, to_roslyn_path(internal_path))
					end
				end

				poll_state.sln_info.csproj_files = current_csproj_set

				if #new_projects_list > 0 then
					vim.schedule(function()
						local clients_list = vim.lsp.get_clients()
						for _, c in ipairs(clients_list) do
							if vim.tbl_contains(config.options.client_names, c.name) then
								notify_project_open(c, new_projects_list, notify)
								notify(
									"[SLN] Detected " .. #new_projects_list .. " new project(s) from solution change",
									vim.log.levels.DEBUG
								)
								request_diagnostics_refresh(c, 2000)
							end
						end
					end)
				end
			end)
		end,
	})

	if not poller then
		notify("Failed to create poller: " .. tostring(poll_err), vim.log.levels.ERROR)
		safe_close_handle(state.watcher)
		state.watcher = nil
		return
	end
	state.poller = poller

	-- Create solution/csproj poll timer
	if config.options.solution_aware and state.sln_info then
		local sln_timer = uv.new_timer()
		if sln_timer then
			local is_csproj_only = state.sln_info.csproj_only == true
			notify(
				"[PROJECT] Started project watcher (mode: " .. (is_csproj_only and "csproj-only" or "solution") .. ")",
				vim.log.levels.DEBUG
			)

			sln_timer:start(POLL_INTERVAL, POLL_INTERVAL, function()
				if client.is_stopped and client.is_stopped() then
					safe_close_handle(sln_timer)
					state.sln_poll_timer = nil
					return
				end

				local cached = state.sln_info
				if not cached then
					return
				end

				-- CSPROJ-ONLY MODE: Poll for new csproj files
				if cached.csproj_only then
					scan_csproj_async(root, function(collected_mtimes)
						if not state.sln_info then
							return
						end

						local previous_csproj = state.sln_info.csproj_files or {}
						local new_projects_list = {}
						local current_csproj_set = {}

						for internal_path, current_mtime_sec in pairs(collected_mtimes) do
							current_csproj_set[internal_path] = current_mtime_sec

							local old_mtime_sec = previous_csproj[internal_path]
							if not old_mtime_sec or old_mtime_sec ~= current_mtime_sec then
								table.insert(new_projects_list, to_roslyn_path(internal_path))

								if old_mtime_sec and old_mtime_sec ~= current_mtime_sec then
									pcall(restore_mod.schedule_restore, internal_path)
								end
							end
						end

						state.sln_info.csproj_files = current_csproj_set

						if #new_projects_list > 0 then
							vim.schedule(function()
								local clients_list = vim.lsp.get_clients()
								for _, c in ipairs(clients_list) do
									if vim.tbl_contains(config.options.client_names, c.name) then
										notify_project_open(c, new_projects_list, notify)
										notify(
											"[CSPROJ] Detected " .. #new_projects_list .. " new/changed csproj file(s)",
											vim.log.levels.DEBUG
										)
										request_diagnostics_refresh(c, 2000)
									end
								end
							end)
						end
					end)
					return
				end

				-- SOLUTION MODE: Check solution file changes
				if not cached.path then
					return
				end

				uv.fs_stat(cached.path, function(err, stat)
					if err or not stat then
						return
					end

					local current_mtime = stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)

					if current_mtime == cached.mtime then
						return
					end

					local old_csproj = cached.csproj_files
					state.sln_info = {
						path = cached.path,
						mtime = current_mtime,
						csproj_files = old_csproj,
					}

					vim.schedule(function()
						if not state.sln_info or not state.sln_info.path then
							return
						end

						local previous_csproj = state.sln_info.csproj_files or {}

						scan_csproj_async(root, function(collected_mtimes)
							local new_projects_list = {}
							local current_csproj_set = {}

							for internal_path, current_mtime_sec in pairs(collected_mtimes) do
								current_csproj_set[internal_path] = current_mtime_sec

								local old_mtime_sec = previous_csproj[internal_path]
								if
									state.sln_info.csproj_files
									and (not old_mtime_sec or old_mtime_sec ~= current_mtime_sec)
								then
									table.insert(new_projects_list, to_roslyn_path(internal_path))

									if old_mtime_sec and old_mtime_sec ~= current_mtime_sec then
										pcall(restore_mod.schedule_restore, internal_path)
									end
								end
							end

							if not state.sln_info.csproj_files then
								state.sln_info.csproj_files = current_csproj_set
								return
							end

							state.sln_info.csproj_files = current_csproj_set

							if #new_projects_list > 0 then
								local clients_list = vim.lsp.get_clients()
								for _, c in ipairs(clients_list) do
									if vim.tbl_contains(config.options.client_names, c.name) then
										notify_project_open(c, new_projects_list, notify)
										request_diagnostics_refresh(c, 2000)
									end
								end
							end
						end)
					end)
				end)
			end)
			state.sln_poll_timer = sln_timer
		else
			vim.schedule(function()
				vim.notify("[roslyn-filewatch] Failed to create project timer", vim.log.levels.ERROR)
			end)
		end
	end

	-- Watchdog
	local watchdog, watchdog_err = watchdog_mod.start(client, root, snapshots_proxy, {
		notify = notify,
		restart_watcher = restart_watcher,
		get_handle = function()
			return state.watcher
		end,
		last_events = last_events_proxy,
		watchdog_idle = WATCHDOG_IDLE,
		use_fs_event = use_fs_event,
	})
	if not watchdog then
		notify("Failed to start watchdog: " .. tostring(watchdog_err), vim.log.levels.ERROR)
		safe_close_handle(state.poller)
		state.poller = nil
		safe_close_handle(state.watcher)
		state.watcher = nil
		return
	end
	state.watchdog = watchdog

	-- Create proxy for sln_mtimes that autocmds expects
	local sln_mtimes_proxy = setmetatable({}, {
		__index = function(_, k)
			return client_states[k] and client_states[k].sln_info
		end,
	})

	-- Autocmds
	local autocmd_ids = autocmds_mod.start(client, root, snapshots_proxy, {
		notify = notify,
		restart_watcher = restart_watcher,
		normalize_path = normalize_path,
		queue_events = queue_events,
		sln_mtimes = sln_mtimes_proxy,
		restore_mod = restore_mod,
	})
	state.autocmd_ids = autocmd_ids

	notify("Watcher started for client " .. client.name .. " at root: " .. root, vim.log.levels.DEBUG)

	-- Project warm-up
	local ok_warmup, warmup_mod = pcall(require, "roslyn_filewatch.project_warmup")
	if ok_warmup and warmup_mod and warmup_mod.warmup then
		warmup_mod.warmup(client)
	end

	-- Game engine context
	local ok_context, context_mod = pcall(require, "roslyn_filewatch.game_context")
	if ok_context and context_mod and context_mod.setup then
		context_mod.setup(client)
	end

	-- LspDetach cleanup - only cleanup when client actually stops
	vim.api.nvim_create_autocmd("LspDetach", {
		callback = function(args)
			if args.data.client_id == client.id then
				-- Check if the client is still running (has other buffers attached)
				-- LspDetach fires per-buffer, so we should only cleanup when client stops
				vim.schedule(function()
					-- Check if client still exists and is active
					local client_still_active = vim.lsp.get_client_by_id(client.id)
					if
						client_still_active
						and not (client_still_active.is_stopped and client_still_active:is_stopped())
					then
						-- Client is still active, just a buffer detach - don't cleanup
						-- Only clear the project open flag to allow re-triggering on next file open
						pcall(function()
							autocmds_mod.clear_client(client.id)
						end)
						notify("LspDetach: Buffer detached, client still active", vim.log.levels.DEBUG)
						return
					end

					-- Client is actually stopping - do full cleanup
					notify("LspDetach: Client stopping, performing cleanup", vim.log.levels.DEBUG)

					-- Clear diagnostics state
					local diag_mod = get_diagnostics_mod()
					if diag_mod and diag_mod.clear_client then
						pcall(diag_mod.clear_client, client.id)
					end

					-- Clear project warmup state
					local ok_w, w_mod = pcall(require, "roslyn_filewatch.project_warmup")
					if ok_w and w_mod and w_mod.clear_client then
						pcall(w_mod.clear_client, client.id)
					end

					-- Cleanup
					cleanup_client(client.id)
					client_states[client.id] = nil
				end)
				return true
			end
		end,
	})
end

--- Reload all tracked projects for all active Roslyn clients
function M.reload_projects()
	local clients = vim.lsp.get_clients()
	local reloaded = 0

	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			local state = get_client_state(client.id)

			if state.sln_info and state.sln_info.csproj_files then
				local project_paths = collect_roslyn_project_paths(state.sln_info)

				if #project_paths > 0 then
					notify_project_open(client, project_paths, notify)
					reloaded = reloaded + 1
					notify("[RELOAD] Sent project/open for " .. #project_paths .. " project(s)", vim.log.levels.DEBUG)

					-- Use throttled diagnostics if available
					local diag_mod = get_diagnostics_mod()
					if diag_mod and diag_mod.request_visible_diagnostics then
						vim.defer_fn(function()
							if client.is_stopped and client.is_stopped() then
								return
							end
							diag_mod.request_visible_diagnostics(client.id)
						end, 2000)
					else
						request_diagnostics_refresh(client, 2000)
					end
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

return M
