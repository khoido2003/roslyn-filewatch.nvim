# Changelog

All notable changes to roslyn-filewatch.nvim will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.4.0] - 2026-02-07

### ⚠️ BREAKING CHANGES
- **Streamlined Scope**: Removed all non-file-watching features to focus on core performance and stability.
  - Removed **Dotnet CLI** commands (`:RoslynBuild`, `:RoslynRun`, etc.) and module.
  - Removed **NuGet** commands (`:RoslynNuget`, `:RoslynRestore`) and module.
  - Removed **Solution Explorer** (`:RoslynExplorer`) and module.
  - Removed **Game Engine Context** (`game_context.lua`) mechanics (presets for performance still exist).
  - Removed **Project Warmup** module.
- **Configuration**: Removed `enable_dotnet_commands` and `enable_nuget_commands` options.

### Added
- **Dynamic Debounce**: "Smart" latency control.
  - **Instant (~50ms)** detection for single file edits.
  - **Efficient (~1000ms)** batching for mass changes (Unity regeneration, git checkout).
- **Recovery System**:
  - **Self-Healing**: Automatically detects and restarts frozen watchers.
  - **Exponential Backoff**: Prevents restart loops during persistent failures.
  - **Status Checks**: `:checkhealth` now tracks recovery stats and notification throughput.
- **Recovery Config**: New options (`recovery_verify_enabled`, `recovery_max_retries`) to tune resilience.

### Optimized
- **Async Startup**: `.sln`/`.slnx` parsing is now fully asynchronous, unblocking the UI during startup.
- **Parallel Scanning**: Initial file scan uses parallel `fs_stat` batches, drastically reducing load time for large projects.
- **Reduced Bloat**: Cleaned up ~15 commands and related files to lower memory footprint and maintenance surface.

### Migration Guide
If you rely on the removed CLI/Explorer features, you can pin your plugin version to v0.3.9:
```lua
{ "khoido2003/roslyn-filewatch.nvim", tag = "v0.3.9" }
```

## [v0.3.9] - 2026-02-07

### Fixed
- **Duplicate Restores**
  - Fixed an issue where opening buffers (even existing files) would trigger `dotnet restore` multiple times.
  - Improved `ensure_in_snapshot` logic to ignore "new file" logic for existing files (older than 60s).
  - Deduplicated startup logic to prevent double `project/open` notifications.

### Added
- **Performance: `fd` Integration**
  - Integrated support for `sharkdp/fd` for significantly faster project scanning (up to 10x faster on large projects).
  - Automatically detects if `fd` (or `fdfind` on Linux) is installed and uses it.
  - Falls back to standard Lua-based scanning if not found.
- **Health Checks**
  - Added Linux system limit check for `fs.inotify.max_user_watches` to prevent silent watcher failures.
  - Added detection for external tools (`fd`).

### Optimized
- **Bulk File Operations**
  - Implemented caching for `.csproj` discovery in `notify.lua`.
  - Prevents redundant filesystem scans when creating/modifying many files at once (e.g., during `git checkout` or massive refactors).
  - Greatly improved responsiveness during bulk operations.

## [v0.3.8] - 2026-02-06

### Fixed
- **CRITICAL: Fix for Moved/Renamed Files detection**
  - Fixed issue where moving or renaming C# files was not ignored by the LSP
  - Implemented proper handle for file moves utilizing `fs_event` renames
  - Automatically triggers `.csproj` updates when source files are moved or renamed (updates both source and destination projects)
- **CRITICAL: Fix for New/Deleted Files in Godot/C# Projects**
  - Fixed issue where created/deleted files were not recognized by Roslyn LSP
  - Now automatically sends `.csproj` change events (type=2) whenever a source file (`.cs`/`.vb`/`.fs`) is created or deleted
  - This forces Roslyn to reload the project context and recognize the file changes
- **Project Reload Logic**
  - Enhanced `project/open` logic to support both **Solution-based** and **CSPROJ-only** projects
  - Added debounce (500ms) to project reload notifications to prevent spam during bulk operations
  - Ensures correct project context even when files are created externally (outside Neovim)

