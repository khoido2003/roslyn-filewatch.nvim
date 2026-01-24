---@class roslyn_filewatch.utils
---@field mtime_ns fun(stat: uv.fs_stat.result|roslyn_filewatch.SnapshotEntry|nil): number
---@field identity_from_stat fun(st: uv.fs_stat.result|roslyn_filewatch.SnapshotEntry|nil): string|nil
---@field same_file_info fun(a: roslyn_filewatch.SnapshotEntry|nil, b: roslyn_filewatch.SnapshotEntry|nil): boolean
---@field normalize_path fun(p: string|nil): string
---@field paths_equal fun(a: string|nil, b: string|nil): boolean
---@field should_watch_path fun(path: string, ignore_dirs: string[], watch_extensions: string[]): boolean
---@field is_windows fun(): boolean
---@field get_extension fun(path: string): string|nil

---@class roslyn_filewatch.SnapshotEntry
---@field mtime number Modification time in nanoseconds
---@field size number File size in bytes
---@field ino number|nil Inode number (may be nil on Windows)
---@field dev number|nil Device ID (may be nil on Windows)

local uv = vim.uv or vim.loop

local M = {}

-- Cache the platform detection result
---@type boolean|nil
local _is_windows_cache = nil

--- Detect if running on Windows
---@return boolean
function M.is_windows()
	if _is_windows_cache ~= nil then
		return _is_windows_cache
	end

	local ok, uname = pcall(function()
		return uv.os_uname()
	end)
	if ok and uname and uname.sysname then
		_is_windows_cache = uname.sysname:match("Windows") ~= nil
	else
		-- Fallback: check path separator
		_is_windows_cache = package.config:sub(1, 1) == "\\"
	end

	return _is_windows_cache
end

--- Compute mtime in nanoseconds
--- Accepts a uv.fs_stat() like table with .mtime = { sec, nsec }
--- or a snapshot entry where .mtime is already a number (ns)
---@param stat uv.fs_stat.result|roslyn_filewatch.SnapshotEntry|nil
---@return number
function M.mtime_ns(stat)
	if not stat then
		return 0
	end

	local mt = stat.mtime
	if type(mt) == "table" then
		-- libuv style { sec = ..., nsec = ... }
		return (mt.sec or 0) * 1e9 + (mt.nsec or 0)
	elseif type(mt) == "number" then
		-- already in ns (snapshot entry)
		return mt
	end

	return 0
end

--- Get file identity from stat
--- Prefer dev:ino (when available), fallback to mtime:size
---@param st uv.fs_stat.result|roslyn_filewatch.SnapshotEntry|nil
---@return string|nil
function M.identity_from_stat(st)
	if not st then
		return nil
	end

	-- prefer device:inode if present (most robust)
	if st.dev and st.ino then
		return tostring(st.dev) .. ":" .. tostring(st.ino)
	end

	-- if snapshot-style entry with numeric mtime and size
	if st.mtime and type(st.mtime) == "number" and st.size then
		return tostring(st.mtime) .. ":" .. tostring(st.size)
	end

	-- if stat has mtime table (libuv) + size
	if st.mtime and type(st.mtime) == "table" and st.size then
		local m = M.mtime_ns(st)
		if m and st.size then
			return tostring(m) .. ":" .. tostring(st.size)
		end
	end

	return nil
end

--- Compare snapshot/file info (mtime in ns + size)
---@param a roslyn_filewatch.SnapshotEntry|nil
---@param b roslyn_filewatch.SnapshotEntry|nil
---@return boolean
function M.same_file_info(a, b)
	if not a or not b then
		return false
	end
	-- both a.mtime and b.mtime should be numeric (ns)
	return a.mtime == b.mtime and a.size == b.size
end

--- Normalize path: unify separators, remove trailing slashes, lowercase drive on windows
---@param p string|nil
---@return string
function M.normalize_path(p)
	if not p or p == "" then
		return p or ""
	end
	-- unify separators to forward slash
	p = p:gsub("\\", "/")
	-- remove trailing slashes (but preserve root like "C:/")
	p = p:gsub("/+$", "")
	-- lowercase drive letter on Windows-style "C:/..."
	local drive = p:match("^([A-Za-z]):/")
	if drive then
		p = drive:lower() .. p:sub(2)
	end
	return p
end

--- Compare two paths for equality (case-insensitive on Windows)
---@param a string|nil
---@param b string|nil
---@return boolean
function M.paths_equal(a, b)
	if not a or not b then
		return a == b
	end

	local norm_a = M.normalize_path(a)
	local norm_b = M.normalize_path(b)

	if M.is_windows() then
		-- Case-insensitive comparison on Windows
		return norm_a:lower() == norm_b:lower()
	else
		return norm_a == norm_b
	end
end

