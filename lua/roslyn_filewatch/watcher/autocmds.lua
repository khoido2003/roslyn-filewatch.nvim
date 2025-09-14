local uv = vim.uv or vim.loop

local M = {}

-- returns { id_main, id_early, id_extra }
function M.start(client, root, snapshots, deps)
	deps = deps or {}
	local notify = deps.notify
	local resync_snapshot = deps.resync_snapshot
	local restart_watcher = deps.restart_watcher
	local normalize_path = deps.normalize_path

	-- BufDelete / BufWipeout
	local id_main = vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		callback = function(args)
			-- ignore special buftypes
			local bt = vim.bo[args.buf].buftype
			if bt ~= "" then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					if notify then
						pcall(
							notify,
							"Buffer closed for deleted file: " .. bufpath .. " -> resync+restart",
							vim.log.levels.DEBUG
						)
					end
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
			-- ignore special buftypes
			local bt = vim.bo[args.buf].buftype
			if bt ~= "" then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					if notify then
						pcall(
							notify,
							"File vanished while buffer open: " .. bufpath .. " -> resync+restart",
							vim.log.levels.DEBUG
						)
					end
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

	-- BufReadPost, BufWritePost
	local id_extra = vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		callback = function(args)
			-- ignore special buftypes
			local bt = vim.bo[args.buf].buftype
			if bt ~= "" then
				return
			end

			local bufpath = vim.api.nvim_buf_get_name(args.buf)
			if bufpath ~= "" and normalize_path(bufpath):sub(1, #root) == root then
				if not uv.fs_stat(bufpath) then
					if notify then
						pcall(
							notify,
							"File missing but buffer still open: " .. bufpath .. " -> resync+restart",
							vim.log.levels.DEBUG
						)
					end
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

	return { id_main, id_early, id_extra }
end

return M
