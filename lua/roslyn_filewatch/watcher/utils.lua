---@class roslyn_filewatch.utils
---@diagnostic disable-next-line: undefined-doc-name
---@field mtime_ns fun(stat: uv.fs_stat.result|roslyn_filewatch.SnapshotEntry|nil): number
---@diagnostic disable-next-line: undefined-doc-name
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

---@diagnostic disable: undefined-field, undefined-doc-name

local M = {}

local _cached_config = nil
local function get_config()
  if _cached_config then
    return _cached_config
  end
  local ok, cfg = pcall(require, "roslyn_filewatch.config")
  if ok and cfg then
    _cached_config = cfg
  end
  return _cached_config
end

local _is_windows_cache = nil

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
    _is_windows_cache = package.config:sub(1, 1) == "\\"
  end

  return _is_windows_cache
end

local _is_case_insensitive_cache = nil

function M.is_case_insensitive()
  if _is_case_insensitive_cache ~= nil then
    return _is_case_insensitive_cache
  end

  if M.is_windows() then
    _is_case_insensitive_cache = true
    return true
  end

  local ok, uname = pcall(function()
    return uv.os_uname()
  end)

  if ok and uname and uname.sysname == "Darwin" then
    local script_path = debug.getinfo(1, "S").source:sub(2)
    if script_path then
      local lower = script_path:lower()
      local upper = script_path:upper()

      local stat_lower = uv.fs_stat(lower)
      local stat_upper = uv.fs_stat(upper)

      if stat_lower and stat_upper then
        if stat_lower.dev == stat_upper.dev and stat_lower.ino == stat_upper.ino then
          _is_case_insensitive_cache = true
          return true
        end
      end
    end

    _is_case_insensitive_cache = true
    return true
  end

  _is_case_insensitive_cache = false
  return false
end

function M.mtime_ns(stat)
  if not stat then
    return 0
  end

  local mt = stat.mtime
  if type(mt) == "table" then
    return (mt.sec or 0) * 1e9 + (mt.nsec or 0)
  elseif type(mt) == "number" then
    return mt
  end

  return 0
end

function M.identity_from_stat(st)
  if not st then
    return nil
  end

  if st.dev and st.ino then
    return tostring(st.dev) .. ":" .. tostring(st.ino)
  end

  if st.mtime and type(st.mtime) == "number" and st.size then
    return tostring(st.mtime) .. ":" .. tostring(st.size)
  end

  if st.mtime and type(st.mtime) == "table" and st.size then
    local m = M.mtime_ns(st)
    if m and st.size then
      return tostring(m) .. ":" .. tostring(st.size)
    end
  end

  return nil
end

function M.same_file_info(a, b)
  if not a or not b then
    return false
  end
  return a.mtime == b.mtime and a.size == b.size
end