--- Check if path starts with a given prefix (case-insensitive on Windows)
---@param path string
---@param prefix string
---@return boolean
function M.path_starts_with(path, prefix)
	if not path or not prefix then
		return false
	end

	local norm_path = M.normalize_path(path)
	local norm_prefix = M.normalize_path(prefix)

	if M.is_windows() then
		return norm_path:lower():sub(1, #norm_prefix) == norm_prefix:lower()
	else
		return norm_path:sub(1, #norm_prefix) == norm_prefix
	end
end

--- Extract file extension from path
---@param path string
---@return string|nil Extension including the dot (e.g., ".cs")
function M.get_extension(path)
	if not path or path == "" then
		return nil
	end
	-- Match extension after the last path separator
	local filename = path:match("[/\\]?([^/\\]+)$") or path
	local ext = filename:match("(%.[^.]+)$")
	return ext
end

--- Check if a path segment matches an ignore directory name exactly
--- This prevents false positives like "MyLibrary" matching "Library"
--- Case-insensitive matching on Windows for cross-platform compatibility
---@param path string Normalized path with forward slashes
---@param ignore_dir string Directory name to check
---@return boolean
local function matches_ignore_dir(path, ignore_dir)
	-- Case-insensitive matching on Windows
	local is_win = M.is_windows()
	local cmp_path = is_win and path:lower() or path
	local cmp_dir = is_win and ignore_dir:lower() or ignore_dir

	-- Pattern: /dir/ or /dir at end
	-- Use pattern anchoring to match exact segment
	local pattern_mid = "/" .. cmp_dir .. "/"
	local pattern_end = "/" .. cmp_dir .. "$"

	if cmp_path:find(pattern_mid, 1, true) then
		return true
	end
	if cmp_path:match(pattern_end) then
		return true
	end

	-- Also check if path starts with the ignore dir (e.g., root level)
	local pattern_start = "^" .. cmp_dir .. "/"
	if cmp_path:match(pattern_start) then
		return true
	end

	return false
end

--- Convert a gitignore/glob pattern to a Lua pattern
--- Supports: ** (any path), * (any except /), ? (single char)
---@param pattern string Glob pattern
---@return string lua_pattern
local function glob_to_lua_pattern(pattern)
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

--- Check if a path matches a glob pattern (gitignore-style)
---@param path string Normalized path to check
---@param pattern string Glob pattern to match against
---@return boolean
local function matches_glob_pattern(path, pattern)
	if not path or path == "" or not pattern or pattern == "" then
		return false
	end

	-- Handle negation (! prefix)
	local is_negated = false
	if pattern:sub(1, 1) == "!" then
		is_negated = true
		pattern = pattern:sub(2)
	end

	-- Normalize pattern: convert backslashes to forward slashes
	pattern = pattern:gsub("\\", "/")

	-- Case-insensitive matching on Windows
	local is_win = M.is_windows()
	local cmp_path = is_win and path:lower() or path
	local cmp_pattern = is_win and pattern:lower() or pattern

	-- Convert glob to Lua pattern
	local lua_pattern = glob_to_lua_pattern(cmp_pattern)

	-- If pattern starts with **, it can match anywhere
	-- If pattern doesn't contain /, it can match any basename
	local matches = false

	if cmp_pattern:sub(1, 2) == "**" then
		-- ** at start: match anywhere in path
		if cmp_path:match(lua_pattern) then
			matches = true
		end
	elseif not cmp_pattern:find("/") then
		-- No slash: match against basename only
		local basename = cmp_path:match("[^/]+$") or cmp_path
		if basename:match("^" .. lua_pattern .. "$") then
			matches = true
		end
	else
		-- Has slash: match against full path
		-- Try matching from the start
		if cmp_path:match("^" .. lua_pattern .. "$") or cmp_path:match("^" .. lua_pattern .. "/") then
			matches = true
		end
		-- Also try matching from any path position (like **/pattern)
		if not matches and cmp_path:match("/" .. lua_pattern .. "$") then
			matches = true
		end
		if not matches and cmp_path:match("/" .. lua_pattern .. "/") then
			matches = true
		end
	end

	-- Apply negation
	if is_negated then
		return not matches
	end
	return matches
end

--- Check if a path matches any of the given glob patterns
---@param path string Normalized path to check
---@param patterns string[] List of glob patterns
---@return boolean is_excluded Whether path is excluded by patterns
function M.matches_any_pattern(path, patterns)
	if not patterns or #patterns == 0 then
		return false
	end

	local excluded = false
	for _, pattern in ipairs(patterns) do
		if pattern and pattern ~= "" then
			local is_negated = pattern:sub(1, 1) == "!"
			if is_negated then
				-- Negation pattern: if matches, INCLUDE the file
				if matches_glob_pattern(path, pattern:sub(2)) then
					excluded = false
				end
			else
				-- Normal pattern: if matches, EXCLUDE the file
				if matches_glob_pattern(path, pattern) then
					excluded = true
				end
			end
		end
	end

	return excluded
end

--- Determine if a path should be watched based on ignore_dirs and extensions
---@param path string Normalized path
---@param ignore_dirs string[] List of directory names to ignore
---@param watch_extensions string[] List of file extensions to watch (with dots)
---@return boolean
function M.should_watch_path(path, ignore_dirs, watch_extensions)
	if not path or path == "" then
		return false
	end

	-- Check against ignored directories (exact segment match) - fast path
	for _, dir in ipairs(ignore_dirs or {}) do
		if matches_ignore_dir(path, dir) then
			return false
		end
	end

	-- Check against ignore_patterns (glob patterns) - only if configured
	local config_ok, config = pcall(require, "roslyn_filewatch.config")
	if config_ok and config and config.options and config.options.ignore_patterns then
		local patterns = config.options.ignore_patterns
		if patterns and #patterns > 0 then
			if M.matches_any_pattern(path, patterns) then
				return false
			end
		end
	end

	-- Check file extension
	local ext = M.get_extension(path)
	if not ext then
		return false
	end

	-- Try O(1) cached lookup first (from config module)
	if config_ok and config and config.is_watched_extension then
		return config.is_watched_extension(ext)
	end

	-- Fallback to O(n) array iteration for backward compatibility
	local compare_ext = ext:lower()
	for _, watch_ext in ipairs(watch_extensions or {}) do
		if compare_ext == watch_ext:lower() then
			return true
		end
	end

	return false
end

--- Split path into segments
---@param path string
---@return string[]
function M.split_path(path)
	local segments = {}
	local normalized = M.normalize_path(path)
	for segment in normalized:gmatch("[^/]+") do
		table.insert(segments, segment)
	end
	return segments
end

--- Convert path to Roslyn-compatible format (Windows canonical path)
--- Ensures drive letter is uppercase and uses backslashes on Windows
---@param path string Path to convert
---@return string Roslyn-compatible path
function M.to_roslyn_path(path)
	if not path or path == "" then
		return path or ""
	end

	path = M.normalize_path(path)

	if M.is_windows() then
		-- Uppercase drive letter
		path = path:gsub("^(%a):", function(l)
			return l:upper() .. ":"
		end)
		-- Convert to backslashes for Roslyn
		path = path:gsub("/", "\\")
	end

	return path
end

--- Safely stop and close a timer or handle
--- Handles nil values and already-closing handles gracefully
---@param handle uv_timer_t|uv_fs_event_t|uv_fs_poll_t|nil Handle to close
function M.safe_close_handle(handle)
	if not handle then
		return
	end

	pcall(function()
		-- Check if handle has is_closing method and is not already closing
		if handle.is_closing and handle:is_closing() then
			return
		end

		-- Stop if possible
		if handle.stop then
			pcall(handle.stop, handle)
		end

		-- Close if possible
		if handle.close then
			pcall(handle.close, handle)
		end
	end)
end

--- Request diagnostics refresh for a client's attached buffers
--- Common pattern used throughout the plugin after project changes
---@param client vim.lsp.Client|nil The LSP client
---@param delay_ms number|nil Delay before requesting (default: 2000)
function M.request_diagnostics_refresh(client, delay_ms)
	if not client then
		return
	end

	delay_ms = delay_ms or 2000

	vim.defer_fn(function()
		-- Check if client is still active
		if client.is_stopped and client.is_stopped() then
			return
		end

		local attached_bufs = vim.lsp.get_buffers_by_client_id(client.id)
		for _, buf in ipairs(attached_bufs or {}) do
			if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
				pcall(function()
					client:request(vim.lsp.protocol.Methods.textDocument_diagnostic, {
						textDocument = vim.lsp.util.make_text_document_params(buf),
					}, nil, buf)
				end)
			end
		end
	end, delay_ms)
end

--- Send project/open notification to Roslyn LSP
--- Common pattern used when opening/reloading projects
---@param client vim.lsp.Client The LSP client
---@param project_paths string[] List of project file paths (already in Roslyn format)
---@param notify_fn fun(msg: string, level: number)|nil Optional notify function for logging
function M.notify_project_open(client, project_paths, notify_fn)
	if not client or not project_paths or #project_paths == 0 then
		return
	end

	local project_uris = vim.tbl_map(function(p)
		return vim.uri_from_fname(p)
	end, project_paths)

	pcall(function()
		client:notify("project/open", {
			projects = project_uris,
		})
	end)

	if notify_fn then
		pcall(notify_fn, "[PROJECT] Sent project/open for " .. #project_paths .. " project(s)", vim.log.levels.DEBUG)
	end
end

return M
