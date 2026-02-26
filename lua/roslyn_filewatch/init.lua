---@class roslyn_filewatch
---@field setup fun(opts?: roslyn_filewatch.Options)
---@field status fun()
---@field resync fun()
---@field reload fun()

local config = require("roslyn_filewatch.config")
local watcher = require("roslyn_filewatch.watcher")

local M = {}

--- Setup the roslyn-filewatch plugin
---@param opts? roslyn_filewatch.Options Configuration options
function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("RoslynFilewatch_LspAttach", { clear = true }),
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and vim.tbl_contains(config.options.client_names, client.name) then
        watcher.start(client)
      end
    end,
  })

  -- Create unified user command
  vim.api.nvim_create_user_command("RoslynFilewatch", function(opts)
    local action = string.lower(opts.fargs[1] or "status")

    if action == "status" then
      M.status()
    elseif action == "reload" then
      M.reload_and_resync()
      vim.notify("[roslyn-filewatch] Reloading projects and resyncing watcher...", vim.log.levels.INFO)
    else
      vim.notify("[roslyn-filewatch] Unknown command. Usage: :RoslynFilewatch [status|reload]", vim.log.levels.ERROR)
    end
  end, {
    nargs = "?",
    desc = "roslyn-filewatch tool (status, reload)",
    complete = function(_, line)
      local match = line:match("^%s*RoslynFilewatch%s+(%S*)")
      local subcmds = { "status", "reload" }
      if not match then
        return subcmds
      end
      local res = {}
      for _, cmd in ipairs(subcmds) do
        if vim.startswith(cmd, match) then
          table.insert(res, cmd)
        end
      end
      return res
    end,
  })
end

--- Show current watcher status
function M.status()
  local ok, status_mod = pcall(require, "roslyn_filewatch.status")
  if ok and status_mod and status_mod.show then
    status_mod.show()
  else
    vim.notify("[roslyn-filewatch] Status module not available", vim.log.levels.ERROR)
  end
end

--- Force full resync and reload for all active clients
function M.reload_and_resync()
  if watcher and watcher.resync then
    pcall(watcher.resync)
  end
  if watcher and watcher.reload_projects then
    pcall(watcher.reload_projects)
  end
end

--- Get current configuration options
---@return roslyn_filewatch.Options
function M.get_config()
  return config.options
end

--- Get available presets
---@return string[]
function M.get_presets()
  local ok, presets = pcall(require, "roslyn_filewatch.presets")
  if ok and presets and presets.list then
    return presets.list()
  end
  return {}
end

return M
