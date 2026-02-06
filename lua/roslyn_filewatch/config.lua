---@class roslyn_filewatch.config
---@field options roslyn_filewatch.Options
---@field setup fun(opts?: roslyn_filewatch.Options)

---@class roslyn_filewatch.Options
---@field batching? roslyn_filewatch.BatchingOptions
---@field ignore_dirs? string[] Directories to ignore (exact segment match)
---@field ignore_patterns? string[] Glob patterns to exclude (gitignore-style)
---@field watch_extensions? string[] File extensions to watch (with dots)
---@field client_names? string[] LSP client names to trigger watching
---@field poll_interval? number Poller interval in ms
---@field poller_restart_threshold? number Seconds threshold for poller restart
---@field watchdog_idle? number Seconds of idle before restarting watcher
---@field rename_detection_ms? number Window for rename detection
---@field processing_debounce_ms? number Debounce for processing events
---@field log_level? number vim.log.levels value
---@field force_polling? boolean Force polling mode (disable fs_event)
---@field solution_aware? boolean Parse .sln/.slnx/.slnf to limit watch scope (default: true)
---@field respect_gitignore? boolean Respect .gitignore patterns (default: true)
---@field activity_quiet_period? number Seconds of quiet before allowing scans (default: 5)
---@field preset? string Project preset: "auto", "unity", "console", "large", "none"
---@field deferred_loading? boolean Defer project/open until first C# file opened
---@field deferred_loading_delay_ms? number Delay before sending deferred project/open (default: 500)
---@field diagnostic_throttling? roslyn_filewatch.DiagnosticThrottlingOptions
---@field enable_dotnet_commands? boolean Enable dotnet CLI commands (default: false)
---@field enable_nuget_commands? boolean Enable NuGet commands (default: false)
---@field enable_snippets? boolean Enable snippets (default: false)

---@class roslyn_filewatch.BatchingOptions
---@field enabled? boolean Enable event batching
---@field interval? number Batch interval in ms

---@class roslyn_filewatch.DiagnosticThrottlingOptions
---@field enabled? boolean Enable diagnostic throttling (default: true)
---@field debounce_ms? number Debounce interval for diagnostics (default: 500)
---@field visible_only? boolean Only request diagnostics for visible buffers (default: true)

local M = {}

