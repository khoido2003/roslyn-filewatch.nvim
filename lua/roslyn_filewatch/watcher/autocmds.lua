---@class roslyn_filewatch.autocmds
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, deps: roslyn_filewatch.AutocmdDeps): number[]

---@class roslyn_filewatch.AutocmdDeps
---@field notify fun(msg: string, level?: number)
---@field resync_snapshot fun()
---@field immediate_resync? fun()
---@field restart_watcher fun(reason?: string, delay_ms?: number, disable_fs_event?: boolean)
---@field normalize_path fun(path: string): string

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
	local resync_snapshot = deps.resync_snapshot
	local immediate_resync = deps.immediate_resync
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

	--- Handle file existence check and resync
	---@param bufpath string
	local function handle_file_check(bufpath)
		if not uv.fs_stat(bufpath) then
			-- File vanished -> resync + restart
			if resync_snapshot then
				pcall(resync_snapshot)
			end
			if restart_watcher then
				pcall(restart_watcher, "file_vanished")
			end
			return true
		end
		return false
	end

	--- Check if file is in snapshot, trigger resync if not
	---@param bufpath string
	local function ensure_in_snapshot(bufpath)
		local npath = normalize_path(bufpath)
		local client_snap = snapshots[client.id]
		if not client_snap or client_snap[npath] == nil then
			-- File not in snapshot, trigger resync
			if immediate_resync then
				pcall(immediate_resync)
			elseif resync_snapshot then
				pcall(resync_snapshot)
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
				if resync_snapshot then
					pcall(resync_snapshot)
				end
				if restart_watcher then
					pcall(restart_watcher, "buffer_deleted_without_file")
				end
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
