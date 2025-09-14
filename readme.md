
# roslyn-filewatch.nvim

A lightweight file-watching plugin for Neovim that keeps the **Roslyn LSP** in sync with file changes.

⚡ **Why?**  
Roslyn doesn’t watch your project files by default in Neovim. Without this, you often need to `:edit!` or restart the LSP when adding/removing/modifying files.  
This plugin adds a proper **file system watcher** so Roslyn always stays updated.

---

## ✨ Features

- Watches your project root recursively using Neovim’s built-in `vim.uv`
- Detects file **create / change / delete** using `uv.fs_event` and `uv.fs_poll`.
- Detects **file renames** reliably (`didRenameFiles`).
- Sends `workspace/didChangeWatchedFiles` notifications to Roslyn

- Configurable:
  - Ignore dirs (`bin`, `obj`, `.git`, etc.)
  - File extensions to watch (`.cs`, `.csproj`, `.sln`, …)

- Auto cleans up watchers when LSP detaches
- **Batching** of events to reduce spam.
- **Watchdog** auto-resyncs when events are missed.
- Closes buffers for deleted files automatically.
- Works seamlessly in Unity projects with Roslyn.

---

## 📦 Requirements

This plugin does **not** provide a Roslyn language server on its own.  
You must already have an **LSP client for Roslyn** installed and configured.

You can use one of the following:

- [roslyn.nvim](https://github.com/seblyng/roslyn.nvim) — A Neovim plugin that manages Roslyn LSP automatically.  
- [nvim-lspconfig (roslyn_ls)](https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md#roslyn_ls) — Manual configuration for Roslyn LSP via `nvim-lspconfig`.

The file watcher integrates with whichever Roslyn LSP client you are using,  
and will forward file system events (`workspace/didChangeWatchedFiles`, `workspace/didRenameFiles`) to keep Roslyn in sync.

---

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "khoido2003/roslyn-filewatch.nvim",
    config = function()
      require("roslyn_filewatch").setup({
        -- optional overrides
        client_names = { "roslyn_ls", "roslyn", "roslyn_lsp" },
        ignore_dirs = {
          "Library",
          "Temp",
          "Logs",
		  "Obj",
		  "Bin",
		  ".git",
		  ".idea",
		  ".vs",
		},
		watch_extensions = { ".cs", ".csproj", ".sln", ".props", ".targets" },
		batching = {
		  enabled = true,
		  interval = 300, -- ms
		},
	 })
   end,
},
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim?utm_source=chatgpt.com)

```lua 
use {
  "khoido2003/roslyn-filewatch.nvim",
  config = function()
    require("roslyn_filewatch").setup()
  end,
}
```

## Configuration

```lua 

require("roslyn_filewatch").setup({

   client_names = { "roslyn_ls", "roslyn", "roslyn_lsp" },
   ignore_dirs = {
	 "Library",
	 "Temp",
	 "Logs",
	 "Obj",
	 "Bin",
	 ".git",
	 ".idea",
	 ".vs",
  },
  watch_extensions = { ".cs", ".csproj", ".sln", ".props", ".targets" },
  batching = {
    enabled = true,
    interval = 150,
  },
  poll_interval = 3000,            -- fs_poll interval (ms)
  poller_restart_threshold = 2,    -- restart poller if idle for N seconds
  watchdog_idle = 60,              -- restart watcher if idle for N seconds
  rename_detection_ms = 300,       -- window to detect delete+create → rename

  --- Window (ms) used to detect renames by buffering deletes and matching by identity.
  rename_detection_ms = 300,

  --- Debounce (ms) used to aggregate high-frequency fs events before processing.
  processing_debounce_ms = 80,
})

```

---

## Project Structure

```
lua/roslyn_filewatch/
├── watcher.lua        # Core orchestrator, starts/stops subsystems per client
├── watcher/
│   ├── fs_event.lua   # Low-level uv.fs_event handling
│   ├── fs_poll.lua    # Polling fallback for platforms with weak fs_event
│   ├── watchdog.lua   # Periodic resync & restart if no events received
│   ├── autocmds.lua   # Neovim autocmd integration (BufWrite, BufDelete, etc.)
│   ├── rename.lua     # Rename detection (Deleted+Created → didRenameFiles)
│   ├── snapshot.lua   # Snapshot tracking of file tree state
│   ├── notify.lua     # Thin wrapper for LSP + user notifications
│   └── utils.lua      # Path normalization, stat helpers, etc.
```

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

## 🐛 Troubleshooting

- **The plugin doesn’t seem to do anything?**
  - Run `:LspInfo` and make sure the active LSP name matches one of the entries in `client_names`.
  - Example: if your LSP shows up as `roslyn_ls`, ensure `client_names = { "roslyn_ls" }`.

- **On Linux, file watchers stop working after deleting directories.**
  - This is a known behavior of `libuv`. The plugin automatically reinitializes the watcher when this happens.

- **Performance concerns on large projects.**
  - Keep batching enabled (`enabled = true`) to reduce spammy notifications.
  - Tune `interval` for your workflow (e.g., 200–500 ms for very large solutions).


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

This project is licensed under the [MIT License](LICENSE).

---

## ❤️ Acknowledgements

- Inspired by the pain of using Roslyn in Neovim without file watchers 😅  
- Thanks to Neovim’s `vim.uv` for making cross-platform file watching possible.
