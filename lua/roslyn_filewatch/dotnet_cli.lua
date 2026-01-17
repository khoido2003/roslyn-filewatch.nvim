---@class roslyn_filewatch.dotnet_cli
---@field build fun(opts?: table)
---@field run fun(opts?: table)
---@field watch fun(opts?: table)
---@field clean fun(opts?: table)
---@field restore fun(opts?: table)
---@field nuget_add fun(package: string, opts?: table)
---@field nuget_remove fun(package: string, opts?: table)
---@field new_project fun(template: string, name?: string, opts?: table)
---@field add_project fun(path: string, opts?: table)

---dotnet CLI integration for common development tasks.
---Provides commands for build, run, NuGet, and project management.

local M = {}

local config = require("roslyn_filewatch.config")

--- Normalize path separators
---@param path string
---@return string
local function normalize_path(path)
	return path:gsub("\\", "/")
end

--- Find project root (solution or csproj directory)
---@return string|nil root
local function find_project_root()
	-- Try active Roslyn client first
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			local root = client.config and client.config.root_dir
			if root then
				return normalize_path(root)
			end
		end
	end

	-- Fallback: Find .sln or .csproj from cwd
	local start_path = vim.fn.expand("%:p:h")
	if start_path == "" or start_path == "." then
		start_path = vim.fn.getcwd()
	end

	local solution_files = vim.fs.find(function(name, _)
		return name:match("%.sln$") or name:match("%.slnx$") or name:match("%.csproj$")
	end, {
		path = start_path,
		upward = true,
		type = "file",
		limit = 1,
	})

	if #solution_files > 0 then
		return vim.fs.dirname(solution_files[1])
	end

	return vim.fn.getcwd()
end

--- Find the nearest .csproj file to current buffer
---@return string|nil csproj_path
local function find_nearest_csproj()
	local buf_path = vim.fn.expand("%:p:h")
	if buf_path == "" then
		buf_path = vim.fn.getcwd()
	end

	local csproj_files = vim.fs.find(function(name, _)
		return name:match("%.csproj$")
	end, {
		path = buf_path,
		upward = true,
		type = "file",
		limit = 1,
	})

	if #csproj_files > 0 then
		return normalize_path(csproj_files[1])
	end

	return nil
end

--- Run a dotnet command in a terminal
---@param cmd string Command to run
---@param opts? table Options: { cwd?: string, title?: string }
local function run_dotnet_cmd(cmd, opts)
	opts = opts or {}
	local cwd = opts.cwd or find_project_root()
	local title = opts.title or "dotnet"

	-- Create a new terminal buffer
	vim.cmd("botright split")
	vim.cmd("terminal")
	local term_buf = vim.api.nvim_get_current_buf()

	-- Set buffer name
	vim.api.nvim_buf_set_name(term_buf, "[" .. title .. "]")

	-- Send the command
	local term_chan = vim.b[term_buf].terminal_job_id
	if term_chan then
		vim.fn.chansend(term_chan, "cd " .. vim.fn.shellescape(cwd) .. "\n")
		vim.fn.chansend(term_chan, cmd .. "\n")
	end

	-- Resize terminal
	vim.cmd("resize 15")
end

--- Run dotnet command and capture output (async)
---@param args string[] Command arguments
---@param opts? table Options: { cwd?: string, on_exit?: fun(code: number, output: string) }
local function run_dotnet_async(args, opts)
	opts = opts or {}
	local cwd = opts.cwd or find_project_root()

	local output = {}
	local cmd = vim.list_extend({ "dotnet" }, args)

	vim.fn.jobstart(cmd, {
		cwd = cwd,
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if data then
				vim.list_extend(output, data)
			end
		end,
		on_stderr = function(_, data)
			if data then
				vim.list_extend(output, data)
			end
		end,
		on_exit = function(_, code)
			if opts.on_exit then
				opts.on_exit(code, table.concat(output, "\n"))
			end
		end,
	})
end

--------------------------------------------------
-- BUILD COMMANDS
--------------------------------------------------

--- Build the solution/project
---@param opts? table Options: { configuration?: string, project?: string }
function M.build(opts)
	opts = opts or {}
	local cmd = "dotnet build"

	if opts.project then
		cmd = cmd .. " " .. vim.fn.shellescape(opts.project)
	end

	if opts.configuration then
		cmd = cmd .. " -c " .. opts.configuration
	end

	run_dotnet_cmd(cmd, { title = "dotnet build" })
