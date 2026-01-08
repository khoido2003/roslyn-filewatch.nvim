# Changelog

All notable changes to roslyn-filewatch.nvim will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`.slnx` support**: Parse XML-based solution files (Visual Studio 2022 17.13+, .NET 9)
- **`.slnf` support**: Parse solution filter files (JSON format) with highest priority
- Unity-style project detection: automatically triggers full scan when all projects are at root level

### Fixed
- Unity projects with `.slnx` files now properly detect and watch all `.cs` files in subdirectories
- Projects where all `.csproj` files are in root (like Unity) now trigger full recursive scan

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
