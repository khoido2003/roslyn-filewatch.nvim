# roslyn-filewatch.nvim

A lightweight, **file-watching and project-sync plugin** for Neovim that keeps the **Roslyn LSP** up-to-date with file changes.

Now with built-in **Dotnet CLI integration**, **Game Engine support**, and **Snippet** management.

---

## ⚡ Why?

Roslyn does not watch your project files by default in Neovim/Linux/Mac. Without this, you often need to `:edit!` or restart the LSP to make Roslyn notice file creation, deletion, renaming, or solution changes.

This plugin adds a robust **cross-platform file watcher** and a suite of tools to make C# development in Neovim feel like a full IDE.

---

## ✨ Features

### 🗂️ Robust File Watching
- **Cross-Platform**: Uses `uv.fs_event` (native) with `uv.fs_poll` (fallback) for reliability on Windows/Linux/macOS.
- **Smart Detection**: Handles create, delete, change, and **detects renames** (merging delete+create pairs).
- **Optimization**: Batches events, throttles diagnostics, and avoids watching ignored files (ignores `.git`, `bin`, `obj`, etc.).
- **Solution-Aware**: Parses `.sln`, `.slnx`, or `.slnf` files to strictly limit watching to relevant project folders.

### 🚀 Performance & Smart Loading
- **Deferred Loading**: Delays project loading until you actually open a C# file to speed up startup for large solutions.
- **Project Warm-up**: Sends initialization notifications to get Roslyn ready without blocking the UI.
- **Diagnostic Throttling**: Prevents UI lag by smoothing out diagnostic updates during heavy operations (like git checkout).

### 🎮 Game Engine Support
First-class support for **C# Game Development**.  
Automatically detects the engine and applies optimized presets (scan intervals, ignore patterns):
- **Unity**: Parses `.asmdef`, configures analyzers, handles meta files.
- **Godot**: Handles `project.godot` and `.godot/`.
- **Stride**, **MonoGame**, **FNA**: Preset configurations included.

### 🛠️ Integrated Tooling (Opt-in)
Enable these features in your config to get a full C# IDE experience:
- **Dotnet CLI**: Build, Run, Watch, Clean, and create Projects directly from Neovim.
- **NuGet**: Manage packages (Add/Remove/Restore) interactively.
- **Snippets**: A collection of 150+ snippets for Unity, Godot, and ASP.NET (requires LuaSnip).
- **Solution Explorer**: A tree-view picker to navigate your solution (`:RoslynExplorer`).

---

## 🔌 Requirements