### Improved
- **Robustness**: Extracted csproj-finding logic into a reusable helper to ensure consistent behavior across all file events (create, delete, move, rename)

## [v0.3.7] - 2026-01-27

### Removed
- **Snippet Support**: Removed built-in snippet management (`snippets.lua`, commands, and config) to reduce bloat. Users are encouraged to use dedicated snippet plugins (like FriendlySnippets) instead.

### Fixed
- **Watcher Logic**: Fixed `last_events` tracking to prevent nil errors.
- **Restore Module**: Fixed syntax error in `restore.lua`.
- **Watchdog Stability**: Added check for client existence before attempting cleanup.
- **CRITICAL: New files in new folders not detected in Unity projects**
  - Fixed issue where creating a new folder with a new file inside was not detected by LSP
  - Root cause: `check_sln_changed` and `on_sln_changed` deps were defined in `fs_poll.lua` but never wired up in `watcher.lua`
  - When solution file (`.slnx`/`.sln`/`.slnf`) changes, the poller now properly:
    - Clears the snapshot to force a full rescan
    - Rescans for new csproj files
    - Sends `project/open` notifications for new projects
    - Triggers diagnostics refresh
- **CRITICAL: Fix "All Buffers Deleted" Bug**
  - Properly detects when all buffers are closed and resets project state
  - Ensures opening a new file after `bufdo bd!` correctly triggers `project/open`
- **Fix LspDetach State Clearing** 
  - `LspDetach` handler no longer wipes project info on every buffer close
  - Full cleanup only happens when the LSP client actually stops
- **New File Detection**
  - Newly created .cs files in csproj-only projects now ALWAYS trigger `dotnet restore` and `project/open`
  - Bypasses the one-time project load flag for new source files

### Improved
- **Enhanced Resync Command**
  - `:RoslynFilewatchResync` now actually does something useful:
    - Clears project tracking state
    - Sends `project/open` notifications to LSP
    - Triggers `dotnet restore` (if enabled)
    - Refreshes diagnostics

## [v0.3.5] - 2026-01-24

### Fixed
- **CRITICAL: csproj-only projects now work correctly**
  - Fixed issue where projects without `.sln`/`.slnx` files were not properly watched
  - New files created in csproj-only projects are now immediately recognized by the LSP
  - Fixed `scan_csproj_async()` to scan recursively (was only scanning root directory)
  - Fixed `get_watch_dirs()` to always return `nil` for csproj-only projects, triggering full recursive scan
  - Ensured full recursive file watching for csproj-only projects (not limited to csproj directories)

### Added
- **Automatic project reload for csproj-only projects**
  - Sends `project/open` notifications immediately when new source files are created or opened
  - Sends csproj CHANGE events to trigger Roslyn project reload (same behavior as opening old files)
  - Automatically triggers restore and project reload after restore completes
  - Debounced notifications (500ms) to batch multiple file creations and prevent constant restores
  - Proper callback mechanism in restore module to notify when restore completes

### Improved
- **Performance optimizations for csproj-only projects**
  - Debounced csproj reload notifications (500ms) to reduce lag and batch file creations
  - Single restore per batch of file creations (not per csproj file)
  - Proper cleanup of debounce timers when clients stop (prevents memory leaks)
  - Reduced duplicate notifications by tracking pending reloads
  - Optimized restore callback system to handle multiple concurrent restores

## [v0.3.4] - 2026-01-22

### Added
- **Auto-Restore for NuGet Packages**: Automatically runs `dotnet restore` when `.csproj` files are modified.
  - **Zero Lag**: Implemented with a sequential Job Queue to prevent CPU spikes ("Thundering Herd") during Unity project regeneration.
  - **Smart Notifications**: Aggregates status updates to prevent spam (one "Start" and one "End" notification per batch).
  - **Opt-in**: Enable via `enable_autorestore = true` in config (default: `false`).
  - **Robustness**: Detects changes from any source (Unity, Git, Manual edits) in both solution and CSPROJ modes.

## [v0.3.3] - 2026-01-21

### Added
- **Feature Toggles**: New configuration options to enable/disable features (all disabled by default):
  - `enable_dotnet_commands` (default: `false`)
  - `enable_nuget_commands` (default: `false`)
  - `enable_snippets` (default: `false`)