end

--- Run the project
---@param opts? table Options: { configuration?: string, project?: string }
function M.run(opts)
	opts = opts or {}
	local cmd = "dotnet run"

	if opts.project then
		cmd = cmd .. " --project " .. vim.fn.shellescape(opts.project)
	end

	if opts.configuration then
		cmd = cmd .. " -c " .. opts.configuration
	end

	run_dotnet_cmd(cmd, { title = "dotnet run" })
end

--- Watch and run with hot reload
---@param opts? table Options: { project?: string }
function M.watch(opts)
	opts = opts or {}
	local cmd = "dotnet watch run"

	if opts.project then
		cmd = cmd .. " --project " .. vim.fn.shellescape(opts.project)
	end

	run_dotnet_cmd(cmd, { title = "dotnet watch" })
end

--- Clean build outputs
---@param opts? table Options: { project?: string }
function M.clean(opts)
	opts = opts or {}
	local cmd = "dotnet clean"

	if opts.project then
		cmd = cmd .. " " .. vim.fn.shellescape(opts.project)
	end

	run_dotnet_cmd(cmd, { title = "dotnet clean" })
end

--------------------------------------------------
-- NUGET COMMANDS
--------------------------------------------------

--- Restore NuGet packages
---@param opts? table Options: { project?: string }
function M.restore(opts)
	opts = opts or {}
	local cmd = "dotnet restore"

	if opts.project then
		cmd = cmd .. " " .. vim.fn.shellescape(opts.project)
	end

	run_dotnet_cmd(cmd, { title = "dotnet restore" })
end

--- Add a NuGet package
---@param package string Package name
---@param opts? table Options: { version?: string, project?: string }
function M.nuget_add(package, opts)
	if not package or package == "" then
		vim.notify("[roslyn-filewatch] Package name required", vim.log.levels.ERROR)
		return
	end

	opts = opts or {}
	local project = opts.project or find_nearest_csproj()

	if not project then
		vim.notify("[roslyn-filewatch] No .csproj found", vim.log.levels.ERROR)
		return
	end

	local cmd = "dotnet add " .. vim.fn.shellescape(project) .. " package " .. package

	if opts.version then
		cmd = cmd .. " --version " .. opts.version
	end

	run_dotnet_cmd(cmd, { title = "NuGet add " .. package })
end

--- Remove a NuGet package
---@param package string Package name
---@param opts? table Options: { project?: string }
function M.nuget_remove(package, opts)
	if not package or package == "" then
		vim.notify("[roslyn-filewatch] Package name required", vim.log.levels.ERROR)
		return
	end

	opts = opts or {}
	local project = opts.project or find_nearest_csproj()

	if not project then
		vim.notify("[roslyn-filewatch] No .csproj found", vim.log.levels.ERROR)
		return
	end

	local cmd = "dotnet remove " .. vim.fn.shellescape(project) .. " package " .. package

	run_dotnet_cmd(cmd, { title = "NuGet remove " .. package })
end

--------------------------------------------------
-- PROJECT COMMANDS
--------------------------------------------------

--- Create a new project
---@param template string Template name (console, webapi, classlib, etc.)
---@param name? string Project name
---@param opts? table Options: { output?: string }
function M.new_project(template, name, opts)
	if not template or template == "" then
		vim.notify("[roslyn-filewatch] Template required (console, webapi, classlib, etc.)", vim.log.levels.ERROR)
		return
	end

	opts = opts or {}
	local cmd = "dotnet new " .. template

	if name and name ~= "" then
		cmd = cmd .. " -n " .. name
	end

	if opts.output then
		cmd = cmd .. " -o " .. vim.fn.shellescape(opts.output)
	end

	run_dotnet_cmd(cmd, { title = "dotnet new " .. template })
end

