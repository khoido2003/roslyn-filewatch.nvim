local uv = vim.uv or vim.loop

local M = {}

-- Start a fs_poll watcher for `client` at `root`.
-- snapshots: shared snapshots table (from watcher.lua)
-- deps: table with expected fields:
--   scan_tree (fn), identity_from_stat (fn), same_file_info (fn),
--   queue_events (fn), notify (fn), notify_roslyn_renames (fn),
--   close_deleted_buffers (fn), restart_watcher (fn), last_events (table),
--   poll_interval (number), poller_restart_threshold (number)
function M.start(client, root, snapshots, deps)
	if not deps then
		return nil, "missing deps"
	end
	if not deps.scan_tree then
		return nil, "missing scan_tree"
	end

	local poll_interval = deps.poll_interval or 3000
	local poller = uv.new_fs_poll()

	local ok, start_err = pcall(function()
		poller:start(root, poll_interval, function(errp, prev, curr)
			if errp then
				if deps.notify then
					pcall(deps.notify, "Poller error: " .. tostring(errp), vim.log.levels.ERROR)
				end
				return
			end

			-- detect root metadata changes (same as before)
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
					pcall(deps.restart_watcher)
				end
				return
			end

			-- rescan tree into new_map
			local new_map = {}
			pcall(function()
				deps.scan_tree(root, new_map)
			end)

			local old_map = snapshots[client.id] or {}
			local evs = {}
			local saw_delete = false
			local rename_pairs = {}

			-- build old identity map
			local old_id_map = {}
			for path, entry in pairs(old_map) do
				local id = deps.identity_from_stat and deps.identity_from_stat(entry) or nil
				if id then
					old_id_map[id] = path
				end
			end

			-- detect creates / renames / changes
			for path, mt in pairs(new_map) do
				local old_mt = old_map[path]
				if not old_mt then
					local id = deps.identity_from_stat and deps.identity_from_stat(mt) or nil
					local oldpath = id and old_id_map[id]
					if oldpath then
						table.insert(rename_pairs, { old = oldpath, ["new"] = path })
						old_map[oldpath] = nil
						old_id_map[id] = nil
					else
						table.insert(evs, { uri = vim.uri_from_fname(path), type = 1 })
					end
				elseif not (deps.same_file_info and deps.same_file_info(old_map[path], new_map[path])) then
					table.insert(evs, { uri = vim.uri_from_fname(path), type = 2 })
				end
			end

			-- remaining old_map entries are deletes
			for path, _ in pairs(old_map) do
				saw_delete = true
				if deps.close_deleted_buffers then
					pcall(deps.close_deleted_buffers, path)
				end
				table.insert(evs, { uri = vim.uri_from_fname(path), type = 3 })
			end

			-- send renames
			if #rename_pairs > 0 then
				if deps.notify then
					pcall(deps.notify, "Poller detected " .. #rename_pairs .. " rename(s)", vim.log.levels.DEBUG)
				end
				if deps.notify_roslyn_renames then
					pcall(deps.notify_roslyn_renames, rename_pairs)
				end
			end

			if #evs > 0 then
				-- update snapshot, queue events, update last_events, and consider restart heuristics
				snapshots[client.id] = new_map
				if deps.queue_events then
					pcall(deps.queue_events, client.id, evs)
				end
				if deps.last_events then
					deps.last_events[client.id] = os.time()
				end

				local last = (deps.last_events and deps.last_events[client.id]) or 0
				local threshold = deps.poller_restart_threshold or 2
				if os.time() - last > threshold then
					if deps.notify then
						pcall(
							deps.notify,
							"Poller detected diffs while fs_event quiet; restarting watcher",
							vim.log.levels.DEBUG
						)
					end
					if deps.restart_watcher then
						pcall(deps.restart_watcher)
					end
				end

				if saw_delete then
					if deps.restart_watcher then
						pcall(deps.restart_watcher)
					end
				end
			else
				-- no diffs -> update snapshot
				snapshots[client.id] = new_map
			end
		end)
	end)

	if not ok then
		-- close poller if start failed
		pcall(function()
			if poller and poller.close then
				poller:close()
			end
		end)
		return nil, start_err
	end

	return poller
end

return M