## [v0.3.2] - 2026-01-18

### Added - C# Dev Kit-Like Features

- **Project Warm-up** (`project_warmup.lua`)
  - Sends `workspace/projectInitializationComplete` notification to speed up Roslyn initialization
  - Lightweight implementation that doesn't block UI

- **Game Engine Context** (`game_context.lua`)
  - Auto-detects Unity, Godot, Stride, MonoGame, FNA game engines
  - Applies engine-specific Roslyn Analyzer settings

- **Unity Integration** (`game_engines/unity.lua`)
  - Parses Assembly Definition files (`.asmdef`) for better project structure
  - Auto-configures Unity Roslyn Analyzer rules (UNT0001-UNT0014)

- **Godot Integration** (`game_engines/godot.lua`)
  - Parses `project.godot` for project settings
  - Applies Godot naming convention hints

- **Dotnet CLI Integration** (`dotnet_cli.lua`)
  - Build, run, clean, and watch commands
  - NuGet package management (add, remove, restore)
  - Project creation and solution management

- **Code Snippets** (`snippets.lua`)
  - Unity snippets: `mono`, `start`, `update`, `serialize`, `coroutine`, `singleton`
  - Godot snippets: `node`, `ready`, `process`, `export`, `signal`
  - ASP.NET snippets: `controller`, `action`, `minimal`
  - General C#: `prop`, `ctor`, `class`, `async`, `try`, `foreach`
  - LuaSnip integration

### New Commands

| Command | Description |
|---------|-------------|
| `:RoslynBuild [config]` | Build solution/project |
| `:RoslynRun [config]` | Run project |
| `:RoslynWatch` | Run with hot reload |
| `:RoslynClean` | Clean build outputs |
| `:RoslynRestore` | Restore NuGet packages |
| `:RoslynNuget <package>` | Add NuGet package |
| `:RoslynNugetRemove <package>` | Remove NuGet package |
| `:RoslynNewProject <template> [name]` | Create new project |
| `:RoslynTemplates` | List available templates |
| `:RoslynOpenCsproj` | Open nearest .csproj |
| `:RoslynOpenSln` | Open solution file |
| `:RoslynSnippets` | Show available snippets |
| `:RoslynLoadSnippets` | Load snippets into LuaSnip |
| `:RoslynEngineInfo` | Show game engine info |

---

## [v0.3.1] - 2026-01-17

### Fixed
- **RoslynExplorer/RoslynFiles Commands**: Fixed commands failing when Roslyn LSP is still loading
  - Added fallback project root detection from current working directory  
  - Commands now work even before LSP attaches by searching for `.sln`/`.csproj` files
  - Improved error messages to help users understand project detection

- **CRITICAL: Explorer Performance**: Completely rewrote explorer to prevent freezing
  - **Lazy Loading**: Projects display instantly (no file scanning until needed)
  - **Async File Scanning**: Files load in background with chunked processing
  - **No UI Blocking**: Large projects (Unity, Godot) no longer freeze Neovim
  - Each project's files are only scanned when user selects that project

### Added
- **Game Engine Presets**: Full C# game development support with optimized settings
  - `godot` - Godot 4.x C# projects (detects `project.godot` and `.godot` folder)
  - `stride` - Stride engine projects (detects `.sdpkg` package files)
  - `monogame` - MonoGame framework (detects `Content.mgcb` pipeline)
  - `fna` - FNA framework (detects `fnalibs` folder)
  
- **Improved Auto-Detection**: Presets system now detects all major C# game engines automatically

### Changed
- **Unity Preset Overhaul**: More aggressive settings to prevent any freezing during index rebuilds
  - `poll_interval`: 10s → 15s
  - `batching.interval`: 500ms → 800ms
  - `processing_debounce_ms`: 300ms → 500ms
  - `activity_quiet_period`: 10s → 15s
  - `diagnostic_throttling.debounce_ms`: 1000ms → 1500ms
  - Added more ignore dirs: `PackageCache`, `il2cpp_cache`, platform folders
