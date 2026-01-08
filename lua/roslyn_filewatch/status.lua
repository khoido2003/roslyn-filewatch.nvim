---@class roslyn_filewatch.status
---@field get_status fun(): roslyn_filewatch.StatusInfo
---@field show fun()

---Status tracking module for RoslynFilewatchStatus command.

local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

local M = {}

---@class roslyn_filewatch.StatusInfo
---@field clients roslyn_filewatch.ClientStatus[]
---@field config_summary table

---@class roslyn_filewatch.ClientStatus
---@field id number
---@field name string
---@field root string
---@field has_fs_event boolean
---@field has_poller boolean
---@field has_watchdog boolean
---@field file_count number
---@field last_event number|nil
---@field sln_file string|nil
---@field project_dirs string[]|nil

-- References to watcher internals (set during watcher.start)
local _watchers = nil
local _pollers = nil
local _watchdogs = nil
local _snapshots = nil
local _last_events = nil

--- Register watcher state references for status tracking
---@param refs table References to watcher internal state tables
function M.register_refs(refs)
	_watchers = refs.watchers
	_pollers = refs.pollers
	_watchdogs = refs.watchdogs
	_snapshots = refs.snapshots
	_last_events = refs.last_events
end

--- Get status for all watched clients
---@return roslyn_filewatch.StatusInfo
function M.get_status()
	local status = {
		clients = {},
		config_summary = {
			solution_aware = config.options.solution_aware ~= false,
			respect_gitignore = config.options.respect_gitignore ~= false,
			force_polling = config.options.force_polling or false,
			batching = config.options.batching and config.options.batching.enabled or false,
			poll_interval = config.options.poll_interval or 3000,
		},
	}

	-- Find all Roslyn clients
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names or {}, client.name) then
			local client_status = {
				id = client.id,
				name = client.name,
				root = client.config and client.config.root_dir or "unknown",
				has_fs_event = _watchers and _watchers[client.id] ~= nil or false,
				has_poller = _pollers and _pollers[client.id] ~= nil or false,
				has_watchdog = _watchdogs and _watchdogs[client.id] ~= nil or false,
				file_count = 0,
				last_event = _last_events and _last_events[client.id] or nil,
				sln_file = nil,
				project_dirs = nil,
			}

			-- Count files in snapshot
			if _snapshots and _snapshots[client.id] then
				local count = 0
				for _ in pairs(_snapshots[client.id]) do
					count = count + 1
				end
				client_status.file_count = count
			end

			-- Check for solution file
			if config.options.solution_aware ~= false then
				local ok, sln_parser = pcall(require, "roslyn_filewatch.watcher.sln_parser")
				if ok and sln_parser and client_status.root then
					local sln, sln_type = sln_parser.find_sln(client_status.root)
					if sln then
						client_status.sln_file = sln
						local dirs = sln_parser.get_project_dirs(sln, sln_type)
						if dirs and #dirs > 0 then
							client_status.project_dirs = dirs
						end
					end
				end
			end

			table.insert(status.clients, client_status)
		end
	end

	return status
end

--- Format time ago string
---@param timestamp number|nil
---@return string
local function format_time_ago(timestamp)
	if not timestamp then
		return "never"
	end
	local ago = os.time() - timestamp
	if ago < 60 then
		return ago .. "s ago"
	elseif ago < 3600 then
		return math.floor(ago / 60) .. "m ago"
	else
		return math.floor(ago / 3600) .. "h ago"
	end
end

--- Show status in a floating window or print to messages
function M.show()
	local status = M.get_status()

	local lines = {
		"",
		"roslyn-filewatch Status",
		string.rep("─", 40),
		"",
		"Config:",
		"  Solution-aware: " .. (status.config_summary.solution_aware and "✓ enabled" or "✗ disabled"),
		"  Gitignore:      " .. (status.config_summary.respect_gitignore and "✓ enabled" or "✗ disabled"),
		"  Force polling:  " .. (status.config_summary.force_polling and "✓ enabled" or "✗ disabled"),
		"  Batching:       " .. (status.config_summary.batching and "✓ enabled" or "✗ disabled"),
	}

	if #status.clients == 0 then
		table.insert(lines, "")
		table.insert(lines, "No active Roslyn clients")
	else
		for _, client in ipairs(status.clients) do
			table.insert(lines, "")
			table.insert(lines, string.rep("─", 40))
			table.insert(lines, "Client: " .. client.name .. " (id: " .. client.id .. ")")
			table.insert(lines, "  Root: " .. utils.normalize_path(client.root))

			-- Watch mode
			local mode = "none"
			if client.has_fs_event and client.has_poller then
				mode = "fs_event + polling fallback"
			elseif client.has_fs_event then
				mode = "fs_event only"
			elseif client.has_poller then
				mode = "polling only"
			end
			table.insert(lines, "  Mode: " .. mode)

			-- Files and events
			table.insert(lines, "  Files watched: " .. tostring(client.file_count))
			table.insert(lines, "  Last event: " .. format_time_ago(client.last_event))

			-- Solution info
			if client.sln_file then
				local sln_name = client.sln_file:match("[^/]+$") or client.sln_file
				table.insert(lines, "  Solution: " .. sln_name)
				if client.project_dirs then
					table.insert(lines, "  Projects: " .. #client.project_dirs .. " directories")
				end
			else
				table.insert(lines, "  Solution: (none found - scanning full root)")
			end
		end
	end

	table.insert(lines, "")

	-- Print to messages
	for _, line in ipairs(lines) do
		vim.api.nvim_echo({ { line, "Normal" } }, true, {})
	end
end

return M
