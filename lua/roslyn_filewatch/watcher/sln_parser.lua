---@class roslyn_filewatch.sln_parser
---@field find_sln fun(root: string): string|nil, "sln"|"slnx"|"slnf"|nil
---@field get_project_dirs fun(sln_path: string, sln_type?: "sln"|"slnx"|"slnf"): string[]

---Solution file (.sln/.slnx/.slnf) parser for solution-aware watching.
---Extracts project directories from solution files to limit watch scope.
---Supports:
---  - Traditional .sln text format
---  - Newer .slnx XML format (VS 2022 17.13+, .NET 9)
---  - Solution filter .slnf JSON format

local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

--- Find .sln, .slnx, or .slnf file in the given root directory
--- Priority: .slnf > .slnx > .sln (filter first, then newer format)
---@param root string Root directory path
---@return string|nil sln_path Path to solution file, or nil if not found
---@return "sln"|"slnx"|"slnf"|nil sln_type Type of solution file found
function M.find_sln(root)
  if not root or root == "" then
    return nil, nil
  end

  root = utils.normalize_path(root)

  -- Use vim.fs.find to search for .sln, .slnx, and .slnf files
  local solution_files = vim.fs.find(function(name, _)
    return name:match("%.slnx?$") or name:match("%.slnf$")
  end, {
    path = root,
    limit = 10, -- get several to pick the best one
    type = "file",
  })

  if solution_files and #solution_files > 0 then
    -- Priority: .slnf > .slnx > .sln
    -- .slnf (solution filter) takes highest priority as it's a user preference
    for _, path in ipairs(solution_files) do
      if path:match("%.slnf$") then
        return utils.normalize_path(path), "slnf"
      end
    end
    -- Then .slnx (newer format)
    for _, path in ipairs(solution_files) do
      if path:match("%.slnx$") then
        return utils.normalize_path(path), "slnx"
      end
    end
    -- Fall back to .sln
    for _, path in ipairs(solution_files) do
      if path:match("%.sln$") then
        return utils.normalize_path(path), "sln"
      end
    end
  end

  return nil, nil
end

--- Parse traditional .sln file content and extract project paths
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

--- Parse .slnx (XML format) file content and extract project paths
--- Format: <Solution><Project Path="relative/path/to/project.csproj" /></Solution>
---@param content string Content of the .slnx file
---@param sln_dir string Directory containing the .slnx file
---@return string[] project_dirs List of absolute project directory paths
local function parse_slnx_content(content, sln_dir)
  local project_dirs = {}
  local seen = {}
  local has_subdirectory_projects = false

  -- Match <Project Path="..."> or <Project Path='...'> elements
  -- The .slnx format uses XML with Project elements containing Path attributes
  for project_path in content:gmatch('<Project[^>]*Path%s*=%s*"([^"]+)"') do
    local normalized = project_path:gsub("\\", "/")

    -- Get the directory containing the project file
    local project_dir = normalized:match("^(.+)/[^/]+$")
    if project_dir then
      has_subdirectory_projects = true
      -- Make absolute path
      local abs_dir = utils.normalize_path(sln_dir .. "/" .. project_dir)

      -- Avoid duplicates
      if not seen[abs_dir] then
        seen[abs_dir] = true
        table.insert(project_dirs, abs_dir)
      end
    else
      -- Project file is in sln directory (no path separator)
      if not seen[sln_dir] then
        seen[sln_dir] = true
        table.insert(project_dirs, sln_dir)
      end
    end
  end

  -- Also try single-quoted attributes (less common but valid XML)
  for project_path in content:gmatch("<Project[^>]*Path%s*=%s*'([^']+)'") do
    local normalized = project_path:gsub("\\", "/")

    local project_dir = normalized:match("^(.+)/[^/]+$")
    if project_dir then
      has_subdirectory_projects = true
      local abs_dir = utils.normalize_path(sln_dir .. "/" .. project_dir)
      if not seen[abs_dir] then
        seen[abs_dir] = true
        table.insert(project_dirs, abs_dir)
      end
    else
      if not seen[sln_dir] then
        seen[sln_dir] = true
        table.insert(project_dirs, sln_dir)
      end
    end
  end

  -- Unity-style slnx fix: If ALL projects are at root level (no subdirectory paths),
  -- this is likely a Unity project where .csproj files are in root but actual
  -- source files (.cs) are in Assets/ subdirectories.
  -- Return empty to trigger full recursive scan instead of solution-aware scan.
  if not has_subdirectory_projects and #project_dirs == 1 then
    -- All projects are at root level - return empty to trigger full scan fallback
    return {}
  end

  return project_dirs
end

