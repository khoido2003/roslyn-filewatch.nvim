---@class roslyn_filewatch.game_engines.unity
---@field detect fun(root: string): boolean
---@field setup_analyzers fun(client: vim.lsp.Client)
---@field get_assembly_definitions fun(root: string): table[]

---Unity game engine integration module.
---Provides Unity-specific features:
---  - Roslyn Analyzer configuration
---  - Assembly Definition (.asmdef) parsing
---  - MonoBehaviour context hints

local M = {}

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

--- Normalize path separators
---@param path string
---@return string
local function normalize_path(path)
  return path:gsub("\\", "/")
end

--- Check if path is a Unity project
---@param root string
---@return boolean
function M.detect(root)
  if not root or root == "" then
    return false
  end

  root = normalize_path(root)
  if not root:match("/$") then
    root = root .. "/"
  end

  -- Unity markers: need at least 2 of these
  local markers = { "Assets", "ProjectSettings", "Library" }
  local count = 0

  for _, marker in ipairs(markers) do
    local stat = uv.fs_stat(root .. marker)
    if stat and stat.type == "directory" then
      count = count + 1
    end
  end

  return count >= 2
end

--- Parse a single .asmdef file
---@param path string Path to .asmdef file
---@return table|nil parsed Assembly definition info
local function parse_asmdef(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end

  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end

  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)

  if not content then
    return nil
  end

  local ok, json = pcall(vim.json.decode, content)
  if not ok or not json then
    return nil
  end

  return {
    name = json.name,
    path = normalize_path(path),
    dir = normalize_path(path):match("^(.+)/[^/]+$"),
    references = json.references or {},
    includePlatforms = json.includePlatforms or {},
    excludePlatforms = json.excludePlatforms or {},
    allowUnsafeCode = json.allowUnsafeCode or false,
    autoReferenced = json.autoReferenced ~= false, -- default true
    defineConstraints = json.defineConstraints or {},
  }
end

--- Find and parse all Assembly Definition files in a Unity project
---@param root string Project root
---@return table[] asmdefs List of parsed assembly definitions
function M.get_assembly_definitions(root)
  if not root or root == "" then
    return {}
  end

  root = normalize_path(root)

  -- Find .asmdef files
  local asmdef_files = vim.fs.find(function(name, _)
    return name:match("%.asmdef$")
  end, {
    path = root,
    type = "file",
    limit = 100,
  })

  local asmdefs = {}
  for _, path in ipairs(asmdef_files) do
    local parsed = parse_asmdef(path)
    if parsed then
      table.insert(asmdefs, parsed)
    end
  end

  return asmdefs
end

--- Get Unity's default Roslyn Analyzer settings
---@return table settings EditorConfig-style settings for Unity
function M.get_analyzer_settings()
  return {
    -- Unity-specific analyzer rules
    ["dotnet_diagnostic.UNT0001.severity"] = "warning", -- Empty Update method
    ["dotnet_diagnostic.UNT0002.severity"] = "warning", -- Inefficient tag comparison
    ["dotnet_diagnostic.UNT0003.severity"] = "warning", -- Usage of non-generic GetComponent
    ["dotnet_diagnostic.UNT0004.severity"] = "warning", -- Time.fixedDeltaTime in Update
    ["dotnet_diagnostic.UNT0005.severity"] = "warning", -- Time.deltaTime in FixedUpdate
    ["dotnet_diagnostic.UNT0006.severity"] = "warning", -- Incorrect message signature
    ["dotnet_diagnostic.UNT0007.severity"] = "warning", -- Null coalescing on Unity object
    ["dotnet_diagnostic.UNT0008.severity"] = "warning", -- Null propagation on Unity object
    ["dotnet_diagnostic.UNT0009.severity"] = "warning", -- Missing static modifier
    ["dotnet_diagnostic.UNT0010.severity"] = "warning", -- MonoBehaviour in wrong file
    -- Performance hints
    ["dotnet_diagnostic.UNT0011.severity"] = "suggestion", -- ScriptableObject CreateInstance
    ["dotnet_diagnostic.UNT0012.severity"] = "suggestion", -- Unused coroutine
    ["dotnet_diagnostic.UNT0013.severity"] = "suggestion", -- Invalid SerializeField
    ["dotnet_diagnostic.UNT0014.severity"] = "warning", -- GetComponent with non-Component
    -- Code style for Unity
    ["dotnet_naming_rule.unity_serialized_field.severity"] = "suggestion",
    ["dotnet_naming_symbols.unity_serialized_field.applicable_kinds"] = "field",
    ["dotnet_naming_symbols.unity_serialized_field.applicable_accessibilities"] = "private",
  }
end

