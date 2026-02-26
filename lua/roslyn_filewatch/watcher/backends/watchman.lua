---@class roslyn_filewatch.watcher_backend.watchman
local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

--- Watchman backend using 'watchman-make' or native 'watchman' CLI
--- We use the watchman JSON interface over CLI since it's most robust
function M.start(client, roots, snapshots, deps)
  -- Validate roots list; fall back to client.config.root_dir only when roots is empty
  if not roots or #roots == 0 then
    local fallback = client.config and client.config.root_dir
    if not fallback then
      return nil, "No root directory provided"
    end
    roots = { fallback }
  end
  -- Watchman backend currently only supports a single root; reject multiple roots early
  if #roots > 1 then
    return nil, "Watchman backend currently supports a single root (" .. #roots .. " provided)"
  end
  local root = roots[1]
  if not root then
    return nil, "No root directory provided"
  end
  root = utils.normalize_path(root)

  -- Allocate the poll timer before constructing the object so failures are caught
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

  -- Helper to queue events
  local function process_watchman_files(files)
    if not files or #files == 0 then
      return
    end

    local events = {}
    for _, f in ipairs(files) do
      local path = root .. "/" .. f.name
      path = utils.normalize_path(path)

      if utils.should_watch_path(path, config.options.ignore_dirs or {}, config.options.watch_extensions or {}) then
        local ev_type = 2 -- Changed
        if not f.exists then
          ev_type = 3 -- Deleted
        elseif f.new then
          ev_type = 1 -- Created
        end
        table.insert(events, { uri = vim.uri_from_fname(path), type = ev_type })

        -- Keep internal last_events updated for status
        if deps.last_events then
          deps.last_events[client.id] = os.time()
        end
      end
    end

    if #events > 0 and deps.queue_events then
      pcall(deps.queue_events, client.id, events)
    end
  end

  -- watchman watch the project
  vim.system({ "watchman", "watch-project", root }, { text = true }, function(watch_out)
    if not obj._running then
      return
    end

    -- Get initial clock
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

        -- Step 3: Start async polling using the clock
        if obj._timer and not obj._timer:is_closing() then
          obj._timer:start(100, config.options.poll_interval or 2000, function()
            if not obj._running or not obj._clock then
              return
            end

            -- Prevent overlap spawn
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

                -- Skip fresh instance warnings, only process incremental file changes
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
