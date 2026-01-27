---@class roslyn_filewatch.autocmds
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, deps: roslyn_filewatch.AutocmdDeps): number[]

---@class roslyn_filewatch.AutocmdDeps
---@field notify fun(msg: string, level?: number)
---@field restart_watcher fun(reason?: string, delay_ms?: number, disable_fs_event?: boolean)
---@field normalize_path fun(path: string): string
---@field queue_events fun(client_id: number, evs: roslyn_filewatch.FileChange[])|nil
---@field sln_mtimes? table<number, { path: string|nil, mtime: number, csproj_files: table<string, number>|nil, csproj_only?: boolean }>|nil Solution/project tracking data
---@field restore_mod? roslyn_filewatch.restore|nil Restore module for triggering project restore

local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")

-- Import shared utilities
local to_roslyn_path = utils.to_roslyn_path
local request_diagnostics_refresh = utils.request_diagnostics_refresh
local notify_project_open = utils.notify_project_open

local M = {}

-- Track if initial project open was sent for each client (prevents restore on every file open)
---@type table<number, boolean>
local initial_project_open_sent = {}

--- Start autocmds for the watcher
--- Creates a unique autocmd group per client to prevent cross-client triggering
---@param client vim.lsp.Client LSP client
---@param root string Normalized root path
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Shared snapshots table
---@param deps roslyn_filewatch.AutocmdDeps Dependencies
---@return number[] autocmd_ids Array of autocmd IDs created
function M.start(client, root, snapshots, deps)
	deps = deps or {}
	local notify = deps.notify or function() end
	local normalize_path = deps.normalize_path or utils.normalize_path

	local group_name = "RoslynFilewatch_" .. client.id
	local group = vim.api.nvim_create_augroup(group_name, { clear = true })

	--- Check if buffer should be ignored (special buffers without names)
	---@param buf number Buffer number
	---@return boolean
	local function should_ignore_buf(buf)
		local ok, bt = pcall(function()
			return vim.bo[buf].buftype
		end)
		if not ok then
			return true
		end
		local name = vim.api.nvim_buf_get_name(buf)
		if bt ~= "" and (not name or name == "") then
			return true
		end
		return false
	end

	--- Check if buffer path belongs to this client's root
	---@param bufpath string
	---@return boolean
	local function is_in_client_root(bufpath)
		if not bufpath or bufpath == "" then
			return false
		end
		return utils.path_starts_with(bufpath, root)
	end

	--- Check if buffer is attached to this specific client
	---@param buf number
	---@return boolean
	local function is_buffer_attached_to_client(buf)
		local attached_clients = vim.lsp.get_clients({ bufnr = buf })
		for _, c in ipairs(attached_clients) do
			if c.id == client.id then
				return true
			end
		end
		return false
	end

	--- Handle file existence check
	---@param bufpath string
	---@return boolean true if file vanished
	local function handle_file_check(bufpath)
		if not uv.fs_stat(bufpath) then
			return true
		end
		return false
	end

	--- Collect Roslyn-formatted project paths from sln_info
	---@param sln_info table|nil
	---@return string[]
	local function collect_project_paths(sln_info)
		if not sln_info or not sln_info.csproj_files then
			return {}
		end

		local project_paths = {}
		for csproj_path, _ in pairs(sln_info.csproj_files) do
			table.insert(project_paths, to_roslyn_path(csproj_path))
		end
		return project_paths
	end

	--- Handle csproj-only project open (called once per client, not on every file open)
	---@param sln_info table
	local function handle_csproj_project_open(sln_info)
		-- Only send project/open ONCE per client session
		if initial_project_open_sent[client.id] then
			return
		end

		local project_paths = collect_project_paths(sln_info)
		if #project_paths == 0 then
			return
		end

		initial_project_open_sent[client.id] = true

		-- Send project/open notification
		notify_project_open(client, project_paths, notify)

		-- Trigger restore if enabled (only once, not on every file open)
		local config = require("roslyn_filewatch.config")
		if config.options.enable_autorestore and deps.restore_mod then
			-- Only restore the first csproj
			local first_path = project_paths[1]
			if first_path then
				pcall(deps.restore_mod.schedule_restore, first_path, function(_)
					-- After restore completes, send project/open again and refresh diagnostics
					vim.defer_fn(function()
						if client.is_stopped and client.is_stopped() then
							return
						end
						notify_project_open(client, project_paths, notify)
						request_diagnostics_refresh(client, 500)
					end, 500)
				end)
			end
		end
	end

	--- Check if file is in snapshot and handle project open for csproj-only projects
	---@param bufpath string
	local function ensure_in_snapshot(bufpath)
		local npath = normalize_path(bufpath)
		local client_snap = snapshots[client.id]

		if not client_snap or client_snap[npath] == nil then
			-- File not in snapshot - check if it exists and add it
			local st = uv.fs_stat(bufpath)
			if st and st.type == "file" then
				if not snapshots[client.id] then
					snapshots[client.id] = {}
				end
				snapshots[client.id][npath] = {
					mtime = st.mtime and (st.mtime.sec * 1e9 + (st.mtime.nsec or 0)) or 0,
					size = st.size,
					ino = st.ino,
					dev = st.dev,
				}

				-- Queue create event for LSP
				local events = { { uri = vim.uri_from_fname(npath), type = 1 } }

				-- For source files in csproj-only projects, handle project open (once)
				if npath:match("%.cs$") or npath:match("%.vb$") or npath:match("%.fs$") then
					local config = require("roslyn_filewatch.config")
					if config.options.solution_aware and deps.sln_mtimes then
						local sln_info = deps.sln_mtimes[client.id]
						if sln_info and sln_info.csproj_only and sln_info.csproj_files then
							-- Handle project open (only once per client)
							handle_csproj_project_open(sln_info)

							-- ALWAYS trigger restore for new source files in csproj-only projects
							-- This ensures restore happens even if project/open was already sent
							if config.options.enable_autorestore and deps.restore_mod then
								for csproj_path, _ in pairs(sln_info.csproj_files) do
									-- Use schedule to avoid blocking
									vim.schedule(function()
										pcall(deps.restore_mod.schedule_restore, csproj_path, 2000)
									end)
									break -- Only restore one csproj
								end
							end

							-- Also send project/open directly for the new file
							-- This ensures LSP is aware of the new file even after all buffers were deleted
							local project_paths = collect_project_paths(sln_info)
							if #project_paths > 0 then
								vim.schedule(function()
									notify_project_open(client, project_paths, notify)
									notify(
										"[AUTOCMD] New source file detected, sent project/open for "
											.. #project_paths
											.. " project(s)",
										vim.log.levels.DEBUG
									)
									request_diagnostics_refresh(client, 1000)
								end)
							end
						end
					end

					-- Also notify about the nearest .csproj
					local function find_csproj_in_dir_async(dir, callback)
						uv.fs_scandir(dir, function(err, scanner)
							if err or not scanner then
								callback({})
								return
							end
							local found = {}
							while true do
								local name, typ = uv.fs_scandir_next(scanner)
								if not name then
									break
								end
								if typ == "file" and name:match("%.csproj$") then
									table.insert(found, normalize_path(dir .. "/" .. name))
								end
							end
							callback(found)
						end)
					end

					local function search_up_for_csproj(dir)
						if not dir or dir == "" or not utils.path_starts_with(dir, root) then
							return
						end
						find_csproj_in_dir_async(dir, function(csproj_files)
							if #csproj_files > 0 then
								local csproj_events = {}
								for _, csproj in ipairs(csproj_files) do
									table.insert(csproj_events, { uri = vim.uri_from_fname(csproj), type = 2 })
								end
								if deps.queue_events then
									vim.schedule(function()
										pcall(deps.queue_events, client.id, csproj_events)
									end)
								end
							else
								local parent = dir:match("^(.+)/[^/]+$")
								search_up_for_csproj(parent)
							end
						end)
					end

					local dir = npath:match("^(.+)/[^/]+$")
					search_up_for_csproj(dir)
				end

				if deps.queue_events then
					vim.schedule(function()
						pcall(deps.queue_events, client.id, events)
					end)
				end
			end
		end
	end

	---@type number[]
	local ids = {}

	-- BufDelete / BufWipeout
	local id_main = vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		callback = function(args)
			if should_ignore_buf(args.buf) then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath == "" then
				return
			end

			if not is_in_client_root(bufpath) then
				return
			end

			-- Check if file still exists (handled by fs_event/fs_poll)
			if not uv.fs_stat(bufpath) then
				-- File vanished - nothing to do here
			end
		end,
	})
	table.insert(ids, id_main)

	-- BufUnload: Detect when all buffers attached to this client are deleted
	-- This resets the project open flag so new files trigger project/open notification
	local id_unload = vim.api.nvim_create_autocmd({ "BufUnload" }, {
		group = group,
		callback = function(args)
			if should_ignore_buf(args.buf) then
				return
			end

			-- Skip if this buffer isn't attached to our client
			if not is_buffer_attached_to_client(args.buf) then
				return
			end

			-- Check if there are any other buffers still attached to this client
			-- We need to defer this check because BufUnload fires before the buffer is actually removed
			vim.schedule(function()
				local remaining_bufs = vim.lsp.get_buffers_by_client_id(client.id)
				-- Filter out the current buffer being unloaded
				local other_bufs = vim.tbl_filter(function(buf)
					return buf ~= args.buf and vim.api.nvim_buf_is_valid(buf)
				end, remaining_bufs or {})

				if #other_bufs == 0 then
					-- All buffers deleted - reset the project open flag
					-- so next file open will trigger project/open notification
					initial_project_open_sent[client.id] = nil
					notify(
						"[AUTOCMD] All buffers deleted, reset project open state for client " .. client.id,
						vim.log.levels.DEBUG
					)
				end
			end)
		end,
	})
	table.insert(ids, id_unload)

	-- BufEnter, BufWritePost, FileChangedRO
	local id_early = vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FileChangedRO" }, {
		group = group,
		callback = function(args)
			if should_ignore_buf(args.buf) then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if not is_in_client_root(bufpath) then
				return
			end

			if handle_file_check(bufpath) then
				return
			end

			ensure_in_snapshot(bufpath)
		end,
	})
	table.insert(ids, id_early)

	-- BufReadPost, BufWritePost
	local id_extra = vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		group = group,
		callback = function(args)
			if should_ignore_buf(args.buf) then
				return
			end

			if not is_buffer_attached_to_client(args.buf) then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if not is_in_client_root(bufpath) then
				return
			end

			if handle_file_check(bufpath) then
				return
			end

			ensure_in_snapshot(bufpath)
		end,
	})
	table.insert(ids, id_extra)

	return ids
end

--- Clear tracking state for a client (called on LspDetach)
---@param client_id number
function M.clear_client(client_id)
	initial_project_open_sent[client_id] = nil
end

return M
