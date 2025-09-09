local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")

local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat

local pending = {} -- client_id -> { map = { identity -> { path, uri, ts, stat } }, timer = uv_timer }

local function safe_stop_timer(t)
	pcall(function()
		if t and not t:is_closing() then
			t:stop()
			t:close()
		end
	end)
end

local M = {}

--- Clear any pending delete timer + map for client
function M.clear(client_id)
	local pd = pending[client_id]
	if not pd then
		return
	end
	if pd.timer then
		safe_stop_timer(pd.timer)
	end
	pending[client_id] = nil
end

--- Handle a delete event for potential rename buffering.
-- Returns true if the delete was buffered (will be flushed later),
-- or false if the identity couldn't be computed (caller should treat as immediate delete).
--
-- Arguments:
--  client_id (number)
--  path (string) -- normalized fullpath that was deleted
--  prev_entry (table) -- previous snapshot entry for the path (should contain mtime/size and maybe ino/dev)
--  snapshots (table) -- snapshots table from watcher (so the flush can remove snapshot entries)
--  callbacks (table) -- { queue_events = fn, close_deleted_buffers = fn, notify = fn, rename_window_ms = number }
function M.on_delete(client_id, path, prev_entry, snapshots, callbacks)
	local id = identity_from_stat(prev_entry)
	if not id then
		-- cannot identity-match, caller must treat as immediate delete
		return false
	end

	pending[client_id] = pending[client_id] or { map = {} }
	pending[client_id].map = pending[client_id].map or {}
	pending[client_id].map[id] = {
		path = path,
		uri = vim.uri_from_fname(path),
		ts = uv.hrtime(),
		stat = prev_entry,
	}

	-- ensure timer exists
	if not pending[client_id].timer then
		local t = uv.new_timer()
		pending[client_id].timer = t
		local window = (callbacks and callbacks.rename_window_ms) or 300
		t:start(window, 0, function()
			-- flush all pending deletes for this client
			local pd = pending[client_id]
			if not pd or not pd.map then
				safe_stop_timer(t)
				pending[client_id] = nil
				return
			end

			local evs = {}
			for _, ent in pairs(pd.map) do
				-- remove from snapshot if present
				if snapshots[client_id] and snapshots[client_id][ent.path] then
					snapshots[client_id][ent.path] = nil
				end
				-- close buffers for deleted path
				if callbacks and callbacks.close_deleted_buffers then
					pcall(callbacks.close_deleted_buffers, ent.path)
				end
				table.insert(evs, { uri = ent.uri, type = 3 }) -- Deleted
			end

			-- cleanup timer + pending map
			safe_stop_timer(t)
			pending[client_id] = nil

			-- enqueue delete events
			if #evs > 0 and callbacks and callbacks.queue_events then
				vim.schedule(function()
					pcall(function()
						callbacks.queue_events(client_id, evs)
					end)
				end)
			end
		end)
	end

	return true
end

--- Handle a create event and attempt to match it to a buffered delete (rename).
-- If a match is found, this updates snapshots and emits a rename notify via callbacks.
-- Returns true if matched (rename handled), false otherwise.
--
-- Arguments:
--  client_id (number)
--  path (string) -- normalized fullpath of created file
--  st (uv fs_stat) -- stat for the created file
--  snapshots (table) -- snapshots table (will be updated for matched rename)
--  callbacks (table) -- { notify = fn, notify_roslyn_renames = fn }
function M.on_create(client_id, path, st, snapshots, callbacks)
	local id = identity_from_stat(st)
	if not id then
		return false
	end

	local pd = pending[client_id]
	if not pd or not pd.map or not pd.map[id] then
		return false
	end

	local del_ent = pd.map[id]

	-- remove pending mapping
	pd.map[id] = nil

	-- if map empty, stop timer and clear pending entry
	if next(pd.map) == nil then
		if pd.timer then
			safe_stop_timer(pd.timer)
		end
		pending[client_id] = nil
	end

	-- update snapshots: remove old path, insert new path
	if snapshots and snapshots[client_id] then
		snapshots[client_id][del_ent.path] = nil
		snapshots[client_id][path] = {
			mtime = mtime_ns(st),
			size = st.size,
			ino = st.ino,
			dev = st.dev,
		}
	end

	-- notify/log and send didRenameFiles
	if callbacks and callbacks.notify then
		pcall(callbacks.notify, "Detected rename: " .. del_ent.path .. " -> " .. path, vim.log.levels.DEBUG)
	end
	if callbacks and callbacks.notify_roslyn_renames then
		pcall(callbacks.notify_roslyn_renames, { { old = del_ent.path, ["new"] = path } })
	end

	return true
end

return M
