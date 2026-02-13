---@class roslyn_filewatch.sln_parser
---@field find_sln fun(root: string): string|nil, "sln"|"slnx"|"slnf"|nil
---@field get_project_dirs fun(sln_path: string, sln_type?: "sln"|"slnx"|"slnf"): string[]

local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

function M.find_sln(root)
  if not root or root == "" then
    return nil, nil
  end

  root = utils.normalize_path(root)

  local solution_files = vim.fs.find(function(name)
    return name:match("%.slnx?$") or name:match("%.slnf$")
  end, { path = root, limit = 10, type = "file" })

  if solution_files and #solution_files > 0 then
    for _, path in ipairs(solution_files) do
      if path:match("%.slnf$") then
        return utils.normalize_path(path), "slnf"
      end
    end
    for _, path in ipairs(solution_files) do
      if path:match("%.slnx$") then
        return utils.normalize_path(path), "slnx"
      end
    end
    for _, path in ipairs(solution_files) do
      if path:match("%.sln$") then
        return utils.normalize_path(path), "sln"
      end
    end
  end

  return nil, nil
end

function M.find_sln_async(root, callback)
  if not root or root == "" then
    callback(nil, nil)
    return
  end

  root = utils.normalize_path(root)

  uv.fs_scandir(root, function(err, fd)
    if err or not fd then
      callback(nil, nil)
      return
    end

    local candidates = {}
    while true do
      local name, typ = uv.fs_scandir_next(fd)
      if not name then
        break
      end
      if typ == "file" then
        if name:match("%.slnf$") then
          table.insert(candidates, { name = name, type = "slnf", score = 3 })
        elseif name:match("%.slnx$") then
          table.insert(candidates, { name = name, type = "slnx", score = 2 })
        elseif name:match("%.sln$") then
          table.insert(candidates, { name = name, type = "sln", score = 1 })
        end
      end
    end

    if #candidates == 0 then
      callback(nil, nil)
      return
    end

    table.sort(candidates, function(a, b)
      return a.score > b.score
    end)

    local best = candidates[1]
    callback(utils.normalize_path(root .. "/" .. best.name), best.type)
  end)
end

local function parse_sln_content(content, sln_dir)
  local project_dirs = {}
  local seen = {}

  for project_path in content:gmatch('Project%("[^"]*"%)%s*=%s*"[^"]*",%s*"([^"]+)"') do
    if project_path:match("%.[^.]+$") then
      local normalized = project_path:gsub("\\", "/")
      local project_dir = normalized:match("^(.+)/[^/]+$")
      if project_dir then
        local abs_dir = utils.normalize_path(sln_dir .. "/" .. project_dir)
        if not seen[abs_dir] then
          seen[abs_dir] = true
          table.insert(project_dirs, abs_dir)
        end
      elseif not seen[sln_dir] then
        seen[sln_dir] = true
        table.insert(project_dirs, sln_dir)
      end
    end
  end

  return project_dirs
end

local function parse_slnx_content(content, sln_dir)
  local project_dirs = {}
  local seen = {}
  local has_subdirectory_projects = false

  for project_path in content:gmatch('<Project[^>]*Path%s*=%s*"([^"]+)"') do
    local normalized = project_path:gsub("\\", "/")
    local project_dir = normalized:match("^(.+)/[^/]+$")
    if project_dir then
      has_subdirectory_projects = true
      local abs_dir = utils.normalize_path(sln_dir .. "/" .. project_dir)
      if not seen[abs_dir] then
        seen[abs_dir] = true
        table.insert(project_dirs, abs_dir)
      end
    elseif not seen[sln_dir] then
      seen[sln_dir] = true
      table.insert(project_dirs, sln_dir)
    end
  end

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
    elseif not seen[sln_dir] then
      seen[sln_dir] = true
      table.insert(project_dirs, sln_dir)
    end
  end

  if not has_subdirectory_projects and #project_dirs == 1 then
    return {}
  end

  return project_dirs
end

