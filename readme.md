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

Roslyn LSP must already be installed (`roslyn.nvim` or `nvim-lspconfig`).

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
| `:RoslynExplorer` | Open solution browser |
| `:RoslynReload` | Reload all project files |

---

## 🐛 Troubleshooting

- Ensure client name matches `client_names` in config.
- Watchdog auto-restarts watchers on dropped events.
- Use Unity preset for large repos.

---

## 📜 License

MIT License

---

## ❤️ Acknowledgements

Made to fix the pain of Roslyn not watching files in Neovim.
