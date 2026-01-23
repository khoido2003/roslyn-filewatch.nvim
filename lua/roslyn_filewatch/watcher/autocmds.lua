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

local M = {}

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
	local restart_watcher = deps.restart_watcher
	local normalize_path = deps.normalize_path or utils.normalize_path

	-- BUG FIX: Create a unique autocmd group per client to prevent cross-client triggering
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
		-- Ignore if buftype is set AND buffer has no name
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
	local function handle_file_check(bufpath)
		if not uv.fs_stat(bufpath) then
			-- File vanished - do nothing, fs_event/fs_poll will handle it
			return true
		end
		return false
	end

	--- Check if file is in snapshot - lightweight version that doesn't do full resync
	--- Adds the file to snapshot and queues create event for LSP
	--- Also notifies about .csproj to help Roslyn refresh project model
	---@param bufpath string
	local function ensure_in_snapshot(bufpath)
		local npath = normalize_path(bufpath)
		local client_snap = snapshots[client.id]
		if not client_snap or client_snap[npath] == nil then
			-- File not in snapshot - check if it exists and add it directly
			local st = uv.fs_stat(bufpath)
			if st and st.type == "file" then
				-- Add to snapshot directly
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

				-- For .cs files, also notify about the nearest .csproj to trigger project refresh
				-- Use async scanning to avoid blocking
				if npath:match("%.cs$") or npath:match("%.vb$") or npath:match("%.fs$") then
					-- For csproj-only projects: Ensure project is opened when a new source file is opened
					local config = require("roslyn_filewatch.config")
					if config.options.solution_aware and deps.sln_mtimes then
						local sln_info = deps.sln_mtimes[client.id]
						if sln_info and sln_info.csproj_only and sln_info.csproj_files then
							-- This is a csproj-only project and a new source file is being opened
							vim.schedule(function()
								local clients_list = vim.lsp.get_clients()
								for _, c in ipairs(clients_list) do
									if vim.tbl_contains(config.options.client_names, c.name) and c.id == client.id then
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

												if deps.notify then
													pcall(
														deps.notify,
														"[CSPROJ] Sent project/open when opening new file ("
															.. #project_paths
															.. " csproj file(s))",
														vim.log.levels.DEBUG
													)
												end
											end

											-- CRITICAL FIX: Send project/open IMMEDIATELY when new file is opened
											-- This ensures Roslyn knows about the project before restore
											send_project_open()

											-- Then trigger restore if enabled, and send project/open AGAIN after restore completes
											-- This forces Roslyn to reload the project after restore
											if config.options.enable_autorestore and deps.restore_mod then
												-- Track how many restores we're waiting for
												local restore_count = 0
												local completed_count = 0
												local function on_restore_complete(restored_path)
													completed_count = completed_count + 1
													-- When all restores complete, send project/open AGAIN to force reload
													if completed_count >= restore_count then
														-- Wait a bit more for restore to fully settle, then send project/open again
														vim.defer_fn(function()
															send_project_open()
															-- Also request diagnostics refresh for attached buffers
															vim.defer_fn(function()
																if c.is_stopped and c.is_stopped() then
																	return
																end
																local attached_bufs =
																	vim.lsp.get_buffers_by_client_id(c.id)
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
															end, 1000)
														end, 1000)
													end
												end

												-- Schedule restore for each csproj
												for _, csproj_path in ipairs(project_paths) do
													restore_count = restore_count + 1
													pcall(
														deps.restore_mod.schedule_restore,
														csproj_path,
														on_restore_complete
													)
												end

												-- If no restores were scheduled, we already sent project/open above
											end
										end
										break
									end
								end
							end)
						end
					end

					-- Also notify about the nearest .csproj to trigger project refresh (existing behavior)
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
							return -- Reached root or invalid, stop searching
						end
						find_csproj_in_dir_async(dir, function(csproj_files)
							if #csproj_files > 0 then
								-- Found csproj files, queue events
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
								-- Not found, search parent directory
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

			-- Only process if buffer was attached to this client
			-- Note: On BufDelete, the buffer may already be detached, so also check path
			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath == "" then
				return
			end

			if not is_in_client_root(bufpath) then
				return
			end

			-- Check if file still exists
			if not uv.fs_stat(bufpath) then
			end
		end,
	})
	table.insert(ids, id_main)

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

			-- File exists: ensure it's in snapshot
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

			-- Only process if buffer is attached to THIS client
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

			-- File exists: ensure it's in snapshot
			ensure_in_snapshot(bufpath)
		end,
	})
	table.insert(ids, id_extra)

	return ids
end

return M
