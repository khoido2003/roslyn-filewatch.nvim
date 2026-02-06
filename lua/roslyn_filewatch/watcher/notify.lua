---@class roslyn_filewatch.notify
---@field user fun(msg: string, level?: number)
---@field roslyn_changes fun(changes: roslyn_filewatch.FileChange[])
---@field roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])

---@class roslyn_filewatch.FileChange
---@field uri string File URI
---@field type number 1=Created, 2=Changed, 3=Deleted

---@class roslyn_filewatch.RenameEntry
---@field old string Old path
---@field new string New path
---@field oldUri? string Optional pre-computed old URI
---@field newUri? string Optional pre-computed new URI

local M = {}

local config = require("roslyn_filewatch.config")

--- Get the configured log level
---@return number
local function configured_log_level()
	local ok, lvl = pcall(function()
		return config and config.options and config.options.log_level
	end)
	if not ok or lvl == nil then
		-- fallback to WARN if something unexpected happens
		if vim.log and vim.log.levels and vim.log.levels.WARN then
			return vim.log.levels.WARN
		end
		return 3
	end
	return lvl
end

--- Check whether a message at 'level' should be shown given configured threshold
---@param level? number
---@return boolean
local function should_emit(level)
	level = level or (vim.log and vim.log.levels and vim.log.levels.INFO) or 2
	local cfg_level = configured_log_level()
	-- vim.log.levels are numeric where smaller = more verbose (TRACE=0,...,ERROR=4)
	-- show messages whose level is >= cfg_level.
	return level >= cfg_level
end

--- Send a notification to the user
---@param msg string
---@param level? number vim.log.levels value
function M.user(msg, level)
	level = level or (vim.log and vim.log.levels and vim.log.levels.INFO) or 2
	if not should_emit(level) then
		return
	end
	vim.schedule(function()
		local notify_fn = vim.notify or print
		pcall(function()
			notify_fn("[roslyn-filewatch] " .. tostring(msg), level)
		end)
	end)
end

--- Helper to find nearby csproj files and trigger updates
---@param source_files string[]
---@param additional_changes table
---@return table seen_csproj
local function find_csproj_changes(source_files, additional_changes)
	local uv = vim.uv or vim.loop
	local seen_csproj = {}
	-- Cache directory scan results to avoid redundant fs calls for files in same dir
	-- Key: directory path, Value: list of csproj paths found (or empty table)
	local dir_cache = {}

	for _, source_file in ipairs(source_files) do
		-- Search up to 3 directories up for .csproj files
		local dir = source_file:match("^(.+)[/\\][^/\\]+$")
		local search_depth = 0

		while dir and search_depth < 3 do
			-- Check cache first
			local cached = dir_cache[dir]
			if cached then
				for _, csproj_path in ipairs(cached) do
					if not seen_csproj[csproj_path] then
						seen_csproj[csproj_path] = true
						table.insert(additional_changes, {
							uri = vim.uri_from_fname(csproj_path),
							type = 2, -- Changed
						})
					end
				end
			else
				-- Not in cache, scan directory
				local found_in_dir = {}
				local handle = uv.fs_scandir(dir)
				if handle then
					while true do
						local name, typ = uv.fs_scandir_next(handle)
						if not name then
							break
						end
						if typ == "file" and name:match("%.csproj$") then
							local csproj_path = dir .. "/" .. name
							-- Normalize path separators
							csproj_path = csproj_path:gsub("\\", "/")
							table.insert(found_in_dir, csproj_path)

							if not seen_csproj[csproj_path] then
								seen_csproj[csproj_path] = true
								table.insert(additional_changes, {
									uri = vim.uri_from_fname(csproj_path),
									type = 2, -- Changed
								})
							end
						end
					end
				end
				dir_cache[dir] = found_in_dir
			end

			-- Move to parent directory
			dir = dir:match("^(.+)[/\\][^/\\]+$")
			search_depth = search_depth + 1
		end
	end
	return seen_csproj
end

--- Send workspace/didChangeWatchedFiles to all matching Roslyn clients
--- If new source files are created OR deleted, also send csproj change events to trigger project reload
---@param changes roslyn_filewatch.FileChange[]
function M.roslyn_changes(changes)
	if not changes or #changes == 0 then
		return
	end

	-- Check if any source files were created or deleted
	local modified_source_files = {}
	for _, change in ipairs(changes) do
		-- Check for Created (1) or Deleted (3) events
		if change.type == 1 or change.type == 3 then
			local path = vim.uri_to_fname(change.uri)
			if path:match("%.cs$") or path:match("%.vb$") or path:match("%.fs$") then
				table.insert(modified_source_files, path)
			end
		end
	end

	-- If source files were modified, find nearby csproj files and add change events
	local additional_changes = {}
	local seen_csproj = find_csproj_changes(modified_source_files, additional_changes)

	-- Merge additional changes with original changes
	local all_changes = vim.list_extend({}, changes)
	vim.list_extend(all_changes, additional_changes)

	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			pcall(function()
				client.notify("workspace/didChangeWatchedFiles", { changes = all_changes })
			end)

			-- If source files were modified, also trigger project/open after a delay
			if #modified_source_files > 0 and #additional_changes > 0 then
				vim.defer_fn(function()
					-- Send project/open for each csproj
					local utils = require("roslyn_filewatch.watcher.utils")
					for csproj_path, _ in pairs(seen_csproj or {}) do
						local roslyn_path = utils.to_roslyn_path(csproj_path)
						pcall(function()
							client.notify("project/open", { projects = { roslyn_path } })
						end)
					end
				end, 500)
			end
		end
	end
end

--- Send workspace/didRenameFiles to all matching Roslyn clients
---@param files roslyn_filewatch.RenameEntry[]
function M.roslyn_renames(files)
	if not files or #files == 0 then
		return
	end

	-- Collect source files that were renamed
	local modified_source_files = {}
	for _, p in ipairs(files) do
		local old_path = p.old
		local new_path = p["new"]

		if old_path:match("%.cs$") or old_path:match("%.vb$") or old_path:match("%.fs$") then
			table.insert(modified_source_files, old_path)
		end
		if new_path:match("%.cs$") or new_path:match("%.vb$") or new_path:match("%.fs$") then
			table.insert(modified_source_files, new_path)
		end
	end

	-- Find relevant csproj files to update
	local additional_changes = {}
	local seen_csproj = find_csproj_changes(modified_source_files, additional_changes)

	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			---@type { files: { oldUri: string, newUri: string }[] }
			local payload = { files = {} }
			for _, p in ipairs(files) do
				table.insert(payload.files, {
					oldUri = p.oldUri or vim.uri_from_fname(p.old),
					newUri = p.newUri or vim.uri_from_fname(p["new"]),
				})
			end
			vim.schedule(function()
				pcall(function()
					client.notify("workspace/didRenameFiles", payload)

					-- Also send csproj change events if we found any
					if #additional_changes > 0 then
						client.notify("workspace/didChangeWatchedFiles", { changes = additional_changes })
					end
				end)

				-- Trigger project/open after delay
				if #modified_source_files > 0 and #additional_changes > 0 then
					vim.defer_fn(function()
						local utils = require("roslyn_filewatch.watcher.utils")
						for csproj_path, _ in pairs(seen_csproj or {}) do
							local roslyn_path = utils.to_roslyn_path(csproj_path)
							pcall(function()
								client.notify("project/open", { projects = { roslyn_path } })
							end)
						end
					end, 500)
				end
			end)
		end
	end
end

return M
