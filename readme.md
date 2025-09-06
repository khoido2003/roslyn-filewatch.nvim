
# roslyn-filewatch.nvim

A lightweight file-watching plugin for Neovim that keeps the **Roslyn LSP** in sync with file changes.

⚡ **Why?**  
Roslyn doesn’t watch your project files by default in Neovim. Without this, you often need to `:edit!` or restart the LSP when adding/removing/modifying files.  
This plugin adds a proper **file system watcher** so Roslyn always stays updated.

---

## ✨ Features

- Watches your project root recursively using Neovim’s built-in `vim.uv`
- Sends `workspace/didChangeWatchedFiles` notifications to Roslyn (or any configured LSP)
- Configurable:
  - Ignore dirs (`bin`, `obj`, `.git`, etc.)
  - File extensions to watch (`.cs`, `.csproj`, `.sln`, …)
  - Batch notifications (to avoid flooding LSP with events)
- Auto cleans up watchers when LSP detaches

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

```

---

## ⚙️ How It Works

1. When a Roslyn (or configured) LSP client attaches, the plugin starts a recursive `uv.fs_event` watcher at your project root.
2. File changes (create, delete, rename, modify) are detected in real-time.
3. The plugin sends `workspace/didChangeWatchedFiles` notifications to the LSP, keeping it perfectly in sync.
4. If batching is enabled, multiple file events are grouped before sending to avoid overwhelming the LSP.
5. When the LSP detaches, the watcher is automatically cleaned up.

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
