---@class roslyn_filewatch.watcher_backend
---@field start fun(client: vim.lsp.Client, roots: string[], snapshots: table, deps: table): table|nil, string|nil
---@field stop fun(handle: table)

local M = {}

---@type table<string, roslyn_filewatch.watcher_backend>
local backends = {}

local function load_backend(name)
  if not backends[name] then
    local ok, mod = pcall(require, "roslyn_filewatch.watcher.backends." .. name)
    if ok and mod then
      backends[name] = mod
    end
  end
  return backends[name]
end

--- Get the best available file watching backend
---@return roslyn_filewatch.watcher_backend|nil, string
function M.get_best_backend()
  -- 1. Try watchman (best performance on monorepos and Windows)
  if vim.fn.executable("watchman") == 1 then
    local backend = load_backend("watchman")
    if backend then
      return backend, "watchman"
    end
  end

  -- 2. Try fswatch (macOS/Linux standard, native ignore)
  if vim.fn.executable("fswatch") == 1 then
    local backend = load_backend("fswatch")
    if backend then
      return backend, "fswatch"
    end
  end

  -- 3. Fallback to libuv fs_event (has limitations with ignores)
  local fallback = load_backend("fs_event_adapter")
  if fallback then
    return fallback, "fs_event"
  end

  return nil, "no backend available"
end

return M
