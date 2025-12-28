---@class roslyn_filewatch.sln_parser
---@field find_sln fun(root: string): string|nil
---@field get_project_dirs fun(sln_path: string): string[]

---Solution file (.sln) parser for solution-aware watching.
---Extracts project directories from .sln files to limit watch scope.

local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

--- Find .sln file in the given root directory
---@param root string Root directory path
---@return string|nil sln_path Path to .sln file, or nil if not found
function M.find_sln(root)
	if not root or root == "" then
		return nil
	end

	root = utils.normalize_path(root)

	-- Use vim.fs.find for efficient file search
	local sln_files = vim.fs.find(function(name, _)
		return name:match("%.sln$")
	end, {
		path = root,
		limit = 1,
		type = "file",
	})

	if sln_files and #sln_files > 0 then
		return utils.normalize_path(sln_files[1])
	end

	return nil
end

--- Parse .sln file content and extract project paths
---@param content string Content of the .sln file
---@param sln_dir string Directory containing the .sln file
---@return string[] project_dirs List of absolute project directory paths
local function parse_sln_content(content, sln_dir)
	local project_dirs = {}
	local seen = {}

	-- Match Project lines: Project("{GUID}") = "Name", "path\to\project.csproj", "{GUID}"
	-- The pattern captures the relative path to the project file
	for project_path in content:gmatch('Project%("[^"]*"%)%s*=%s*"[^"]*",%s*"([^"]+)"') do
		-- Skip solution folders (they don't have file extensions)
		if project_path:match("%.[^.]+$") then
			-- Normalize path separators
			local normalized = project_path:gsub("\\", "/")

			-- Get the directory containing the project file
			local project_dir = normalized:match("^(.+)/[^/]+$")
			if project_dir then
				-- Make absolute path
				local abs_dir = utils.normalize_path(sln_dir .. "/" .. project_dir)

				-- Avoid duplicates
				if not seen[abs_dir] then
					seen[abs_dir] = true
					table.insert(project_dirs, abs_dir)
				end
			else
				-- Project file is in sln directory
				if not seen[sln_dir] then
					seen[sln_dir] = true
					table.insert(project_dirs, sln_dir)
				end
			end
		end
	end

	return project_dirs
end

--- Get project directories from a .sln file
---@param sln_path string Path to the .sln file
---@return string[] project_dirs List of absolute project directory paths
function M.get_project_dirs(sln_path)
	if not sln_path or sln_path == "" then
		return {}
	end

	sln_path = utils.normalize_path(sln_path)

	-- Read the .sln file
	local ok, content = pcall(function()
		local fd = uv.fs_open(sln_path, "r", 438)
		if not fd then
			return nil
		end

		local stat = uv.fs_fstat(fd)
		if not stat then
			uv.fs_close(fd)
			return nil
		end

		local data = uv.fs_read(fd, stat.size, 0)
		uv.fs_close(fd)
		return data
	end)

	if not ok or not content then
		return {}
	end

	-- Get the directory containing the .sln file
	local sln_dir = sln_path:match("^(.+)/[^/]+$") or sln_path:match("^(.+)$")
	if not sln_dir then
		return {}
	end

	return parse_sln_content(content, sln_dir)
end

--- Get project directories for a root, with caching
--- Returns nil if solution-aware watching should be skipped (fallback to full scan)
---@param root string Root directory path
---@return string[]|nil project_dirs List of project directories, or nil to use full scan
function M.get_watch_dirs(root)
	if not root or root == "" then
		return nil
	end

	local sln_path = M.find_sln(root)
	if not sln_path then
		return nil -- No .sln found, use full scan
	end

	local dirs = M.get_project_dirs(sln_path)
	if #dirs == 0 then
		return nil -- No projects found, use full scan
	end

	-- Always include the sln directory itself (for .sln/.props/.targets changes)
	local sln_dir = sln_path:match("^(.+)/[^/]+$")
	if sln_dir then
		local seen = {}
		for _, d in ipairs(dirs) do
			seen[d] = true
		end
		if not seen[sln_dir] then
			table.insert(dirs, sln_dir)
		end
	end

	return dirs
end

return M