--- Setup Unity analyzers for a Roslyn client
--- Sends workspace/didChangeConfiguration with Unity-specific settings
---@param client vim.lsp.Client
function M.setup_analyzers(client)
  if not client or (client.is_stopped and client.is_stopped()) then
    return
  end

  local root = client.config and client.config.root_dir
  if not root then
    return
  end

  -- Only apply to Unity projects
  if not M.detect(root) then
    return
  end

  -- Get Unity-specific analyzer settings
  local settings = M.get_analyzer_settings()

  -- Get assembly definitions for better project understanding
  local asmdefs = M.get_assembly_definitions(root)

  -- Build configuration payload
  local configuration = {
    settings = {
      csharp = settings,
    },
  }

  -- Send configuration update to Roslyn
  pcall(function()
    client:notify("workspace/didChangeConfiguration", configuration)
  end)

  -- Log for debugging
  if config.options.log_level and config.options.log_level <= vim.log.levels.DEBUG then
    vim.notify(
      "[roslyn-filewatch] Applied Unity analyzer settings (" .. #asmdefs .. " assembly definitions found)",
      vim.log.levels.DEBUG
    )
  end
end

--- Check if a file is in an Editor assembly
---@param file_path string
---@param asmdefs table[] Assembly definitions
---@return boolean
function M.is_editor_script(file_path, asmdefs)
  file_path = normalize_path(file_path)

  -- Check if in Editor folder (Unity convention)
  if file_path:match("/Editor/") then
    return true
  end

  -- Check assembly definitions
  for _, asmdef in ipairs(asmdefs) do
    if file_path:find(asmdef.dir, 1, true) == 1 then
      -- Check if this is an Editor-only assembly
      local platforms = asmdef.includePlatforms
      if #platforms == 1 and platforms[1] == "Editor" then
        return true
      end
    end
  end

  return false
end

--- Get the assembly name for a given file
---@param file_path string
---@param asmdefs table[] Assembly definitions
---@return string|nil assembly_name
function M.get_assembly_for_file(file_path, asmdefs)
  file_path = normalize_path(file_path)

  -- Find the deepest matching asmdef
  local best_match = nil
  local best_depth = -1

  for _, asmdef in ipairs(asmdefs) do
    if file_path:find(asmdef.dir, 1, true) == 1 then
      local depth = select(2, asmdef.dir:gsub("/", ""))
      if depth > best_depth then
        best_depth = depth
        best_match = asmdef
      end
    end
  end

  if best_match then
    return best_match.name
  end

  -- Default Unity assemblies
  if file_path:match("/Editor/") then
    return "Assembly-CSharp-Editor"
  else
    return "Assembly-CSharp"
  end
end

--- Unity asset file extensions
M.asset_extensions = {
  ".unity", -- Scenes
  ".prefab", -- Prefabs
  ".asset", -- ScriptableObjects and other assets
  ".mat", -- Materials
  ".controller", -- Animator controllers
  ".anim", -- Animation clips
  ".meta", -- Unity metadata files
  ".asmdef", -- Assembly definitions
  ".asmref", -- Assembly references
  ".inputactions", -- Input System actions
  ".uxml", -- UI Toolkit layouts
  ".uss", -- UI Toolkit stylesheets
}

--- Check if a file is a Unity asset that might need LSP attention
---@param path string File path
---@return boolean is_important_asset
function M.is_important_asset(path)
  path = normalize_path(path)

  -- .meta files are important (track dependencies)
  if path:match("%.meta$") then
    return true
  end

  -- ScriptableObject .asset files (contain code references)
  if path:match("%.asset$") then
    return true
  end

  -- Assembly definition files (affect project structure)
  if path:match("%.asmdef$") or path:match("%.asmref$") then
    return true
  end

  -- Input System actions (contain action references)
  if path:match("%.inputactions$") then
    return true
  end

  -- Other assets generally don't need LSP notifications
  return false
end

--- Check if a path is in a Unity generated folder that should be ignored
---@param path string File path
---@return boolean should_ignore
function M.should_ignore_path(path)
  path = normalize_path(path)

  local ignore_patterns = {
    "/Library/",
    "/Temp/",
    "/Logs/",
    "/obj/",
    "/bin/",
    "/Build/",
    "/Builds/",
  }

  for _, pattern in ipairs(ignore_patterns) do
    if path:find(pattern, 1, true) then
      return true
    end
  end

  return false
end

--- Detect if Unity is currently recompiling (assembly reload in progress)
---@param root string Project root
---@return boolean is_recompiling
function M.is_assembly_reloading(root)
  root = normalize_path(root)
  if not root:match("/$") then
    root = root .. "/"
  end

  -- Check for Unity lock files that indicate compilation
  local lock_files = {
    root .. "Library/ScriptAssemblies/BuiltInAssemblies.stamp",
    root .. "Library/SourceAssetDB.lock",
  }

  for _, lock_file in ipairs(lock_files) do
    local stat = uv.fs_stat(lock_file)
    if stat then
      return true
    end
  end

  return false
end

return M
