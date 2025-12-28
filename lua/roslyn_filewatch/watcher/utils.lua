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
---@param path string Normalized path with forward slashes
---@param ignore_dir string Directory name to check
---@return boolean
local function matches_ignore_dir(path, ignore_dir)
	-- Pattern: /dir/ or /dir at end
	-- Use pattern anchoring to match exact segment
	local pattern_mid = "/" .. ignore_dir .. "/"
	local pattern_end = "/" .. ignore_dir .. "$"

	if path:find(pattern_mid, 1, true) then
		return true
	end
	if path:match(pattern_end) then
		return true
	end

	-- Also check if path starts with the ignore dir (e.g., root level)
	local pattern_start = "^" .. ignore_dir .. "/"
	if path:match(pattern_start) then
		return true
	end

	return false
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

	-- Check against ignored directories (exact segment match)
	for _, dir in ipairs(ignore_dirs or {}) do
		if matches_ignore_dir(path, dir) then
			return false
		end
	end

	-- Check file extension
	local ext = M.get_extension(path)
	if not ext then
		return false
	end

	-- Case-insensitive extension matching on Windows
	local compare_ext = M.is_windows() and ext:lower() or ext

	for _, watch_ext in ipairs(watch_extensions or {}) do
		local compare_watch = M.is_windows() and watch_ext:lower() or watch_ext
		if compare_ext == compare_watch then
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

return M
