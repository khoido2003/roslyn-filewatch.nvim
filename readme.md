# roslyn-filewatch.nvim

A lightweight file-watching and project-sync plugin for Neovim that keeps the **Roslyn LSP** up-to-date with file changes.

⚡ **Why?**  
Roslyn does not watch your project files by default in Neovim. Without this, you often need to `:edit!` or restart the LSP to make Roslyn notice file creation, deletion, rename, or solution changes.  
This plugin adds a robust **cross-platform file watcher** plus new project-sync and navigation features.

---

## ✨ Features

### 🗂️ File Watching Core
- Watches your project root recursively using Neovim’s built-in `vim.uv`
- Detects file **create / change / delete** using `uv.fs_event` and `uv.fs_poll`
- Reliable **rename detection** with delete+create pairing
- Sends:
  - `workspace/didChangeWatchedFiles`
  - `workspace/didRenameFiles`
- Automatically cleans up watchers when LSP detaches
- **Batching** to reduce notification spam
- **Watchdog** detects dropped events and restarts watcher
- Automatically closes deleted buffers
- Solution-aware watching:
  - Parses `.sln`, `.slnx`, `.slnf` to scope watch area to project folders

### 🆕 New in v0.3.0

#### ⏳ Deferred Project Loading
Roslyn project loading is delayed until you actually open a `.cs` file.  
This improves startup time drastically, especially for **Unity** or large solutions.

#### 🧭 Solution Explorer (`:RoslynExplorer`)
A minimal tree picker for navigating solution → projects → files.

#### 🎮 Unity-Optimized Presets
Built-in presets auto-tune behavior for Unity:
- reduced event frequency  
- smarter batching  
- ignores Unity noise  

#### 📡 Diagnostic Throttling
Smooths Roslyn diagnostic spam during heavy operations.

#### 🔄 Project Reload Command
Force Roslyn to reload all `.csproj` files without restarting the LSP: `:RoslynReload`

---

## 🔌 Requirements

This plugin does **not** provide a Roslyn language server on its own.  
You must already have an **LSP client for Roslyn** installed and configured.

You can use one of the following:

