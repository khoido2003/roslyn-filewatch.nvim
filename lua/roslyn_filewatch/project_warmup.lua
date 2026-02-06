---@class roslyn_filewatch.project_warmup
---@field warmup fun(client: vim.lsp.Client)
---@field send_project_init_complete fun(client: vim.lsp.Client)
---@field clear_client fun(client_id: number)

---Project warm-up module for faster Roslyn LSP initialization.
---SIMPLIFIED version - just sends projectInitializationComplete after delay.
---Avoids duplicate project/open since watcher already handles this.

local M = {}

local config = require("roslyn_filewatch.config")

-- Track warmup state per client (weak table to allow garbage collection)
---@type table<number, boolean>
local init_complete_sent = setmetatable({}, { __mode = "k" })

--- Send workspace/projectInitializationComplete notification
--- This tells Roslyn that project discovery is complete
---@param client vim.lsp.Client
function M.send_project_init_complete(client)
  if not client then
    return
  end

  -- Check if client is still valid
  local ok_check = pcall(function()
    return client.id and not (client.is_stopped and client.is_stopped())
  end)
  if not ok_check then
    return
  end

  local cid = client.id
  if init_complete_sent[cid] then
    return
  end

  init_complete_sent[cid] = true

  -- Send the notification (silent fail if not supported)
  pcall(function()
    client:notify("workspace/projectInitializationComplete", {})
  end)
end

--- Perform lightweight project warmup for a client
--- Just sends projectInitializationComplete after a delay
--- Avoids heavy work - watcher already handles project/open
---@param client vim.lsp.Client
function M.warmup(client)
  if not client then
    return
  end

  local cid = client.id
  if init_complete_sent[cid] then
    return
  end

  -- Check if client is valid
  local ok_check = pcall(function()
    return not (client.is_stopped and client.is_stopped())
  end)
  if not ok_check then
    return
  end

  -- Simple delayed notification - no file scanning needed
  -- Watcher module already handles project/open with its own logic
  local warmup_delay = (config.options and config.options.project_warmup_delay_ms) or 3000

  vim.defer_fn(function()
    -- Re-check client validity before sending
    local still_valid = pcall(function()
      return client.id and not (client.is_stopped and client.is_stopped())
    end)
    if still_valid then
      M.send_project_init_complete(client)
    end
  end, warmup_delay)
end

--- Clear state for a client
---@param client_id number
function M.clear_client(client_id)
  init_complete_sent[client_id] = nil
end

--- Get warmup status for a client
---@param client_id number
---@return boolean init_sent
function M.get_status(client_id)
  return init_complete_sent[client_id] == true
end

return M
