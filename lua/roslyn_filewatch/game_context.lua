---@class roslyn_filewatch.game_context
---@field detect_engine fun(root: string): string|nil
---@field setup fun(client: vim.lsp.Client)
---@field get_engine fun(root: string): table|nil

---Game engine context provider.
---Detects the game engine type and provides engine-specific enhancements:
---  - Unity: Assembly Definitions, MonoBehaviour hints, Roslyn Analyzers
---  - Godot: Node scripts, GDScript naming conventions
---  - Stride/MonoGame/FNA: Basic project structure support

local M = {}

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

-- Lazy-loaded engine modules
local unity_mod = nil
local godot_mod = nil

--- Get Unity module (lazy load)
---@return table|nil
local function get_unity_mod()
  if not unity_mod then
    local ok, mod = pcall(require, "roslyn_filewatch.game_engines.unity")
    if ok then
      unity_mod = mod
    end
  end
  return unity_mod
end

--- Get Godot module (lazy load)
---@return table|nil
local function get_godot_mod()
  if not godot_mod then
    local ok, mod = pcall(require, "roslyn_filewatch.game_engines.godot")
    if ok then
      godot_mod = mod
    end
  end
  return godot_mod
end

--- Normalize path separators
---@param path string
---@return string
local function normalize_path(path)
  return path:gsub("\\", "/")
end

--- Detect which game engine is being used
---@param root string Project root
---@return string|nil engine_name "unity", "godot", "stride", "monogame", "fna", or nil
function M.detect_engine(root)
  if not root or root == "" then
    return nil
  end

  root = normalize_path(root)
  if not root:match("/$") then
    root = root .. "/"
  end

  -- Check Unity first (most common)
  local unity = get_unity_mod()
  if unity and unity.detect(root) then
    return "unity"
  end

  -- Check Godot
  local godot = get_godot_mod()
  if godot and godot.detect(root) then
    return "godot"
  end

  -- Check Stride (.sdpkg file)
  local fd = uv.fs_scandir(root)
  if fd then
    while true do
      local name, typ = uv.fs_scandir_next(fd)
      if not name then
        break
      end
      if typ == "file" then
        if name:match("%.sdpkg$") then
          return "stride"
        elseif name:match("%.mgcb$") or name == "Content.mgcb" then
          return "monogame"
        end
      elseif typ == "directory" then
        if name == "fnalibs" or name == "FNALibs" then
          return "fna"
        end
      end
    end
  end

  -- Check Content folder for MonoGame
  local content_dir = uv.fs_stat(root .. "Content")
  if content_dir and content_dir.type == "directory" then
    local content_fd = uv.fs_scandir(root .. "Content")
    if content_fd then
      while true do
        local name, typ = uv.fs_scandir_next(content_fd)
        if not name then
          break
        end
        if typ == "file" and name:match("%.mgcb$") then
          return "monogame"
        end
      end
    end
  end

  return nil
end

--- Get engine-specific module
---@param engine_name string
---@return table|nil engine_module
function M.get_engine_module(engine_name)
  if engine_name == "unity" then
    return get_unity_mod()
  elseif engine_name == "godot" then
    return get_godot_mod()
  end
  return nil
end

--- Setup game engine context for a client
--- This configures engine-specific analyzers and settings
---@param client vim.lsp.Client
function M.setup(client)
  if not client then
    return
  end

  -- Safe client validity check
  local is_valid = pcall(function()
    return client.id and not (client.is_stopped and client.is_stopped())
  end)
  if not is_valid then
    return
  end

  local root = client.config and client.config.root_dir
  if not root then
    return
  end

  -- Detect engine (quick check, no heavy scanning)
  local engine = M.detect_engine(root)
  if not engine then
    return
  end

  -- Log detection (only at DEBUG level to avoid spam)
  if config.options and config.options.log_level and config.options.log_level <= vim.log.levels.DEBUG then
    vim.notify("[roslyn-filewatch] Detected game engine: " .. engine, vim.log.levels.DEBUG)
  end

  -- Apply engine-specific settings with safety wrapper
  local engine_mod = M.get_engine_module(engine)
  if engine_mod and engine_mod.setup_analyzers then
    -- Delay to let Roslyn initialize first
    vim.defer_fn(function()
      -- Re-check client validity
      local still_valid = pcall(function()
        return client.id and not (client.is_stopped and client.is_stopped())
      end)
      if still_valid then
        pcall(engine_mod.setup_analyzers, client)
      end
    end, 3000) -- 3 second delay
  end
end

--- Get engine info for status display
---@param root string
---@return table|nil info Engine info
function M.get_info(root)
  local engine = M.detect_engine(root)
  if not engine then
    return nil
  end

  local info = {
    engine = engine,
  }

  if engine == "unity" then
    local unity = get_unity_mod()
    if unity then
      info.assembly_definitions = unity.get_assembly_definitions(root)
    end
  elseif engine == "godot" then
    local godot = get_godot_mod()
    if godot then
      info.project_info = godot.get_project_info(root)
    end
  end

  return info
end

return M
