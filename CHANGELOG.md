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

## [0.2.2] - 2026-01-08

### Added
- Initial release
- Native file watching with `fs_event` (inotify/FSEvents/ReadDirectoryChangesW)
- Polling fallback for reliability
- Solution-aware watching: parses `.sln` files to limit watch scope
- `.gitignore` support
- Rename detection for proper file move notifications
- Event batching for VS Code-like performance
- Watchdog for automatic recovery from stale watchers
- Buffer management for deleted files
- `:RoslynFilewatchStatus` command for diagnostics
- `:checkhealth roslyn_filewatch` integration

### Supported Extensions
- `.cs`, `.csproj`, `.sln`, `.slnx`, `.slnf`
- `.props`, `.targets`, `.editorconfig`
- `.razor`, `.config`, `.json`

### Supported LSP Clients
- `roslyn` (Roslyn LSP)
- `roslyn_ls` (Roslyn Language Server)