---@type roslyn_filewatch.Options
M.options = {
  batching = {
    enabled = true,
    interval = 300, -- coalesce events over 300ms
  },

  ignore_dirs = {
    -- Unity-specific
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
    "ScriptTemplates",
    "ProjectTemplates",
    "Recordings",
    -- Godot-specific
    ".godot",
    ".mono",
    ".import",
    "export",
    -- .NET / Build
    "Obj",
    "obj",
    "Bin",
    "bin",
    "Build",
    "Builds",
    "packages",
    "TestResults",
    -- General
    ".git",
    ".idea",
    ".vs",
    ".vscode",
    "node_modules",
  },

  --- Glob patterns to exclude files/directories (gitignore-style)
  --- Patterns are applied in order; later patterns can override earlier ones
  --- Use ! prefix to negate (include previously excluded files)
  --- Examples:
  ---   "*.generated.cs"    - exclude generated files
  ---   "**/*.Designer.cs"  - exclude designer files anywhere
  ---   "**/obj/**"         - exclude obj directory contents
  ---   "!**/important/**"  - but include important directory
  ignore_patterns = {},

  watch_extensions = {
    -- C# Code Files
    ".cs",
    ".csx", -- C# script files

    -- Visual Basic (VB.NET) Code Files
    ".vb", -- VB source files

    -- Project Files
    ".csproj",
    ".vbproj", -- VB project files

    -- Solution Files
    ".sln",
    ".slnx", -- XML solution files
    ".slnf", -- Solution filter files

    -- MSBuild Files
    ".props", -- MSBuild property files
    ".targets", -- MSBuild target files

    -- Configuration Files
    ".editorconfig",
    ".config", -- App.config, Web.config
    ".globalconfig", -- Global analyzer config
    ".ruleset", -- Code analysis rulesets

    -- Web Code Files (Blazor, Razor, ASP.NET)
    ".razor", -- Blazor components
    ".cshtml", -- Razor views

    -- XAML Files (WPF, MAUI, Avalonia, UWP)
    ".xaml", -- WPF/MAUI/UWP XAML
    ".axaml", -- Avalonia XAML

    -- Resource Files
    ".resx", -- .NET resource files

    -- Unity-specific Files
    ".asmdef", -- Assembly definitions
    ".asmref", -- Assembly references
    ".inputactions", -- Input System actions
    ".uxml", -- UI Toolkit layouts
    ".uss", -- UI Toolkit stylesheets
  },

  --- Which LSP client names should trigger watching
  --- C# LSP clients: Roslyn-based servers
  client_names = {
    "roslyn",
    "roslyn_ls",
    "roslyn_lsp",
  },

  --- Poller interval in ms (used for fallback resync scan)
  poll_interval = 5000, -- VS Code-like: poll less frequently for better performance

  --- If poller detects changes while fs_event was quiet for this many seconds,
  --- we restart the watcher (heals silent-death cases).
  poller_restart_threshold = 2,

  --- If absolutely no fs activity for this many seconds, restart watcher (safety).
  watchdog_idle = 60,

  --- Window (ms) used to detect renames by buffering deletes and matching by identity.
  rename_detection_ms = 200, -- Faster rename detection

  --- Debounce (ms) used to aggregate high-frequency fs events before processing.
  --- Higher values coalesce more events (better for Unity regeneration).
  processing_debounce_ms = 150,

  --- Logging level for plugin notifications (controls what gets passed to vim.notify).
  --- Default: WARN (show only warnings and errors). Set to vim.log.levels.INFO or DEBUG
  --- to get more verbose notifications.
  ---
  --- Valid values: vim.log.levels.TRACE, DEBUG, INFO, WARN, ERROR
  -- Example:
  --   require("roslyn_filewatch").setup({ log_level = vim.log.levels.ERROR })
  log_level = vim.log and vim.log.levels and vim.log.levels.WARN or 3,

  --- Force polling mode (disable fs_event entirely)
  --- Set to true if you experience issues with native file watching
  force_polling = false,

  --- Solution-aware watching: parse .sln/.slnx/.slnf files to limit watch scope
  --- to project directories only. Reduces I/O on large repositories.
  --- When enabled, the plugin will:
  ---   1. First look for .slnf (filter), .slnx (XML), or .sln files and parse project directories
  ---   2. If no solution found, fall back to scanning for .csproj files
  ---   3. If neither found, perform a full directory scan
  --- This makes it work well for both solution-based and simple csproj-only projects.
  solution_aware = true,

  --- Respect .gitignore patterns when scanning files.
  --- Automatically skips files matching .gitignore rules.
  respect_gitignore = true,

  --- Seconds of quiet time required after last file event before triggering scans.
  --- Higher values prevent freezes during heavy file operations (Unity regeneration).
  --- Default: 5 seconds (Unity regeneration can take 5-30+ seconds)
  activity_quiet_period = 5,

  --- Project preset for optimized settings based on project type.
  --- "auto" = auto-detect (Unity, large, console)
  --- "unity" = optimized for Unity projects (longer delays, more batching)
  --- "console" = optimized for small projects (faster, more responsive)
  --- "large" = balanced for large non-Unity solutions
  --- "none" = use only explicit settings
  preset = "auto",

  --- Defer project/open notifications until first C# file is opened.
  --- Helps reduce startup time for large solutions.
  deferred_loading = false,

  --- Delay (ms) before sending deferred project/open notification
  deferred_loading_delay_ms = 500,

  --- Diagnostic throttling options to reduce LSP load during heavy editing
  diagnostic_throttling = {
    enabled = true,
    debounce_ms = 500, -- Debounce diagnostics by 500ms
    visible_only = true, -- Only request diagnostics for visible buffers
  },

  --- Enable dotnet CLI commands (build, run, watch, etc.)
  enable_dotnet_commands = false,

  --- Enable NuGet commands (restore, add, remove)
  enable_nuget_commands = false,

  --- Enable auto-restore of NuGet packages on .csproj change (default: true)
  enable_autorestore = true,

  --- Regeneration detection: automatically pause event processing during heavy file generation
  --- (Unity asset imports, Godot project regeneration, etc.)
  regen_detection_enabled = true,

  --- Number of events within burst window to trigger regeneration mode
  regen_burst_threshold = 30,

  --- Time window (ms) for burst detection
  regen_burst_window_ms = 500,

  --- Quiet time (ms) before exiting regeneration mode
  regen_quiet_period_ms = 2000,

  --- Maximum regeneration mode duration (ms) - safety lim it
  regen_max_duration_ms = 60000,

  --- Maximum events per batch sent to Roslyn LSP (prevents server overload)
  max_events_per_batch = 100,
}

-- Track detected root for preset application
M._detected_root = nil

--- Setup the configuration with user options
---@param opts? roslyn_filewatch.Options
function M.setup(opts)
  -- First merge user options with defaults
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})

  -- Build cached lookup sets for O(1) performance
  M._rebuild_cache()
end

--- Apply preset based on root directory (called when client starts)
---@param root string Root directory for preset detection
function M.apply_preset_for_root(root)
  if not root then
    return
  end

  M._detected_root = root

  local preset_name = M.options.preset or "auto"
  if preset_name == "none" then
    return
  end

  local ok, presets = pcall(require, "roslyn_filewatch.presets")
  if not ok or not presets then
    return
  end

  -- Apply preset and merge with current options
  M.options = presets.apply(preset_name, M.options, root)

  -- Rebuild cache after preset application
  M._rebuild_cache()
end

--- Rebuild internal caches (call after modifying options directly)
function M._rebuild_cache()
  -- Build extension lookup set (lowercase for case-insensitive matching)
  local ext_set = {}
  for _, ext in ipairs(M.options.watch_extensions or {}) do
    ext_set[ext:lower()] = true
  end
  M._watch_ext_set = ext_set

  -- Build ignore dirs lookup set (lowercase for case-insensitive matching)
  local ignore_set = {}
  for _, dir in ipairs(M.options.ignore_dirs or {}) do
    ignore_set[dir:lower()] = true
  end
  M._ignore_dirs_set = ignore_set
end

--- Check if an extension should be watched (O(1) lookup)
---@param ext string Extension with dot (e.g., ".cs")
---@return boolean
function M.is_watched_extension(ext)
  if not ext then
    return false
  end
  -- Lazy build cache if not built yet
  if not M._watch_ext_set then
    M._rebuild_cache()
  end
  return M._watch_ext_set[ext:lower()] == true
end

--- Check if a directory name should be ignored (O(1) lookup)
---@param dir_name string Directory name
---@return boolean
function M.is_ignored_dir(dir_name)
  if not dir_name then
    return false
  end
  -- Lazy build cache if not built yet
  if not M._ignore_dirs_set then
    M._rebuild_cache()
  end
  return M._ignore_dirs_set[dir_name:lower()] == true
end

return M
