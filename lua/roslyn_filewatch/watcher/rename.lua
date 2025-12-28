---@class roslyn_filewatch.rename
---@field clear fun(client_id: number)
---@field on_delete fun(client_id: number, path: string, prev_entry: roslyn_filewatch.SnapshotEntry, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, callbacks: roslyn_filewatch.RenameCallbacks): boolean
---@field on_create fun(client_id: number, path: string, st: uv.fs_stat.result, snapshots: table<number, table<string, roslyn_filewatch.SnapshotEntry>>, callbacks: roslyn_filewatch.RenameCreateCallbacks): boolean

---@class roslyn_filewatch.RenameCallbacks
---@field queue_events fun(client_id: number, evs: roslyn_filewatch.FileChange[])
---@field close_deleted_buffers fun(path: string)
---@field notify fun(msg: string, level?: number)
---@field rename_window_ms? number

---@class roslyn_filewatch.RenameCreateCallbacks
---@field notify fun(msg: string, level?: number)
---@field notify_roslyn_renames fun(files: roslyn_filewatch.RenameEntry[])

---@class PendingDelete
---@field path string
---@field uri string
---@field ts number hrtime timestamp
---@field stat roslyn_filewatch.SnapshotEntry

---@class PendingDeleteBuffer
---@field map table<string, PendingDelete>
---@field timer uv_timer_t|nil

local uv = vim.uv or vim.loop
local utils = require("roslyn_filewatch.watcher.utils")

local mtime_ns = utils.mtime_ns
local identity_from_stat = utils.identity_from_stat

---@type table<number, PendingDeleteBuffer>
local pending = {}

--- Safely stop and close a timer
---@param t uv_timer_t|nil
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
---@param client_id number
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
--- Returns true if the delete was buffered (will be flushed later),
--- or false if the identity couldn't be computed (caller should treat as immediate delete).
---@param client_id number
---@param path string Normalized fullpath that was deleted
---@param prev_entry roslyn_filewatch.SnapshotEntry Previous snapshot entry for the path
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Snapshots table from watcher
---@param callbacks roslyn_filewatch.RenameCallbacks Callback functions
---@return boolean buffered Whether the delete was buffered
function M.on_delete(client_id, path, prev_entry, snapshots, callbacks)
	local id = identity_from_stat(prev_entry)
	if not id then
		-- Cannot identity-match, caller must treat as immediate delete
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

	-- Ensure timer exists
	if not pending[client_id].timer then
		local t = uv.new_timer()
		pending[client_id].timer = t
		local window = (callbacks and callbacks.rename_window_ms) or 300

		t:start(window, 0, function()
			-- Flush all pending deletes for this client
			local pd = pending[client_id]
			if not pd or not pd.map then
				safe_stop_timer(t)
				pending[client_id] = nil
				return
			end

			---@type roslyn_filewatch.FileChange[]
			local evs = {}
			for _, ent in pairs(pd.map) do
				-- Remove from snapshot if present
				if snapshots[client_id] and snapshots[client_id][ent.path] then
					snapshots[client_id][ent.path] = nil
				end
				-- Close buffers for deleted path
				if callbacks and callbacks.close_deleted_buffers then
					pcall(callbacks.close_deleted_buffers, ent.path)
				end
				table.insert(evs, { uri = ent.uri, type = 3 }) -- Deleted
			end

			-- Cleanup timer + pending map
			safe_stop_timer(t)
			pending[client_id] = nil

			-- Enqueue delete events
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
--- If a match is found, this updates snapshots and emits a rename notify via callbacks.
--- Returns true if matched (rename handled), false otherwise.
---@param client_id number
---@param path string Normalized fullpath of created file
---@param st uv.fs_stat.result Stat for the created file
---@param snapshots table<number, table<string, roslyn_filewatch.SnapshotEntry>> Snapshots table
---@param callbacks roslyn_filewatch.RenameCreateCallbacks Callback functions
---@return boolean matched Whether a rename was detected
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

	-- Remove pending mapping
	pd.map[id] = nil

	-- If map empty, stop timer and clear pending entry
	if next(pd.map) == nil then
		if pd.timer then
			safe_stop_timer(pd.timer)
		end
		pending[client_id] = nil
	end

	-- Update snapshots: remove old path, insert new path
	if snapshots and snapshots[client_id] then
		snapshots[client_id][del_ent.path] = nil
		snapshots[client_id][path] = {
			mtime = mtime_ns(st),
			size = st.size,
			ino = st.ino,
			dev = st.dev,
		}
	end

	-- Notify/log and send didRenameFiles
	if callbacks and callbacks.notify then
		pcall(callbacks.notify, "Detected rename: " .. del_ent.path .. " -> " .. path, vim.log.levels.DEBUG)
	end
	if callbacks and callbacks.notify_roslyn_renames then
		pcall(callbacks.notify_roslyn_renames, { { old = del_ent.path, ["new"] = path } })
	end

	return true
end

return M
