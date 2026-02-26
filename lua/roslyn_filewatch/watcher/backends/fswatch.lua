---@class roslyn_filewatch.watcher_backend.fswatch
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

  -- Build fswatch arguments
  -- -r = recursive
  -- -0 = NUL record separator (robust with spaces in paths)
  -- --exclude = filters
  local args = { "-r", "-0", "--event=Created", "--event=Updated", "--event=Removed", "--event=Renamed" }

  -- Exclude ignored directories
  for _, dir in ipairs(config.options.ignore_dirs or {}) do
    -- fswatch uses regex for exclusions!
    table.insert(args, "--exclude")
    table.insert(args, "/" .. dir .. "/")
  end

  -- Add root directories
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

  -- Output buffering (NUL-delimited records)
  local buffer = ""

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

          if utils.should_watch_path(path, config.options.ignore_dirs or {}, config.options.watch_extensions or {}) then
            -- Simple approach: just tell the watcher something changed and force a fast diff-scan
            -- Since tracking exact mtime/size via fswatch stdout is tricky across platforms,
            -- we can queue a resync event.

            if deps.queue_events then
              -- For fswatch, we might not know if it's type 1 (create) 2 (update) or 3 (delete) accurately without stat.
              -- So we rely on a partial scan fallback or assume type 2.
              if deps.last_events then
                deps.last_events[client.id] = os.time()
              end
              pcall(deps.queue_events, client.id, { { uri = vim.uri_from_fname(path), type = 2 } })
            end
          end
        end
      end
    end
  end)

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

  local watcher_obj = {
    _handle = handle,
    _stdout = stdout,
    _stderr = stderr,
    stop = function(self)
      if self._handle and not self._handle:is_closing() then
        pcall(function() self._handle:kill(9) end)
        pcall(function() self._handle:close() end)
      end
      if self._stdout and not self._stdout:is_closing() then
        pcall(function() self._stdout:read_stop() end)
        pcall(function() self._stdout:close() end)
      end
      if self._stderr and not self._stderr:is_closing() then
        pcall(function() self._stderr:read_stop() end)
        pcall(function() self._stderr:close() end)
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