- **Neovim 0.10+** (Required for `vim.fs` and modern Lua APIs)
- An existing Roslyn LSP client, such as:
  - [roslyn.nvim](https://github.com/seblyng/roslyn.nvim) (**Highly recommended**)
  - [nvim-lspconfig (roslyn_ls)](https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md#roslyn_ls)

---

## 📦 Installation

### lazy.nvim
```lua
{
  "khoido2003/roslyn-filewatch.nvim",
  config = true, -- calls require('roslyn_filewatch').setup()
}
```

### packer.nvim
```lua
use {
  "khoido2003/roslyn-filewatch.nvim",
  config = function()
    require("roslyn_filewatch").setup()
  end,
}
```

---

## 📘 User Manual

This section covers how to configure and use the plugin effectively in your daily workflow.

### 1. Configuration

The defaults are sane, but the following settings are commonly adjusted:

```lua
require("roslyn_filewatch").setup({
  -- === The Essentials ===
  -- The plugin hooks into these LSP client names. 
  -- If you use nvim-lspconfig, add "roslyn_ls" here.
  client_names = { "roslyn_ls", "roslyn", "roslyn_lsp" },
  
  -- === Optimization ===
  -- "deferred_loading": If true, project loading is deferred until a 
  -- .cs file is opened. This improves startup time, but Intellisense 
  -- might take a second to wake up on the first file.
  deferred_loading = true,
  
  -- "diagnostic_throttling": During heavy git operations or branch switching, 
  -- Roslyn can spam diagnostics, lagging the UI. This throttles them.
  diagnostic_throttling = {
    enabled = true,
    debounce_ms = 150, -- Wait 150ms before asking for errors
    visible_only = true, -- Don't lint files hidden in background buffers
  },

  -- === File Watching Tweaks ===
  -- Directories to completely ignore. Adding folders here saves CPU.
  ignore_dirs = { "Library", "Temp", "Obj", "Bin", ".git", ".idea" },
  
  -- "solution_aware": If true, parses the .sln file and ONLY watches 
  -- the folders listed inside it. This improves performance on monorepos.
  solution_aware = true, 
  
  -- === Enabling IDE Features ===
  -- By default, only file watching is enabled. Toggle these for the full experience.
  enable_dotnet_commands = true, -- Adds :RoslynBuild, :RoslynRun, etc.
  enable_nuget_commands = true,  -- Adds :RoslynNuget, :RoslynRestore
  enable_snippets = true,        -- Adds :RoslynLoadSnippets
})
```

### 2. Common Workflows

#### **A. Starting a New Project**
1.  Run `:RoslynNewProject`.
2.  Select a template (e.g., `console`, `webapi`, `classlib`).
3.  Enter a name.
4.  The plugin creates the project folder and file.
5.  *(Optional)* Open it immediately with `:RoslynOpenCsproj`.

#### **B. Adding a Dependency**
Instead of switching to the terminal:
1.  Run `:RoslynNuget`.
2.  Type `Newtonsoft.Json`.
3.  The plugin finds the nearest `.csproj` and installs the package.
4.  Roslyn automatically picks up the reference because the file watcher sees the change.

#### **C. Working with Unity**
1.  Open your Unity project folder in Neovim.
2.  The plugin detects `Assets/` and `ProjectSettings/`.
3.  It automatically switches to the **Unity Preset**:
    *   Ignores `Library`, `Temp`, `Logs`.
    *   Increases debounce time (Unity likes to touch many files at once).
    *   Adds `UNT` analyzer rules to your LSP configuration.
4.  **Tip**: Use `:RoslynEngineInfo` to confirm Unity mode is active.

#### **D. Navigating Large Solutions**
1.  Run `:RoslynExplorer`.
2.  You see a tree view: `Solution` -> `Project A` -> `Folder` -> `File.cs`.
3.  Select a file to open.
4.  *Note*: This respects `.sln` structure, so it's cleaner than a raw file tree.

---

## 🧭 Command Reference

Most commands are **interactive**—if you run them without arguments, a selection menu will appear.

### 📂 Core (Always Available)
| Command | Usage | Description |
|---------|-------|-------------|
| `:RoslynExplorer` | `:RoslynExplorer` | Interactive Solution/Project explorer. |
| `:RoslynFiles` | `:RoslynFiles` | Fuzzy find C# files within the solution scope. |
| `:RoslynStatus` | `:RoslynStatus` | **Debug Tool**: Shows active watcher status, tracked projects, and health. |
| `:RoslynReload` | `:RoslynReload` | **Emergency Fix**: Forces Roslyn to reload all project files. Use if Intellisense breaks. |
| `:RoslynEngineInfo`| `:RoslynEngineInfo`| Shows detected game engine and active settings. |

### 🔨 Build & Run (`enable_dotnet_commands = true`)
| Command | Usage | Description |
|---------|-------|-------------|
| `:RoslynBuild` | `:RoslynBuild [Release/Debug]` | Builds the solution. |
| `:RoslynRun` | `:RoslynRun [ProjectName]` | Runs a project. Interactive if multiple executable projects exist. |
| `:RoslynWatch` | `:RoslynWatch` | Starts `dotnet watch` in a terminal buffer for Hot Reload. |
| `:RoslynClean` | `:RoslynClean` | Deletes `bin/` and `obj/` folders. |

### 📦 NuGet (`enable_nuget_commands = true`)
| Command | Usage | Description |
|---------|-------|-------------|
| `:RoslynNuget` | `:RoslynNuget [PackageName]` | Adds a NuGet package to the current project. |
| `:RoslynNugetRemove`| `:RoslynNugetRemove` | Shows a list of installed packages to remove. |
| `:RoslynRestore` | `:RoslynRestore` | Runs `dotnet restore` to download missing packages. |

---

## � Maintainer Guide

For developers contributing to `roslyn-filewatch.nvim`, this section details the architecture.

### 🗺️ The Code Map

*   `lua/roslyn_filewatch/`
    *   **Core Logic**:
        *   `init.lua`: The entry point. Handles setup and command registration.
        *   `watcher.lua`: The brain. Manages `uv.fs_event` handles and the polling loop.
        *   `snapshot.lua`: The memory. Maintains the state of the filesystem (`path -> {mtime, size, inode}`). Computes diffs.
        *   `config.lua`: Validation and default options.
    *   **Features**:
        *   `dotnet_cli.lua`: Wraps the `dotnet` binary. Handles messy job of parsing CLI output.
        *   `explorer.lua`: Implements the Tree View UI (using `vim.ui.select` or Telescope if available).
        *   `snippets.lua`: Definitions for Unity/Godot snippets.
    *   **Engine Support**:
        *   `presets.lua`: Registry of game engines.
        *   `game_engines/`: Individual logic for Unity, Godot, etc. detection.

### ⚙️ The Watch Cycle (How it actually works)

1.  **Startup**:
    *   `LspAttach` autocmd triggers `watcher.start()`.
    *   `snapshot.create()` scans the root dir recursively (respecting `.gitignore` and `ignore_dirs`).
    *   Initial state is stored.

2.  **Monitoring**:
    *   Attempts to attach a `uv.fs_event` to the root directory (recursive).
    *   **Windows Quirk**: `uv.fs_event` on Windows is recursive by default.
    *   **Linux/Mac Quirk**: `uv.fs_event` is NOT recursive. Falls back to `uv.fs_poll` or recursive watching (depending on implementation version).

3.  **The Event Loop**:
    *   **Event**: File system event fires (or poll interval ticks).
    *   **Debounce**: Waits `processing_debounce_ms` (default 150ms) to let bursts settle (e.g., `git checkout`).
    *   **Scan**: Scans the *affected path* (or full tree if path unknown).
    *   **Diff**: Compares new scan vs old snapshot.
        *   `Snapshot: nil`, `Disk: exists` -> **Created**
        *   `Snapshot: exists`, `Disk: nil` -> **Deleted**
        *   `Snapshot: mtime=X`, `Disk: mtime=Y` -> **Changed**
    *   **Rename Heuristic**:
        *   If `Delete(A)` and `Create(B)` occur in the same batch...
        *   AND `inode(A) == inode(B)` (if supported) OR `size(A) == size(B)`...
        *   The events are marked as **Renamed**.

4.  **Notification**:
    *   Changes are formatted into LSP `FileEvent` objects.
    *   `workspace/didChangeWatchedFiles` or `workspace/didRenameFiles` notifications are sent to Roslyn.

### ❓ Troubleshooting & Debugging

**"The watcher is not watching files"**
1.  Turn on debug logs: `setup({ log_level = vim.log.levels.DEBUG })`.
2.  Run `:messages`.
3.  Check `:RoslynStatus`.
    *   **Healthy**: "Watcher: Running (fs_event)"
    *   **Issue**: "Watcher: Polling (Fallback)" -> Might be slower.

**"It freezes when I change branch"**
1.  This means the dirty scan is taking too long.
2.  Increase `poll_interval` or `processing_debounce_ms`.
3.  Ensure `ignore_dirs` includes your build artifacts (`bin`, `obj`).

### ➕ How to add a new Game Engine

1.  **Create file**: `lua/roslyn_filewatch/game_engines/my_engine.lua`.
2.  **Implement**:
    ```lua
    local M = {}
    M.detect = function(root)
      return vim.fn.filereadable(root .. "/my_engine_config.json") == 1
    end
    M.get_config = function()
       return { ignore_dirs = { "EngineCache" } }
    end
    return M
    ```
3.  **Register**: Add it to `lua/roslyn_filewatch/presets.lua` in the `engine_check_order` list.

---

## ⚠️ Known Limitations

1.  **Massive Repositories (10k+ files)**
    *   **Issue**: Initial scan might cause a brief CPU spike.
    *   **Workaround**: `deferred_loading = true` is enabled by default to delay parsing until work begins.
    *   **Optimization**: Ensure your `ignore_dirs` list includes all build/cache folders (e.g., `dist`, `node_modules`).

2.  **Network Shares (NFS/SMB)**
    *   **Issue**: Native file watching (`fs_event`) is notoriously flaky on network drives.
    *   **Workaround**: The plugin attempts to fall back to polling, but latency will be higher.

3.  **Linux/BSD: "ENOSPC" Error**
    *   **Issue**: You might hit the system limit for file watchers.
    *   **Fix**: Increase `fs.inotify.max_user_watches` with `sysctl` (Standard Linux limitation).

4.  **External Changes (Git/Unity)**
    *   **Issue**: Mass changes from outside Neovim (like `git checkout` or Unity re-importing assets) triggers thousands of events.
    *   **Mitigation**: Automatically throttle these bursts using `processing_debounce_ms` and `activity_quiet_period`, so Neovim stays responsive, but Roslyn might take a few seconds to catch up.

---

## 📜 License

MIT License.  

## ❤️ Acknowledgements

- Inspired by the pain of using Roslyn in Neovim without file watchers 😅  
- Thanks to Neovim’s `vim.uv` for making cross-platform file watching possible.
