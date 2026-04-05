---@class roslyn_filewatch.watcher_backend.fswatch
---@diagnostic disable-next-line: undefined-doc-name
---@field start fun(client: vim.lsp.Client, roots: string[], snapshots: table, deps: table): table|nil, string|nil
---@field stop fun(handle: table|nil)

---@diagnostic disable: undefined-field, undefined-doc-name

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

function M.start(client, roots, snapshots, deps)
  if not roots or #roots == 0 then
    if client.config and client.config.root_dir then
      roots = { client.config.root_dir }
    else
      return nil, "No root directory provided"
    end
  end

  local args = { "-r", "-0", "--event=Created", "--event=Updated", "--event=Removed", "--event=Renamed" }

  for _, dir in ipairs(config.options.ignore_dirs or {}) do
    table.insert(args, "--exclude")
    table.insert(args, "/" .. dir .. "/")
  end

  for _, root in ipairs(roots) do
    table.insert(args, utils.normalize_path(root))
  end

  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local handle
  handle = uv.spawn("fswatch", {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code, signal)
    if stdout and not stdout:is_closing() then
      pcall(stdout.read_stop, stdout)
      pcall(stdout.close, stdout)
    end
    if stderr and not stderr:is_closing() then
      pcall(stderr.read_stop, stderr)
      pcall(stderr.close, stderr)
    end
    if handle and not handle:is_closing() then
      handle:close()
    end
  end)

  if not handle then
    if stdout then
      stdout:close()
    end
    if stderr then
      stderr:close()
    end
    return nil, "Failed to spawn fswatch"
  end

  local buffer = ""
  local is_alive = true
  local path_seq = {}

  if stdout then
    uv.read_start(stdout, function(err, data)
      if err then
        return
      end
      if data then
        buffer = buffer .. data
        while true do
          local rec_end = buffer:find("\0", 1, true)
          if not rec_end then
            break
          end
          local record = buffer:sub(1, rec_end - 1)
          buffer = buffer:sub(rec_end + 1)

          if #record > 0 then
            local path = record

            path = utils.normalize_path(path)

            if
              utils.should_watch_path(path, config.options.ignore_dirs or {}, config.options.watch_extensions or {})
            then
              if deps.queue_events then
                path_seq[path] = (path_seq[path] or 0) + 1
                local current_seq = path_seq[path]

                uv.fs_stat(path, function(stat_err, stat)
                  if not is_alive or path_seq[path] ~= current_seq then
                    return
                  end
                  local event_type = 2
                  local client_snapshots = snapshots[client.id] or {}
                  local prev_mt = client_snapshots[path]

                  if not stat_err and stat then
                    local current_mt = string.format("%d:%d", stat.mtime.sec or 0, stat.mtime.nsec or 0)
                    if not prev_mt then
                      event_type = 1
                    elseif prev_mt ~= current_mt then
                      event_type = 2
                    else
                      snapshots[client.id] = client_snapshots
                      return
                    end
                    client_snapshots[path] = current_mt
                  else
                    if prev_mt then
                      event_type = 3
                      client_snapshots[path] = nil
                    else
                      return
                    end
                  end

                  snapshots[client.id] = client_snapshots

                  vim.schedule(function()
                    if not is_alive or path_seq[path] ~= current_seq then
                      return
                    end
                    if deps.last_events then
                      deps.last_events[client.id] = os.time()
                    end
                    pcall(deps.queue_events, client.id, { { uri = vim.uri_from_fname(path), type = event_type } })
                  end)
                end)
              end
            end
          end
        end
      end
    end)
  end

  if stderr then
    uv.read_start(stderr, function(err, data)
      if err then
        if stderr and not stderr:is_closing() then
          pcall(stderr.read_stop, stderr)
          pcall(stderr.close, stderr)
        end
        return
      end
      if not data then
        if stderr and not stderr:is_closing() then
          pcall(stderr.read_stop, stderr)
          pcall(stderr.close, stderr)
        end
        return
      end
    end)
  end

  local watcher_obj = {
    _handle = handle,
    _stdout = stdout,
    _stderr = stderr,
    stop = function(self)
      is_alive = false
      if self._handle and not self._handle:is_closing() then
        pcall(function()
          self._handle:kill(9)
        end)
        pcall(function()
          self._handle:close()
        end)
      end
      if self._stdout and not self._stdout:is_closing() then
        pcall(function()
          self._stdout:read_stop()
        end)
        pcall(function()
          self._stdout:close()
        end)
      end
      if self._stderr and not self._stderr:is_closing() then
        pcall(function()
          self._stderr:read_stop()
        end)
        pcall(function()
          self._stderr:close()
        end)
      end
    end,
  }

  return watcher_obj, nil
end

function M.stop(handle)
  if handle and handle.stop then
    pcall(handle.stop, handle)
  end
end

return M