--- Get project directories from a .sln, .slnx, or .slnf file
---@param sln_path string Path to the solution file
---@param sln_type? "sln"|"slnx"|"slnf" Type of solution file (auto-detected if nil)
---@return string[] project_dirs List of absolute project directory paths
function M.get_project_dirs(sln_path, sln_type)
  if not sln_path or sln_path == "" then
    return {}
  end

  sln_path = utils.normalize_path(sln_path)

  -- Auto-detect type if not provided
  if not sln_type then
    if sln_path:match("%.slnf$") then
      sln_type = "slnf"
    elseif sln_path:match("%.slnx$") then
      sln_type = "slnx"
    else
      sln_type = "sln"
    end
  end

  -- Read the solution file
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

  -- Get the directory containing the solution file
  local sln_dir = sln_path:match("^(.+)/[^/]+$") or sln_path:match("^(.+)$")
  if not sln_dir then
    return {}
  end

  -- Parse based on file type
  if sln_type == "slnf" then
    -- .slnf is JSON format: { "solution": { "path": "x.sln", "projects": ["a.csproj", "b.csproj"] } }
    local decode_ok, json = pcall(vim.json.decode, content)
    if not decode_ok or not json or not json.solution then
      return {}
    end

    local project_dirs = {}
    local seen = {}
    local has_subdirectory_projects = false

    -- Parse project paths from the filter
    local projects = json.solution.projects or {}
    for _, project_path in ipairs(projects) do
      -- Normalize path separators
      local normalized = project_path:gsub("\\", "/")

      -- Get the directory containing the project file
      local project_dir = normalized:match("^(.+)/[^/]+$")
      if project_dir then
        has_subdirectory_projects = true
        -- Make absolute path
        local abs_dir = utils.normalize_path(sln_dir .. "/" .. project_dir)

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

    -- Unity-style fix: if all projects are at root level, trigger full scan
    if not has_subdirectory_projects and #project_dirs == 1 then
      return {}
    end

    return project_dirs
  elseif sln_type == "slnx" then
    return parse_slnx_content(content, sln_dir)
  else
    return parse_sln_content(content, sln_dir)
  end
end

--- Find .csproj and .vbproj files in the given root directory
---@param root string Root directory path
---@return string[] project_paths List of paths to project files
function M.find_csproj_files(root)
  if not root or root == "" then
    return {}
  end

  root = utils.normalize_path(root)

  -- Use vim.fs.find to search for .csproj and .vbproj files
  local project_files = vim.fs.find(function(name, _)
    return name:match("%.csproj$") or name:match("%.vbproj$")
  end, {
    path = root,
    limit = 50, -- reasonable limit to avoid scanning huge monorepos
    type = "file",
  })

  local result = {}
  for _, path in ipairs(project_files or {}) do
    table.insert(result, utils.normalize_path(path))
  end

  return result
end

--- Get project directories from .csproj files (fallback when no .sln found)
---@param root string Root directory path
---@return string[] project_dirs List of absolute project directory paths
function M.get_csproj_dirs(root)
  local csproj_files = M.find_csproj_files(root)
  if #csproj_files == 0 then
    return {}
  end

  local project_dirs = {}
  local seen = {}

  for _, csproj_path in ipairs(csproj_files) do
    -- Get the directory containing the .csproj file
    local project_dir = csproj_path:match("^(.+)/[^/]+$")
    if project_dir and not seen[project_dir] then
      seen[project_dir] = true
      table.insert(project_dirs, project_dir)
    end
  end

  return project_dirs
end

--- Get project directories for a root, with caching
--- Returns nil if solution-aware watching should be skipped (fallback to full scan)
---@param root string Root directory path
---@return string[]|nil project_dirs List of project directories, or nil to use full scan
function M.get_watch_dirs(root)
  if not root or root == "" then
    return nil
  end

  local sln_path, sln_type = M.find_sln(root)
  if sln_path then
    -- .sln or .slnx found, parse it for project directories
    local dirs = M.get_project_dirs(sln_path, sln_type)
    if #dirs > 0 then
      -- Always include the sln directory itself (for .sln/.slnx/.props/.targets changes)
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
  end

  -- No .sln/.slnx found (or empty), try fallback to .csproj scanning
  local csproj_dirs = M.get_csproj_dirs(root)
  if #csproj_dirs > 0 then
    -- Also include root directory for shared files like .editorconfig, Directory.Build.props etc.
    local seen = {}
    for _, d in ipairs(csproj_dirs) do
      seen[d] = true
    end
    root = utils.normalize_path(root)
    if not seen[root] then
      table.insert(csproj_dirs, root)
    end

    -- For csproj-only projects (no solution file), always use full recursive scan
    -- This ensures all source files are properly watched regardless of directory structure.
    -- Solution-aware scanning can miss files in subdirectories when csproj files are at root.
    -- Unity-style fix: If all csproj files are at root level (only root in list),
    -- return nil to trigger full recursive scan instead of solution-aware scan.
    if #csproj_dirs == 1 and csproj_dirs[1] == root then
      return nil -- Full scan for projects with csproj at root
    end

    -- Even if csproj files are in subdirectories, for csproj-only projects we should
    -- use full scan to ensure all source files are watched (csproj-only projects
    -- don't have solution files to limit scope, so we need to watch everything)
    return nil -- Always use full scan for csproj-only projects
  end

  return nil -- No .sln/.slnx or .csproj found, use full scan
end

--- Get solution file information including path, type, and modification time
--- Used for change detection to trigger rescans when .slnx is modified
---@param root string Root directory path
---@return { path: string, type: "sln"|"slnx"|"slnf", mtime: number }|nil sln_info Solution info or nil if not found
function M.get_sln_info(root)
  if not root or root == "" then
    return nil
  end

  local sln_path, sln_type = M.find_sln(root)
  if not sln_path then
    return nil
  end

  -- Get the modification time of the solution file
  local stat = uv.fs_stat(sln_path)
  if not stat then
    return nil
  end

  -- Use mtime in nanoseconds for precision
  local mtime = stat.mtime and (stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)) or 0

  return {
    path = sln_path,
    type = sln_type,
    mtime = mtime,
  }
end

return M