- Extended default `client_names` to include `roslyn_lsp` variant
- Preset detection runs in priority order: Unity → Godot → Stride → FNA → MonoGame → Large → Console

---

## [v0.3.0] - 2026-01-17

### Added
- **Deferred Project Loading**  
  - New `deferred_loading` option delays `project/open` until the user opens a `.cs` file  
  - Optional `deferred_loading_delay_ms` controls delay before first project load  
  - Reduces startup time for large solutions and Unity projects

- **Solution Explorer**  
  - New `:RoslynExplorer` command provides a solution/project/file picker  
  - Telescope integration when available, fallback to `vim.ui.select`  
  - Hierarchical navigation: Solution → Projects → Files

- **Unity-Optimized Presets**  
  - New presets module with `"unity"` and `"console"` configurations  
  - `"auto"` preset detection based on project type  
  - Unity preset increases `activity_quiet_period`, batching interval, polling interval, and adds Unity-specific ignored directories

- **Project Reload Command**  
  - New `:RoslynReload` command to force Roslyn to reload all tracked `.csproj` files  
  - Sends fresh `project/open` messages without restarting the LSP client

- **Diagnostic Throttling**  
  - New `diagnostic_throttling` config block  
  - Debounces diagnostic requests and restricts updates to visible buffers  
  - Automatically throttles diagnostics during heavy file activity or Unity regeneration

### Changed
- Updated `config.lua`, `watcher.lua`, and `init.lua` to integrate deferred loading, presets, diagnostic throttling, and new commands
- Watcher now respects throttling state when dispatching file-change events
- Unified project reload and deferred load logic under shared notification pathways

### New Files
- `explorer.lua` — Solution explorer implementation with Telescope support  
- `presets.lua` — Unity/console presets and auto-detection logic  
- `diagnostics.lua` — Diagnostic request debouncing and throttling

---

## [v0.2.4] - 2026-01-16

### Fixed
- **Critical Performance Fix**: Eliminated all UI freezes during Unity index file regeneration
- **Async Tree Scanning**: Full tree scans use chunked processing with `vim.defer_fn`, yielding every ~30 files
- **Async Event Flushing**: `fs_event` file changes use async `uv.fs_stat` with callbacks and chunked processing
- **Async CSPROJ Scanning**: All `vim.fn.glob()` calls replaced with async `uv.fs_scandir` (watcher.lua, autocmds.lua)
- **Enhanced Activity Throttling**: Increased quiet period from 2s to 5s (configurable)

### Added
- **`activity_quiet_period`**: New config option to control seconds of quiet time before full scans (default: 5)
- **`scan_tree_async()`**: Async scanning function in `snapshot.lua` that prevents UI blocking
- **`scan_csproj_async()`**: Async csproj discovery function in `watcher.lua`
- **`is_scanning()`**: Function to check if async scan is in progress (prevents duplicates)

### Changed
- **Event Processing Debounce**: Increased from 50ms to 150ms to coalesce more events during heavy activity
- **100% Async I/O**: All file system operations in hot paths now use async callbacks
- Full scans now prefer async mode with callback-based processing
- Poller skips cycles when async scan is in progress

---

## [v0.2.3] - 2026-01-16

### Fixed
- **Performance**: Fixed massive lag/freeze when solution files (`.slnx`/`.sln`) change by implementing smart delta updates (only reloading new/modified projects).
- **Detection**: Fixed issue where adding new files to existing projects (e.g. Unity `.asmdef` assemblies) was ignored by the watcher.

### Changed
- **VS Code-like Performance**: Async solution file checking, activity-based throttling, and longer poll intervals for smooth Unity workflows.
- **Poll Interval**: Default increased from 3s to 5s for lighter CPU load.
- **Batching Interval**: Increased from 150ms to 300ms for better event coalescing.
- **Unity Ignore Dirs**: Added more Unity-specific directories to ignore list (ScriptAssemblies, ShaderCache, etc.).
---

## [v0.2.2] - 2026-01-08

