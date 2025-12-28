---@class roslyn_filewatch.gitignore
---@field load fun(root: string): roslyn_filewatch.GitignoreMatcher|nil
---@field is_ignored fun(matcher: roslyn_filewatch.GitignoreMatcher, path: string): boolean

---Lightweight .gitignore parser for respecting git ignore patterns.

local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

---@class roslyn_filewatch.GitignoreMatcher
---@field patterns roslyn_filewatch.GitignorePattern[]
---@field root string

---@class roslyn_filewatch.GitignorePattern
---@field pattern string
---@field negated boolean
---@field dir_only boolean
---@field anchored boolean

--- Convert gitignore pattern to Lua pattern
---@param pattern string
---@return string lua_pattern
local function gitignore_to_lua_pattern(pattern)
	-- Escape special Lua pattern characters except * and ?
	local escaped = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")

	-- Convert gitignore wildcards to Lua patterns
	-- ** matches any path (including /)
	escaped = escaped:gsub("%*%*", "\1") -- placeholder
	-- * matches anything except /
	escaped = escaped:gsub("%*", "[^/]*")
	-- ? matches single char except /
	escaped = escaped:gsub("%?", "[^/]")
	-- Restore ** as .*
	escaped = escaped:gsub("\1", ".*")

	return escaped
end

--- Parse a single gitignore line
---@param line string
---@return roslyn_filewatch.GitignorePattern|nil
local function parse_line(line)
	-- Skip empty lines and comments
	if line == "" or line:match("^%s*#") or line:match("^%s*$") then
		return nil
	end

	-- Remove trailing spaces (unless escaped)
	line = line:gsub("([^\\])%s+$", "%1"):gsub("^%s+", "")
	if line == "" then
		return nil
	end

	local pattern = {
		pattern = line,
		negated = false,
		dir_only = false,
		anchored = false,
	}

	-- Check for negation
	if line:sub(1, 1) == "!" then
		pattern.negated = true
		line = line:sub(2)
	end

	-- Check for trailing slash (directory only)
	if line:sub(-1) == "/" then
		pattern.dir_only = true
		line = line:sub(1, -2)
	end

	-- Check if anchored (contains / not at end)
	if line:find("/") then
		pattern.anchored = true
		-- Remove leading slash if present
		if line:sub(1, 1) == "/" then
			line = line:sub(2)
		end
	end

	-- Convert to Lua pattern
	pattern.pattern = gitignore_to_lua_pattern(line)

	return pattern
end

--- Load .gitignore from a directory
---@param root string Root directory path
---@return roslyn_filewatch.GitignoreMatcher|nil
function M.load(root)
	if not root or root == "" then
		return nil
	end

	root = utils.normalize_path(root)
	local gitignore_path = root .. "/.gitignore"

	-- Check if .gitignore exists
	local stat = uv.fs_stat(gitignore_path)
	if not stat then
		return nil
	end

	-- Read the file
	local ok, content = pcall(function()
		local fd = uv.fs_open(gitignore_path, "r", 438)
		if not fd then
			return nil
		end
		local data = uv.fs_read(fd, stat.size, 0)
		uv.fs_close(fd)
		return data
	end)

	if not ok or not content then
		return nil
	end

	-- Parse patterns
	local patterns = {}
	for line in content:gmatch("[^\r\n]+") do
		local parsed = parse_line(line)
		if parsed then
			table.insert(patterns, parsed)
		end
	end

	if #patterns == 0 then
		return nil
	end

	return {
		patterns = patterns,
		root = root,
	}
end

--- Check if a path is ignored by the matcher
---@param matcher roslyn_filewatch.GitignoreMatcher
---@param path string Absolute path to check
---@param is_dir boolean|nil Whether path is a directory
---@return boolean
function M.is_ignored(matcher, path, is_dir)
	if not matcher or not path then
		return false
	end

	-- Get relative path from root
	local root = matcher.root
	local normalized = utils.normalize_path(path)

	-- Make path relative to root
	local rel_path = normalized
	if normalized:sub(1, #root) == root then
		rel_path = normalized:sub(#root + 2) -- +2 to skip the /
	end

	if rel_path == "" then
		return false
	end

	-- Check each pattern in order (last match wins)
	local ignored = false
	for _, pat in ipairs(matcher.patterns) do
		local matches = false

		-- Skip dir-only patterns for files
		if pat.dir_only and not is_dir then
			goto continue
		end

		if pat.anchored then
			-- Anchored: match from root
			if rel_path:match("^" .. pat.pattern .. "$") or rel_path:match("^" .. pat.pattern .. "/") then
				matches = true
			end
		else
			-- Not anchored: match any path segment
			-- Match at start, after /, or the whole thing
			if
				rel_path:match("^" .. pat.pattern .. "$")
				or rel_path:match("^" .. pat.pattern .. "/")
				or rel_path:match("/" .. pat.pattern .. "$")
				or rel_path:match("/" .. pat.pattern .. "/")
			then
				matches = true
			end
		end

		if matches then
			ignored = not pat.negated
		end

		::continue::
	end

	return ignored
end

return M