function M.get_project_dirs_async(sln_path, sln_type, callback)
  if not sln_path or sln_path == "" then
    callback({})
    return
  end

  sln_path = utils.normalize_path(sln_path)

  if not sln_type then
    if sln_path:match("%.slnf$") then
      sln_type = "slnf"
    elseif sln_path:match("%.slnx$") then
      sln_type = "slnx"
    else
      sln_type = "sln"
    end
  end

  uv.fs_open(sln_path, "r", 438, function(err, fd)
    if err or not fd then
      callback({})
      return
    end

    uv.fs_fstat(fd, function(err_stat, stat)
      if err_stat or not stat then
        uv.fs_close(fd)
        callback({})
        return
      end

      uv.fs_read(fd, stat.size, 0, function(err_read, data)
        uv.fs_close(fd)

        if err_read or not data then
          callback({})
          return
        end

        vim.schedule(function()
          local sln_dir = sln_path:match("^(.+)/[^/]+$") or sln_path
          local dirs

          if sln_type == "slnf" then
            local ok, json = pcall(vim.json.decode, data)
            if not ok or not json or not json.solution then
              callback({})
              return
            end

            dirs = {}
            local seen = {}
            local has_sub = false
            for _, project_path in ipairs(json.solution.projects or {}) do
              local normalized = project_path:gsub("\\", "/")
              local project_dir = normalized:match("^(.+)/[^/]+$")
              if project_dir then
                has_sub = true
                local abs_dir = utils.normalize_path(sln_dir .. "/" .. project_dir)
                if not seen[abs_dir] then
                  seen[abs_dir] = true
                  table.insert(dirs, abs_dir)
                end
              elseif not seen[sln_dir] then
                seen[sln_dir] = true
                table.insert(dirs, sln_dir)
              end
            end
            if not has_sub and #dirs == 1 then
              dirs = {}
            end
          elseif sln_type == "slnx" then
            dirs = parse_slnx_content(data, sln_dir)
          else
            dirs = parse_sln_content(data, sln_dir)
          end

          callback(dirs or {})
        end)
      end)
    end)
  end)
end

function M.find_csproj_files(root)
  if not root or root == "" then
    return {}
  end

  root = utils.normalize_path(root)

  local project_files = vim.fs.find(function(name)
    return name:match("%.csproj$") or name:match("%.vbproj$")
  end, { path = root, limit = 50, type = "file" })

  local result = {}
  for _, path in ipairs(project_files or {}) do
    table.insert(result, utils.normalize_path(path))
  end
  return result
end

function M.get_csproj_dirs(root)
  local csproj_files = M.find_csproj_files(root)
  if #csproj_files == 0 then
    return {}
  end

  local project_dirs = {}
  local seen = {}

  for _, csproj_path in ipairs(csproj_files) do
    local project_dir = csproj_path:match("^(.+)/[^/]+$")
    if project_dir and not seen[project_dir] then
      seen[project_dir] = true
      table.insert(project_dirs, project_dir)
    end
  end

  return project_dirs
end

function M.get_watch_dirs(root)
  if not root or root == "" then
    return nil
  end

  local sln_path, sln_type = M.find_sln(root)
  if sln_path then
    local dirs = M.get_project_dirs(sln_path, sln_type)
    if #dirs > 0 then
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

  local csproj_dirs = M.get_csproj_dirs(root)
  if #csproj_dirs > 0 then
    local seen = {}
    for _, d in ipairs(csproj_dirs) do
      seen[d] = true
    end
    root = utils.normalize_path(root)
    if not seen[root] then
      table.insert(csproj_dirs, root)
    end

    if #csproj_dirs == 1 and csproj_dirs[1] == root then
      return nil
    end

    return nil
  end

  return nil
end

function M.get_sln_info(root)
  if not root or root == "" then
    return nil
  end

  local sln_path, sln_type = M.find_sln(root)
  if not sln_path then
    return nil
  end

  local stat = uv.fs_stat(sln_path)
  if not stat then
    return nil
  end

  local mtime = stat.mtime and (stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)) or 0
  return { path = sln_path, type = sln_type, mtime = mtime }
end

function M.get_sln_info_async(root, callback)
  M.find_sln_async(root, function(sln_path, sln_type)
    if not sln_path then
      callback(nil)
      return
    end

    uv.fs_stat(sln_path, function(err, stat)
      if err or not stat then
        callback(nil)
        return
      end

      callback({
        path = sln_path,
        type = sln_type,
        mtime = stat.mtime and (stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)) or 0,
      })
    end)
  end)
end

return M
