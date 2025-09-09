local M = {}

-- compute mtime in nanoseconds
-- accepts a uv.fs_stat() like table with .mtime = { sec, nsec }
-- or a snapshot entry where .mtime is already a number (ns)
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

-- identity helpers: prefer dev:ino (when available), fallback to mtime:size
-- supports:
--  - uv.fs_stat() results (stat.dev, stat.ino, stat.mtime table)
--  - snapshot entries { mtime = <ns number>, size = <n>, ino = <>, dev = <> }
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

-- compare snapshot/file info (mtime in ns + size)
function M.same_file_info(a, b)
	if not a or not b then
		return false
	end
	-- both a.mtime and b.mtime should be numeric (ns)
	return a.mtime == b.mtime and a.size == b.size
end

-- normalize path: unify separators, remove trailing slashes, lowercase drive on windows
function M.normalize_path(p)
	if not p or p == "" then
		return p
	end
	-- unify separators
	p = p:gsub("\\", "/")
	-- remove trailing slashes
	p = p:gsub("/+$", "")
	-- lowercase drive letter on Windows-style "C:/..."
	local drive = p:match("^([A-Za-z]):/")
	if drive then
		p = drive:lower() .. p:sub(2)
	end
	return p
end

return M
