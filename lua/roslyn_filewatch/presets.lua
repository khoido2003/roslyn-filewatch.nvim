---@class roslyn_filewatch.presets

local M = {}

local uv = vim.uv or vim.loop

---@type table<string, roslyn_filewatch.Options>
M.presets = {
  unity = {
    batching = { enabled = true, interval = 800 },
    activity_quiet_period = 15,
    poll_interval = 15000,
    processing_debounce_ms = 500,
    watchdog_idle = 120,
    ignore_dirs = {
      "Library",
      "Temp",
      "Logs",
      "UserSettings",
      "MemoryCaptures",
      "CrashReports",
      "ScriptAssemblies",
      "bee_backend",
      "StateCache",
      "ShaderCache",
      "AssetBundleCache",
      "Recorder",
      "TextMesh Pro",
      "Plugins",
      "StreamingAssets",
      "PackageCache",
      "il2cpp_cache",
      "AndroidPlayer",
      "iOSPlayer",
      "WebGLPlayer",
      "ScriptTemplates",
      "ProjectTemplates",
      "Recordings",
      "Obj",
      "obj",
      "Bin",
      "bin",
      "Build",
      "Builds",
      "packages",
      "TestResults",
      ".git",
      ".idea",
      ".vs",
      ".vscode",
      "node_modules",
    },
    deferred_loading = true,
    deferred_loading_delay_ms = 2000,
    diagnostic_throttling = { enabled = true, debounce_ms = 1500, visible_only = true },
  },

  console = {
    batching = { enabled = true, interval = 200 },
    activity_quiet_period = 3,
    poll_interval = 3000,
    processing_debounce_ms = 100,
    deferred_loading = false,
    diagnostic_throttling = { enabled = true, debounce_ms = 300, visible_only = false },
  },

  large = {
    batching = { enabled = true, interval = 1000 },
    activity_quiet_period = 10,
    poll_interval = 10000,
    processing_debounce_ms = 300,
    deferred_loading = true,
    deferred_loading_delay_ms = 1000,
    diagnostic_throttling = { enabled = true, debounce_ms = 500, visible_only = true },
  },

  godot = {
    batching = { enabled = true, interval = 350 },
    activity_quiet_period = 5,
    poll_interval = 5000,
    processing_debounce_ms = 150,
    ignore_dirs = {
      ".godot",
      ".import",
      "addons",
      ".mono",
      "export",
      "android",
      "Obj",
      "obj",
      "Bin",
      "bin",
      "Build",
      "Builds",
      "packages",
      "TestResults",
      ".git",
      ".idea",
      ".vs",
      ".vscode",
      "node_modules",
    },
    deferred_loading = false,
    diagnostic_throttling = { enabled = true, debounce_ms = 400, visible_only = true },
  },

  stride = {
    batching = { enabled = true, interval = 450 },
    activity_quiet_period = 8,
    poll_interval = 8000,
    processing_debounce_ms = 200,
    ignore_dirs = {
      ".vs",
      "Bin",
      "bin",
      "obj",
      "Obj",
      "Cache",
      "cache",
      "Intermediate",
      "log",
      "logs",
      "Logs",
      ".git",
      ".idea",
      ".vscode",
      "node_modules",
      "packages",
    },
    deferred_loading = true,
    deferred_loading_delay_ms = 500,
    diagnostic_throttling = { enabled = true, debounce_ms = 600, visible_only = true },
  },

  monogame = {
    batching = { enabled = true, interval = 300 },
    activity_quiet_period = 5,
    poll_interval = 5000,
    processing_debounce_ms = 150,
    ignore_dirs = {
      "Content",
      "bin",
      "obj",
      "Bin",
      "Obj",
      ".git",
      ".idea",
      ".vs",
      ".vscode",
      "node_modules",
      "packages",
    },
    deferred_loading = false,
    diagnostic_throttling = { enabled = true, debounce_ms = 400, visible_only = true },
  },

  fna = {
    batching = { enabled = true, interval = 300 },
    activity_quiet_period = 5,
    poll_interval = 5000,
    processing_debounce_ms = 150,
    ignore_dirs = {
      "fnalibs",
      "FNALibs",
      "Content",
      "bin",
      "obj",
      "Bin",
      "Obj",
      ".git",
      ".idea",
      ".vs",
      ".vscode",
      "node_modules",
      "packages",
    },
    deferred_loading = false,
    diagnostic_throttling = { enabled = true, debounce_ms = 400, visible_only = true },
  },
}

function M.detect(root)
  if not root then
    return nil
  end

  if not root:match("[/\\]$") then
    root = root .. "/"
  end

  -- Unity: check for Assets + ProjectSettings (fast sync stat - single file check)
  local assets_stat = uv.fs_stat(root .. "Assets")
  local projsettings_stat = uv.fs_stat(root .. "ProjectSettings")
  if
    assets_stat
    and assets_stat.type == "directory"
    and projsettings_stat
    and projsettings_stat.type == "directory"
  then
    return "unity"
  end

  -- Godot: check for project.godot or .godot folder
  local godot_file = uv.fs_stat(root .. "project.godot")
  if godot_file then
    return "godot"
  end
  local godot_dir = uv.fs_stat(root .. ".godot")
  if godot_dir and godot_dir.type == "directory" then
    return "godot"
  end

  -- Quick root-level scan for other markers (single scandir call)
  local fd = uv.fs_scandir(root)
  if not fd then
    return "console"
  end

  local has_sln = false
  local csproj_count = 0
  local has_sdpkg = false
  local has_content_mgcb = false
  local has_fnalibs = false

  while true do
    local name, typ = uv.fs_scandir_next(fd)
    if not name then
      break
    end
    if typ == "file" then
      if name:match("%.slnx?$") or name:match("%.sln$") then
        has_sln = true
      elseif name:match("%.csproj$") then
        csproj_count = csproj_count + 1
      elseif name:match("%.sdpkg$") then
        has_sdpkg = true
      elseif name:match("%.mgcb$") or name == "Content.mgcb" then
        has_content_mgcb = true
      end
    elseif typ == "directory" then
      if name == "fnalibs" or name == "FNALibs" then
        has_fnalibs = true
      end
    end
  end

  if has_sdpkg then
    return "stride"
  end

  if has_fnalibs then
    return "fna"
  end

  if has_content_mgcb then
    return "monogame"
  end

  -- Large project: has .sln and many csproj files
  -- NO sync file reading - just use csproj count from scandir
  if has_sln and csproj_count > 10 then
    return "large"
  end

  if csproj_count <= 3 then
    return "console"
  end

  return nil
end

function M.get(preset_name)
  return M.presets[preset_name]
end

function M.apply(preset_name, options, root)
  if preset_name == "none" then
    return options
  end

  local actual_preset = preset_name
  if preset_name == "auto" and root then
    actual_preset = M.detect(root) or "console"
  end

  local preset_opts = M.get(actual_preset)
  if not preset_opts then
    return options
  end

  local result = vim.tbl_deep_extend("force", preset_opts, options)
  result._applied_preset = actual_preset

  return result
end

function M.list()
  local names = { "auto", "none" }
  for name in pairs(M.presets) do
    table.insert(names, name)
  end
  return names
end

return M
