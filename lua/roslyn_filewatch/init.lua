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

  -- Create user command for status display
  vim.api.nvim_create_user_command("RoslynFilewatchStatus", function()
    M.status()
  end, { desc = "Show roslyn-filewatch status" })

  -- Create user command for manual resync
  vim.api.nvim_create_user_command("RoslynFilewatchResync", function()
    M.resync()
  end, { desc = "Force resync file watcher snapshots" })

  -- Create user command for project reload
  vim.api.nvim_create_user_command("RoslynReloadProjects", function()
    M.reload()
    vim.notify("[roslyn-filewatch] Reloading all projects...", vim.log.levels.INFO)
  end, { desc = "Force reload all project files" })
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

--- Force resync for all active clients
function M.resync()
  if watcher and watcher.resync then
    watcher.resync()
  else
    vim.notify("[roslyn-filewatch] Watcher module not available", vim.log.levels.ERROR)
  end
end

--- Force reload all Roslyn projects
function M.reload()
  if watcher and watcher.reload_projects then
    watcher.reload_projects()
  else
    vim.notify("[roslyn-filewatch] Reload not available", vim.log.levels.ERROR)
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
