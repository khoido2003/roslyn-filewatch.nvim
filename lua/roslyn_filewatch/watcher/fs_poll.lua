---@class roslyn_filewatch.fs_poll
---@field start fun(client: vim.lsp.Client, root: string, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, deps: roslyn_filewatch.FsPollDeps): uv_fs_poll_t|nil, string|nil

---@class roslyn_filewatch.FsPollDeps
---@field scan_tree fun(root: string, out_map: table<string, roslyn_filewatch.SnapshotEntry>)
---@field identity_from_stat fun(st: roslyn_filewatch.SnapshotEntry|nil): string|nil
---@field same_file_info fun(a: roslyn_filewatch.SnapshotEntry|nil, b: roslyn_filewatch.SnapshotEntry|nil): boolean
---@field queue_events fun(client_id: number, evs: roslyn_filewatch.FileChange[])
---@field notify fun(msg: string, level?: number)
---@field notify_roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])
---@field close_deleted_buffers fun(path: string)
---@field restart_watcher fun(reason?: string, delay_ms?: number, disable_fs_event?: boolean)
---@field last_events table<number, number>
---@field poll_interval number
---@field poller_restart_threshold number

local uv = vim.uv or vim.loop

local M = {}

--- Start a fs_poll watcher for `client` at `root`.
---@param client vim.lsp.Client LSP client
---@param root string Root directory path
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Shared snapshots table
---@param deps roslyn_filewatch.FsPollDeps Dependencies
---@return uv_fs_poll_t|nil poller The poll handle, or nil on error
---@return string|nil error Error message if failed
function M.start(client, root, snapshots, deps)
	if not deps then
		return nil, "missing deps"
	end
	if not deps.scan_tree then
		return nil, "missing scan_tree"
	end

	local poll_interval = deps.poll_interval or 3000
	local poller_restart_threshold = deps.poller_restart_threshold or 2

	local poller = uv.new_fs_poll()
	if not poller then
		return nil, "failed to create fs_poll"
	end

	local ok, start_err = pcall(function()
		poller:start(root, poll_interval, function(errp, prev, curr)
			if errp then
				if deps.notify then
					pcall(deps.notify, "Poller error: " .. tostring(errp), vim.log.levels.ERROR)
				end
				return
			end

			-- Detect root metadata changes
			if
				prev
				and curr
				and (prev.mtime and curr.mtime)
				and (prev.mtime.sec ~= curr.mtime.sec or prev.mtime.nsec ~= curr.mtime.nsec)
			then
				if deps.notify then
					pcall(deps.notify, "Poller detected root metadata change; restarting watcher", vim.log.levels.DEBUG)
				end
				if deps.restart_watcher then
					pcall(deps.restart_watcher, "root_metadata_change")
				end
				return
			end

			-- BUG FIX: Store last_event BEFORE updating it, so threshold comparison works
			local last_event_time = (deps.last_events and deps.last_events[client.id]) or 0

			-- Rescan tree into new_map
			---@type table<string, roslyn_filewatch.SnapshotEntry>
			local new_map = {}
			pcall(function()
				deps.scan_tree(root, new_map)
			end)

			local old_map = snapshots[client.id] or {}

			---@type roslyn_filewatch.FileChange[]
			local evs = {}
			local saw_delete = false
			---@type roslyn_filewatch.RenameEntry[]
			local rename_pairs = {}

			-- Build old identity map
			---@type table<string, string>
			local old_id_map = {}
			for path, entry in pairs(old_map) do
				local id = deps.identity_from_stat and deps.identity_from_stat(entry) or nil
				if id then
					old_id_map[id] = path
				end
			end

			-- Track processed old paths to avoid double-processing
			---@type table<string, boolean>
			local processed_old = {}

			-- Detect creates / renames / changes
			for path, mt in pairs(new_map) do
				local old_mt = old_map[path]
				if not old_mt then
					local id = deps.identity_from_stat and deps.identity_from_stat(mt) or nil
					local oldpath = id and old_id_map[id]
					if oldpath then
						table.insert(rename_pairs, { old = oldpath, ["new"] = path })
						processed_old[oldpath] = true
						old_id_map[id] = nil
					else
						table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
					end
				elseif not (deps.same_file_info and deps.same_file_info(old_map[path], new_map[path])) then
					table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
				end
				processed_old[path] = true
			end

			-- Remaining old_map entries are deletes
			for path, _ in pairs(old_map) do
				if not processed_old[path] and new_map[path] == nil then
					saw_delete = true
					if deps.close_deleted_buffers then
						pcall(deps.close_deleted_buffers, path)
					end
					table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
				end
			end

			-- Send renames
			if #rename_pairs > 0 then
				if deps.notify then
					pcall(deps.notify, "Poller detected " .. #rename_pairs .. " rename(s)", vim.log.levels.DEBUG)
				end
				if deps.notify_roslyn_renames then
					pcall(deps.notify_roslyn_renames, rename_pairs)
				end
			end

			if #evs > 0 then
				-- Update snapshot, queue events
				snapshots[client.id] = new_map
				if deps.queue_events then
					pcall(deps.queue_events, client.id, evs)
				end

				-- Now update last_events AFTER processing
				if deps.last_events then
					deps.last_events[client.id] = os.time()
				end

				-- BUG FIX: Use the STORED last_event_time for threshold comparison
				-- This correctly detects if fs_event was quiet while poller found changes
				if os.time() - last_event_time > poller_restart_threshold then
					if deps.notify then
						pcall(
							deps.notify,
							"Poller detected diffs while fs_event quiet; restarting watcher",
							vim.log.levels.DEBUG
						)
					end
					if deps.restart_watcher then
						pcall(deps.restart_watcher, "poller_detected_missed_events")
					end
				end

				if saw_delete then
					if deps.restart_watcher then
						pcall(deps.restart_watcher, "delete_detected")
					end
				end
			else
				-- No diffs -> update snapshot
				snapshots[client.id] = new_map
			end
		end)
	end)

	if not ok then
		-- Close poller if start failed
		pcall(function()
			if poller and poller.close then
				poller:close()
			end
		end)
		return nil, start_err
	end

	return poller, nil
end

return M