--- Add project to solution
---@param project_path string Path to .csproj file
---@param opts? table Options: { solution?: string }
function M.add_project(project_path, opts)
	if not project_path or project_path == "" then
		vim.notify("[roslyn-filewatch] Project path required", vim.log.levels.ERROR)
		return
	end

	opts = opts or {}
	local root = find_project_root()

	-- Find solution file
	local sln_files = vim.fs.find(function(name, _)
		return name:match("%.sln$") or name:match("%.slnx$")
	end, {
		path = root,
		type = "file",
		limit = 1,
	})

	local solution = opts.solution
	if not solution and #sln_files > 0 then
		solution = sln_files[1]
	end

	if not solution then
		vim.notify("[roslyn-filewatch] No solution file found", vim.log.levels.ERROR)
		return
	end

	local cmd = "dotnet sln " .. vim.fn.shellescape(solution) .. " add " .. vim.fn.shellescape(project_path)

	run_dotnet_cmd(cmd, { title = "Add to solution" })
end

--- Open the nearest .csproj file
function M.open_csproj()
	local csproj = find_nearest_csproj()
	if csproj then
		vim.cmd("edit " .. vim.fn.fnameescape(csproj))
	else
		vim.notify("[roslyn-filewatch] No .csproj found", vim.log.levels.WARN)
	end
end

--- Open the solution file
function M.open_sln()
	local root = find_project_root()

	local sln_files = vim.fs.find(function(name, _)
		return name:match("%.sln$") or name:match("%.slnx$")
	end, {
		path = root,
		type = "file",
		limit = 1,
	})

	if #sln_files > 0 then
		vim.cmd("edit " .. vim.fn.fnameescape(sln_files[1]))
	else
		vim.notify("[roslyn-filewatch] No solution file found", vim.log.levels.WARN)
	end
end

--- List available dotnet templates
function M.list_templates()
	run_dotnet_async({ "new", "list", "--columns", "name,shortName" }, {
		on_exit = function(code, output)
			if code == 0 then
				vim.schedule(function()
					-- Show in a floating window
					local lines = vim.split(output, "\n")
					local buf = vim.api.nvim_create_buf(false, true)
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

					local width = 80
					local height = math.min(#lines, 20)

					vim.api.nvim_open_win(buf, true, {
						relative = "editor",
						width = width,
						height = height,
						col = (vim.o.columns - width) / 2,
						row = (vim.o.lines - height) / 2,
						style = "minimal",
						border = "rounded",
						title = " dotnet Templates ",
						title_pos = "center",
					})

					-- Close on q or Escape
					vim.keymap.set("n", "q", ":close<CR>", { buffer = buf, silent = true })
					vim.keymap.set("n", "<Esc>", ":close<CR>", { buffer = buf, silent = true })
				end)
			end
		end,
	})
end

--- Get list of installed NuGet packages from a csproj file
---@param csproj_path string Path to .csproj file
---@return string[] packages List of package names
function M.get_installed_packages(csproj_path)
	local packages = {}

	if not csproj_path or not vim.fn.filereadable(csproj_path) then
		return packages
	end

	local content = vim.fn.readfile(csproj_path)
	for _, line in ipairs(content) do
		-- Match <PackageReference Include="PackageName" .../>
		local package_name = line:match('<PackageReference%s+Include="([^"]+)"')
		if package_name then
			table.insert(packages, package_name)
		end
	end

	return packages
end

--- Get list of common dotnet templates
---@return table[] templates List of {name, short_name, description}
function M.get_common_templates()
	return {
		{ name = "Console Application", short = "console", desc = "A project for creating a command-line application" },
		{ name = "Class Library", short = "classlib", desc = "A project for creating a class library" },
		{ name = "ASP.NET Core Web App", short = "web", desc = "A project for creating an ASP.NET Core web app" },
		{ name = "ASP.NET Core Web API", short = "webapi", desc = "A project for creating an ASP.NET Core Web API" },
		{ name = "ASP.NET Core MVC", short = "mvc", desc = "A project for creating an ASP.NET Core MVC web app" },
		{ name = "Blazor Server App", short = "blazorserver", desc = "A project for creating a Blazor Server app" },
		{
			name = "Blazor WebAssembly App",
			short = "blazorwasm",
			desc = "A project for creating a Blazor WebAssembly app",
		},
		{ name = "xUnit Test Project", short = "xunit", desc = "A project for creating xUnit tests" },
		{ name = "NUnit Test Project", short = "nunit", desc = "A project for creating NUnit tests" },
		{ name = "MSTest Test Project", short = "mstest", desc = "A project for creating MSTest tests" },
	}
end

return M