### Added
- **`.slnx` support**: Parse XML-based solution files (Visual Studio 2022 17.13+, .NET 9)
- **`.slnf` support**: Parse solution filter files (JSON format) with highest priority
- Unity-style project detection: automatically triggers full scan when all projects are at root level
- **`ignore_patterns`**: New config option for gitignore-style glob exclusions (like VS Code's `files.watcherExclude`)
- **Missing project hint**: `:RoslynFilewatchStatus` now warns when no `.sln`/`.csproj` found and suggests `dotnet new console` or `dotnet restore`
- **Colored status output**: `:RoslynFilewatchStatus` now uses syntax highlighting for better readability
- **`:RoslynFilewatchResync` command**: Force resync file watcher snapshots for debugging/recovery
- **Updated vimdoc**: Complete `:help roslyn-filewatch` documentation with all commands and config options

### Fixed
- Unity projects with `.slnx` files now properly detect and watch all `.cs` files in subdirectories
- Projects where all `.csproj` files are in root (like Unity) now trigger full recursive scan
- Memory leak: `dirty_dirs` and `needs_full_scan` tables not cleaned up on client disconnect
- LspDetach autocmd now properly removes itself only after the correct client detaches

### Changed
- Solution detection priority is now: `.slnf` > `.slnx` > `.sln` (filter first, then newer format)
- Updated health check and documentation to reflect all three solution formats

---

## [0.2.1] - 2026-01-07

### Fixed
- Improved solution/project file parsing for the Roslyn file watcher

---

## [0.2.0] - 2026-01-01

### Added
- **Solution-Aware Watching**: Parse `.sln` files to limit watch scope to project directories only
- **Gitignore Support**: Automatic `.gitignore` pattern matching with caching
- **Incremental Scanning**: Partial scan using `dirty_dirs` instead of full tree scans
- **Status Command**: New `:RoslynFilewatchStatus` command for debugging
- **Rename Detection**: Detects file renames by matching file identity (inode/dev)
- Full LuaLS type annotations throughout the codebase

### Fixed
- Non-`.sln` projects (e.g., `dotnet new console`) now work correctly
- Autocmd scoping - unique group per client prevents cross-client triggering
- Restart race conditions with proper scheduling guards
- `fs_poll` logic for incremental vs full scans
- `ignore_dirs` pattern matching
- New files created in Neovim immediately detected by LSP
- Added `.csproj` notification when new `.cs` files are created

### Changed
- `restart_watcher` is now lightweight - only recreates fs_event handle, preserves snapshot
- Reduced batching interval: 300ms → 150ms
- Reduced debounce: 80ms → 50ms
- Reduced rename detection window: 300ms → 200ms
- Removed ~200+ lines of dead/unused code

### Improved
- Enabled `uv.fs_event` on Windows (previously polling-only)
- Case-insensitive path comparisons on Windows
- Fixed 30-60 second freezes on file operations from external editors (Unity)

---

## [0.1.4] - 2025-09-15

### Added
- `cleanup_client()` utility for consistent handle/timer cleanup

### Fixed
- Windows EPERM error loop that could crash Neovim
- Watchdog no longer enters infinite restart loop in poller-only mode
- Duplicate start prevention for same client
- Poller-only resilience without native fs_event

---

## [0.1.3] - 2025-09-08

### Added
- **Rename detection**: Detects Deleted+Created event pairs and emits proper `workspace/didRenameFiles` notifications
- Internal logging for rename detection (debug level)

### Improved
- Rename detection falls back safely to normal delete/create events if matching fails

---

## [0.1.2] - 2025-09-07

### Fixed
- "Changed" events only sent when both modification time AND size differ
- Prevents false change notifications from tools like Unity that update timestamps

### Changed
- Default batching interval increased to 300ms (was 100ms)

---

## [0.1.1] - 2025-09-03

### Added
- Safer buffer closing with double-check before closing buffers
- Path normalization for Windows/Unix separators
- Optional batching for `workspace/didChangeWatchedFiles`

### Fixed
- Avoid closing wrong buffer when another file is deleted
- Restart watcher when libuv returns `filename = nil` or error
- Robust autocmd cleanup to avoid type errors

### Improved
- Watcher stability and recovery with resync logic
- Safe fast-event handling with `vim.schedule`
