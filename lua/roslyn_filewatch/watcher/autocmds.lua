local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")
local normalize_path_default = utils.normalize_path

local M = {}

-- @param client LSP client
-- @param root normalized root path
-- @param snapshots shared snapshots table (indexed by client.id)
-- @param deps table of dependencies:
function M.start(client, root, snapshots, deps)
	deps = deps or {}
	local notify = deps.notify or function() end
	local resync_snapshot = deps.resync_snapshot
	local immediate_resync = deps.immediate_resync
	local restart_watcher = deps.restart_watcher
	local normalize_path = deps.normalize_path or normalize_path_default

	-- Ignore special buffers (no name + non-empty buftype).
	-- If buffer *has* a name (file path) we do *not* ignore it even if buftype is set.
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

	-- BufDelete / BufWipeout
	local id_main = vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		callback = function(args)
			if should_ignore_buf(args.buf) then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					if resync_snapshot then
						pcall(resync_snapshot)
					end
					if restart_watcher then
						pcall(restart_watcher)
					end
				end
			end
		end,
	})

	-- BufEnter, BufWritePost, FileChangedRO
	local id_early = vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FileChangedRO" }, {
		callback = function(args)
			if should_ignore_buf(args.buf) then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				-- If file vanished -> resync + restart (old behaviour)
				if not uv.fs_stat(bufpath) then
					if resync_snapshot then
						pcall(resync_snapshot)
					end
					if restart_watcher then
						pcall(restart_watcher)
					end
					return
				end

				-- File exists: ensure snapshot contains it. If it does not, trigger a resync.
				local npath = normalize_path(bufpath)
				local client_snap = snapshots[client.id]
				if not client_snap or client_snap[npath] == nil then
					-- Prefer immediate_resync when available (faster, non-debounced)
					if immediate_resync then
						pcall(immediate_resync)
					elseif resync_snapshot then
						pcall(resync_snapshot)
					end
				end
			end
		end,
	})

	-- BufReadPost, BufWritePost
	local id_extra = vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		callback = function(args)
			if should_ignore_buf(args.buf) then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					if resync_snapshot then
						pcall(resync_snapshot)
					end
					if restart_watcher then
						pcall(restart_watcher)
					end
					return
				end

				local npath = normalize_path(bufpath)
				local client_snap = snapshots[client.id]
				if not client_snap or client_snap[npath] == nil then
					if immediate_resync then
						pcall(immediate_resync)
					elseif resync_snapshot then
						pcall(resync_snapshot)
					end
				end
			end
		end,
	})

	return { id_main, id_early, id_extra }
end

return M