--- Normalize path: unify separators, remove trailing slashes, lowercase drive on windows
---@param p string|nil
---@return string
function M.normalize_path(p)
  if not p or p == "" then
    return p or ""
  end

  local is_win = M.is_windows()

  -- Unify separators to forward slash
  if is_win or p:find("\\", 1, true) then
    p = p:gsub("\\", "/")
  end

  -- Remove trailing slashes (but preserve root like "C:/")
  if #p > 1 and p:sub(-1) == "/" then
    -- Check if it's a Windows root like "C:/"
    if not (is_win and #p == 3 and p:sub(2, 3) == ":/") then
      p = p:gsub("/+$", "")
    end
  end

  if is_win then
    -- Lowercase drive letter on Windows-style "C:/..."
    local drive = p:match("^([A-Za-z]):/")
    if drive then
      p = drive:lower() .. p:sub(2)
    end
  end

  return p
end

function M.paths_equal(a, b)
  if not a or not b then
    return a == b
  end

  local norm_a = M.normalize_path(a)
  local norm_b = M.normalize_path(b)

  if M.is_case_insensitive() then
    return norm_a:lower() == norm_b:lower()
  else
    return norm_a == norm_b
  end
end

function M.path_starts_with(path, prefix)
  if not path or not prefix then
    return false
  end

  local norm_path = M.normalize_path(path)
  local norm_prefix = M.normalize_path(prefix)

  if M.is_case_insensitive() then
    return norm_path:lower():sub(1, #norm_prefix) == norm_prefix:lower()
  else
    return norm_path:sub(1, #norm_prefix) == norm_prefix
  end
end

function M.get_extension(path)
  if not path or path == "" then
    return nil
  end
  local filename = path:match("[/\\]?([^/\\]+)$") or path
  local ext = filename:match("(%.[^.]+)$")
  return ext
end

local function matches_ignore_dir(path, ignore_dir)
  local is_win = M.is_windows()
  local cmp_path = is_win and path:lower() or path
  local cmp_dir = is_win and ignore_dir:lower() or ignore_dir

  if cmp_path:find("/" .. cmp_dir .. "/", 1, true) then
    return true
  end
  local suffix = "/" .. cmp_dir
  if #cmp_path >= #suffix and cmp_path:sub(-#suffix) == suffix then
    return true
  end
  local prefix = cmp_dir .. "/"
  if cmp_path:sub(1, #prefix) == prefix then
    return true
  end

  return false
end

local function glob_to_lua_pattern(pattern)
  local escaped = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")

  escaped = escaped:gsub("%*%*", "\1")
  escaped = escaped:gsub("%*", "[^/]*")
  escaped = escaped:gsub("%?", "[^/]")
  escaped = escaped:gsub("\1", ".*")

  return escaped
end

-- Cache for compiled glob patterns to avoid expensive string manipulation
local _glob_cache = {}

local function matches_glob_pattern(path, pattern)
  if not path or path == "" or not pattern or pattern == "" then
    return false
  end

  local is_negated = false
  if pattern:sub(1, 1) == "!" then
    is_negated = true
    pattern = pattern:sub(2)
  end

  local lua_pattern = _glob_cache[pattern]
  if not lua_pattern then
    local p = pattern:gsub("\\", "/")
    lua_pattern = glob_to_lua_pattern(p)
    _glob_cache[pattern] = lua_pattern
  end

  local cmp_path = M.is_case_insensitive() and path:lower() or path
  local cmp_pattern = M.is_case_insensitive() and pattern:lower() or pattern

  if M.is_case_insensitive() then
    local cache_key = pattern:lower() .. "_lower"
    if not _glob_cache[cache_key] then
      _glob_cache[cache_key] = glob_to_lua_pattern(cmp_pattern:gsub("\\", "/"))
    end
    lua_pattern = _glob_cache[cache_key]
  end

  local matches = false

  if cmp_pattern:sub(1, 2) == "**" then
    if cmp_path:match(lua_pattern) then
      matches = true
    end
  elseif not cmp_pattern:find("/") then
    local basename = cmp_path:match("[^/]+$") or cmp_path
    if basename:match("^" .. lua_pattern .. "$") then
      matches = true
    end
  else
    if cmp_path:match("^" .. lua_pattern .. "$") or cmp_path:match("^" .. lua_pattern .. "/") then
      matches = true
    end
    if not matches and cmp_path:match("/" .. lua_pattern .. "$") then
      matches = true
    end
    if not matches and cmp_path:match("/" .. lua_pattern .. "/") then
      matches = true
    end
  end

  if is_negated then
    return not matches
  end
  return matches
end

function M.matches_any_pattern(path, patterns)
  if not patterns or #patterns == 0 then
    return false
  end

  local excluded = false
  for _, pattern in ipairs(patterns) do
    if pattern and pattern ~= "" then
      local is_negated = pattern:sub(1, 1) == "!"
      if is_negated then
        if matches_glob_pattern(path, pattern:sub(2)) then
          excluded = false
        end
      else
        if matches_glob_pattern(path, pattern) then
          excluded = true
        end
      end
    end
  end

  return excluded
end

function M.should_watch_path(path, ignore_dirs, watch_extensions)
  if not path or path == "" then
    return false
  end

  local cfg = get_config()

  if cfg and cfg._ignore_dirs_set then
    for segment in path:gmatch("[^/]+") do
      if cfg._ignore_dirs_set[segment:lower()] then
        return false
      end
    end
  else
    for _, dir in ipairs(ignore_dirs or {}) do
      if matches_ignore_dir(path, dir) then
        return false
      end
    end
  end

  if cfg and cfg.options and cfg.options.ignore_patterns then
    local patterns = cfg.options.ignore_patterns
    if patterns and #patterns > 0 then
      if M.matches_any_pattern(path, patterns) then
        return false
      end
    end
  end

  local ext = M.get_extension(path)
  if not ext then
    return false
  end

  if cfg and cfg.is_watched_extension then
    return cfg.is_watched_extension(ext)
  end

  local compare_ext = ext:lower()
  for _, watch_ext in ipairs(watch_extensions or {}) do
    if compare_ext == watch_ext:lower() then
      return true
    end
  end

  return false
end

function M.split_path(path)
  local segments = {}
  local normalized = M.normalize_path(path)
  for segment in normalized:gmatch("[^/]+") do
    table.insert(segments, segment)
  end
  return segments
end

function M.to_roslyn_path(path)
  if not path or path == "" then
    return path or ""
  end

  path = M.normalize_path(path)

  if M.is_windows() then
    path = path:gsub("^(%a):", function(l)
      return l:upper() .. ":"
    end)
    path = path:gsub("/", "\\")
  end

  return path
end

function M.safe_close_handle(handle)
  if not handle then
    return
  end

  pcall(function()
    if handle.is_closing and handle:is_closing() then
      return
    end

    if handle.stop then
      pcall(handle.stop, handle)
    end

    if handle.close then
      pcall(handle.close, handle)
    end
  end)
end

function M.request_diagnostics_refresh(client, delay_ms)
  if not client then
    return
  end

  delay_ms = delay_ms or 2000

  vim.defer_fn(function()
    if client:is_stopped() then
      return
    end

    local lsp_client = vim.lsp.get_client_by_id(client.id)
    local attached_bufs = (lsp_client and lsp_client.attached_buffers) or {}
    for buf, _ in pairs(attached_bufs) do
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

function M.notify_project_open(client, project_paths, notify_fn)
  if not client or not project_paths or #project_paths == 0 then
    return
  end

  local project_uris = vim.tbl_map(function(p)
    return vim.uri_from_fname(p)
  end, project_paths)

  pcall(function()
    ---@diagnostic disable-next-line: param-type-mismatch
    client:notify("project/open", {
      projects = project_uris,
    })
  end)

  if notify_fn then
    pcall(notify_fn, "[PROJECT] Sent project/open for " .. #project_paths .. " project(s)", vim.log.levels.DEBUG)
  end
end

return M
