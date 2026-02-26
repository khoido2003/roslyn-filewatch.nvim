---@class roslyn_filewatch.watcher_backend.fs_event_adapter
local fs_event = require("roslyn_filewatch.watcher.fs_event")

local M = {}

--- Adapter to make fs_event compatible with multi-root backend interface
---@param client vim.lsp.Client
---@param roots string[]
---@param snapshots table
---@param deps table
---@return table|nil, string|nil
function M.start(client, roots, snapshots, deps)
  -- fs_event currently only supports a single root efficiently in our setup,
  -- so we just use the first root (which should be the main root) or fallback to client.config.root_dir
  local root = (roots and #roots > 0) and roots[1] or (client.config and client.config.root_dir)
  if not root then
    return nil, "No root directory provided"
  end

  -- Wrap the handle to match our generic handle interface expected by stop()
  local handle, err = fs_event.start(client, root, snapshots, deps)
  if not handle then
    return nil, err
  end

  return {
    _uv_handle = handle,
    _client_id = client.id,
    stop = function(self)
      if self._uv_handle and not self._uv_handle:is_closing() then
        pcall(self._uv_handle.stop, self._uv_handle)
        pcall(self._uv_handle.close, self._uv_handle)
      end
      fs_event.clear(self._client_id)
    end,
  },
    nil
end

function M.stop(handle)
  if handle and handle.stop then
    pcall(handle.stop, handle)
  end
end

return M
