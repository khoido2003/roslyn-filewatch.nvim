---@class roslyn_filewatch.watcher_backend.watchman
---@diagnostic disable-next-line: undefined-doc-name
---@field start fun(client: vim.lsp.Client, roots: string[], snapshots: table, deps: table): table|nil, string|nil
---@field stop fun(handle: table|nil)

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

---@diagnostic disable: undefined-field, undefined-doc-name

local M = {}

function M.start(client, roots, snapshots, deps)
  if not roots or #roots == 0 then
    local fallback = client.config and client.config.root_dir
    if not fallback then
      return nil, "No root directory provided"
    end
    roots = { fallback }
  end
  if #roots > 1 then
    return nil, "Watchman backend currently supports a single root (" .. #roots .. " provided)"
  end
  local root = roots[1]
  if not root then
    return nil, "No root directory provided"
  end
  root = utils.normalize_path(root)

  local timer = uv.new_timer()
  if not timer then
    return nil, "Failed to allocate watchman poll timer"
  end

  local obj = {
    _timer = timer,
    _clock = nil,
    _running = true,
  }

  function obj:stop()
    self._running = false
    if self._timer and not self._timer:is_closing() then
      self._timer:stop()
      self._timer:close()
    end
  end

  local function process_watchman_files(files)
    if not files or #files == 0 then
      return
    end

    local events = {}
    for _, f in ipairs(files) do
      local path = root .. "/" .. f.name
      path = utils.normalize_path(path)

      if utils.should_watch_path(path, config.options.ignore_dirs or {}, config.options.watch_extensions or {}) then
        local ev_type = 2
        if not f.exists then
          ev_type = 3
        elseif f.new then
          ev_type = 1
        end
        table.insert(events, { uri = vim.uri_from_fname(path), type = ev_type })

        if deps.last_events then
          deps.last_events[client.id] = os.time()
        end
      end
    end

    if #events > 0 and deps.queue_events then
      pcall(deps.queue_events, client.id, events)
    end
  end

  vim.system({ "watchman", "watch-project", root }, { text = true }, function(watch_out)
    if not obj._running then
      return
    end

    vim.system({ "watchman", "clock", root }, { text = true }, function(clock_out)
      if not obj._running then
        return
      end
      if clock_out.code ~= 0 then
        return
      end

      local ok_json, parsed_clock = pcall(vim.json.decode, clock_out.stdout)
      if ok_json and parsed_clock and parsed_clock.clock then
        obj._clock = parsed_clock.clock

        if obj._timer and not obj._timer:is_closing() then
          local interval = tonumber(config.options.poll_interval) or 500
          if interval < 100 then
            interval = 100
          end
          obj._timer:start(100, interval, function()
            if not obj._running or not obj._clock then
              return
            end

            if obj._is_polling then
              return
            end
            obj._is_polling = true

            vim.system({ "watchman", "since", root, obj._clock }, { text = true }, function(since_out)
              obj._is_polling = false
              if not obj._running then
                return
              end
              if since_out.code ~= 0 then
                return
              end

              local ok_since, parsed_since = pcall(vim.json.decode, since_out.stdout)
              if ok_since and parsed_since then
                if parsed_since.clock then
                  obj._clock = parsed_since.clock
                end

                if parsed_since.files and not parsed_since.is_fresh_instance then
                  process_watchman_files(parsed_since.files)
                end
              end
            end)
          end)
        end
      end
    end)
  end)

  return obj, nil
end

function M.stop(handle)
  if handle and handle.stop then
    pcall(handle.stop, handle)
  end
end

return M