- [roslyn.nvim](https://github.com/seblyng/roslyn.nvim) — A Neovim plugin that manages Roslyn LSP automatically.  
- [nvim-lspconfig (roslyn_ls)](https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md#roslyn_ls) — Manual configuration for Roslyn LSP via `nvim-lspconfig`.

The file watcher integrates with whichever Roslyn LSP client you are using,  
and will forward file system events (`workspace/didChangeWatchedFiles`, `workspace/didRenameFiles`) to keep Roslyn in sync.

---

## 📦 Installation

### lazy.nvim

```lua
{
  "khoido2003/roslyn-filewatch.nvim",
  config = function()
    require("roslyn_filewatch").setup()
  end,
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

## ⚙️ Configuration

```lua
require("roslyn_filewatch").setup({
  client_names = { "roslyn_ls", "roslyn", "roslyn_lsp" },
  preset = "auto",
  deferred_loading = true,
  deferred_loading_delay_ms = 150,

  ignore_dirs = { "Library", "Temp", "Logs", "Obj", "Bin", ".git", ".idea", ".vs" },
  ignore_patterns = {},
  watch_extensions = { ".cs", ".csproj", ".sln", ".slnx", ".slnf", ".props", ".targets" },

  batching = { enabled = true, interval = 300 },

  poll_interval = 3000,
  poller_restart_threshold = 2,
  watchdog_idle = 60,
  rename_detection_ms = 300,
  processing_debounce_ms = 80,

  solution_aware = true,
  respect_gitignore = true,

  diagnostic_throttling = {
    enabled = true,
    debounce_ms = 150,
    visible_only = true,
  },

  log_level = vim.log.levels.WARN,
})
```

---

## 🧭 Commands

| Command | Description |
|---------|-------------|
| `:RoslynFilewatchStatus` | Show watcher & solution status |
| `:RoslynExplorer` | Open solution browser (works even before LSP loads) |
| `:RoslynFiles` | Quick file finder for all C# files in solution |
| `:RoslynReload` | Reload all project files |

---

## 🎮 Game Engine Support

The plugin auto-detects and optimizes settings for these C# game engines:

| Engine | Detection | Preset |
|--------|-----------|--------|
| **Unity** | `Assets/`, `ProjectSettings/` folders | `unity` |
| **Godot 4.x** | `project.godot` file or `.godot/` folder | `godot` |
| **Stride** | `.sdpkg` package files | `stride` |
| **MonoGame** | `Content.mgcb` pipeline files | `monogame` |
| **FNA** | `fnalibs/` folder | `fna` |

### Manual Preset Selection

```lua
require("roslyn_filewatch").setup({
  preset = "unity",  -- or "godot", "stride", "monogame", "fna", "large", "console"
})
```

---

## 🐛 Troubleshooting

- Watchdog auto-restarts watchers on dropped events.
- Use `preset = "unity"` or `preset = "large"` for big repos to prevent freezing.

- **The plugin doesn’t seem to do anything?**
  - Run `:LspInfo` and make sure the active LSP name matches one of the entries in `client_names`.
  - Example: if your LSP shows up as `roslyn_ls`, ensure `client_names = { "roslyn_ls" }`.

- **On Linux, file watchers stop working after deleting directories.**
  - This is a known behavior of `libuv`. The plugin automatically reinitializes the watcher when this happens.

- **Performance concerns on large projects.**
  - Keep batching enabled (`enabled = true`) to reduce spammy notifications.
  - Tune `interval` for your workflow (e.g., 200–500 ms for very large solutions).---

---

## 🔍 How It Works

This plugin keeps Roslyn aware of **file system changes** that Neovim or Unity trigger:

1. **fs_event** (`uv.fs_event`)  
   - Listens for low-level file changes.  
   - Fast and efficient where supported.  

2. **fs_poll** (`uv.fs_poll`)  
   - Polls periodically as a fallback.  
   - Detects missed events and validates file integrity.  

3. **Snapshots** (`snapshot.lua`)  
   - Keeps an in-memory map of files and their metadata (mtime, inode, size).  
   - Allows diffing to detect *created*, *deleted*, or *changed* files.  

4. **Rename detection** (`rename.lua`)  
   - If a file is deleted and a new one created within a short window → treat as **rename**.  
   - Sends Roslyn `workspace/didRenameFiles` instead of separate delete/create.  

5. **Batching**  
   - Groups multiple events into a single LSP notification to reduce traffic.  

6. **Watchdog**  
   - Restarts the watcher if no events are seen for too long (e.g. Unity reload).  
   - Ensures resilience against dropped events.  

7. **Autocmds**  
   - Hooks into Neovim’s buffer lifecycle (`BufWritePost`, `BufDelete`, etc.).  
   - Keeps open buffers and file state in sync.  

8. **Notifications**  
   - Translates events into Roslyn-compatible LSP notifications:  
     - `workspace/didChangeWatchedFiles`  
     - `workspace/didRenameFiles`

---

## ⚠️ Known Limitations

- On very large repositories (tens of thousands of files):  
  - Initial snapshot scans can cause **short CPU spikes** (UI may freeze briefly).  
  - Memory usage scales with project size (released when projects close).  

- During heavy operations (e.g. `git checkout`, Unity regenerating solution files):  
  - Expect a burst of events. With batching enabled, these are grouped safely,  
    but you may notice **slight delays** before Roslyn sees all updates.  

- These spikes **will not crash Neovim**, but may temporarily impact responsiveness.  

For most Unity/.NET projects, this plugin is **good enough** and keeps Roslyn in sync without manual restarts.


---

## 📜 License

MIT License

---

## ❤️ Acknowledgements

Made to fix the pain of Roslyn not watching files in Neovim.
