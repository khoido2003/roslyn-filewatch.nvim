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
			fd_available = (vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1),
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
					else
						-- No solution found, check if there are .csproj files
						local csproj_files = sln_parser.find_csproj_files(client_status.root)
						if csproj_files and #csproj_files > 0 then
							client_status.has_csproj = true
						else
							-- No .sln, no .csproj - might need dotnet restore/init
							client_status.missing_project = true
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

	--- Helper to echo a line with optional highlight
	---@param text string
	---@param hl string|nil Highlight group name
	local function echo(text, hl)
		vim.api.nvim_echo({ { text, hl or "Normal" } }, true, {})
	end

	--- Helper to echo multiple segments with different highlights
	---@param segments table[] Array of {text, hl} pairs
	local function echo_multi(segments)
		local formatted = {}
		for _, seg in ipairs(segments) do
			table.insert(formatted, { seg[1], seg[2] or "Normal" })
		end
		vim.api.nvim_echo(formatted, true, {})
	end

	-- Header
	echo("")
	echo("roslyn-filewatch Status", "Title")
	echo(string.rep("─", 40), "Comment")
	echo("")

	-- Config section
	echo("Config:", "Bold")
	local function config_line(label, enabled)
		if enabled then
			echo_multi({
				{ "  " .. label .. ": ", "Normal" },
				{ "✓ enabled", "DiagnosticOk" },
			})
		else
			echo_multi({
				{ "  " .. label .. ": ", "Normal" },
				{ "✗ disabled", "Comment" },
			})
		end
	end
	config_line("Solution-aware", status.config_summary.solution_aware)
	config_line("Gitignore     ", status.config_summary.respect_gitignore)
	config_line("Force polling ", status.config_summary.force_polling)
	config_line("Batching      ", status.config_summary.batching)
	config_line("Diag throttle ", config.options.diagnostic_throttling and config.options.diagnostic_throttling.enabled)
	config_line("fd Integration", status.config_summary.fd_available)

	-- Show applied preset
	local applied_preset = config.options._applied_preset
	if applied_preset then
		echo_multi({
			{ "  Preset        : ", "Normal" },
			{ applied_preset, "String" },
		})
	end

	if #status.clients == 0 then
		echo("")
		echo("No active Roslyn clients", "WarningMsg")
	else
		for _, client in ipairs(status.clients) do
			echo("")
			echo(string.rep("─", 40), "Comment")
			echo_multi({
				{ "Client: ", "Normal" },
				{ client.name, "Identifier" },
				{ " (id: " .. client.id .. ")", "Comment" },
			})
			echo("  Root: " .. utils.normalize_path(client.root), "Normal")

			-- Watch mode
			local mode = "none"
			if client.has_fs_event and client.has_poller then
				mode = "fs_event + polling fallback"
			elseif client.has_fs_event then
				mode = "fs_event only"
			elseif client.has_poller then
				mode = "polling only"
			end
			echo("  Mode: " .. mode, "Normal")

			-- Files and events
			echo_multi({
				{ "  Files watched: ", "Normal" },
				{ tostring(client.file_count), "Number" },
			})
			echo_multi({
				{ "  Last event: ", "Normal" },
				{ format_time_ago(client.last_event), "Comment" },
			})

			-- Solution info
			if client.sln_file then
				local sln_name = client.sln_file:match("[^/]+$") or client.sln_file
				echo_multi({
					{ "  Solution: ", "Normal" },
					{ sln_name, "String" },
				})
				if client.project_dirs then
					echo("  Projects: " .. #client.project_dirs .. " directories", "Normal")
				end
			elseif client.has_csproj then
				echo("  Solution: (none found - using .csproj files)", "Comment")
			elseif client.missing_project then
				echo("  Solution: (none found - scanning full root)", "Comment")
				echo("")
				echo("  ⚠ No .sln or .csproj found!", "WarningMsg")
				echo("  IntelliSense may be limited. To fix, run:", "Comment")
				echo("    dotnet new console   (for new projects)", "Comment")
				echo("    dotnet restore       (if project exists)", "Comment")
			else
				echo("  Solution: (none found - scanning full root)", "Comment")
			end
		end
	end

	echo("")
end

return M
