---@class roslyn_filewatch
---@field setup fun(opts?: roslyn_filewatch.Options)
---@field status fun()
---@field resync fun()
---@field reload fun()
---@field explorer fun()
---@field find_files fun()

local config = require("roslyn_filewatch.config")
local watcher = require("roslyn_filewatch.watcher")

local M = {}

--- Setup the roslyn-filewatch plugin
---@param opts? roslyn_filewatch.Options Configuration options
function M.setup(opts)
	config.setup(opts)

	vim.api.nvim_create_autocmd("LspAttach", {
		group = vim.api.nvim_create_augroup("RoslynFilewatch_LspAttach", { clear = true }),
		callback = function(args)
			local client = vim.lsp.get_client_by_id(args.data.client_id)
			if client and vim.tbl_contains(config.options.client_names, client.name) then
				watcher.start(client)
			end
		end,
	})

	-- Create user command for status display
	vim.api.nvim_create_user_command("RoslynFilewatchStatus", function()
		M.status()
	end, { desc = "Show roslyn-filewatch status" })

	-- Create user command for manual resync
	vim.api.nvim_create_user_command("RoslynFilewatchResync", function()
		M.resync()
	end, { desc = "Force resync file watcher snapshots" })

	-- Create user command for project reload
	vim.api.nvim_create_user_command("RoslynReloadProjects", function()
		M.reload()
		vim.notify("[roslyn-filewatch] Reloading all projects...", vim.log.levels.INFO)
	end, { desc = "Force reload all project files" })

	-- Create user command for game engine info
	vim.api.nvim_create_user_command("RoslynEngineInfo", function()
		M.engine_info()
	end, { desc = "Show game engine context info" })

	-- ===== DOTNET CLI COMMANDS =====
	if config.options.enable_dotnet_commands then
		-- Create user command for solution explorer
		vim.api.nvim_create_user_command("RoslynExplorer", function()
			M.explorer()
		end, { desc = "Open Solution Explorer" })

		-- Create user command for C# file finder
		vim.api.nvim_create_user_command("RoslynFiles", function()
			M.find_files()
		end, { desc = "Find C# files in solution" })

		-- Build commands
		vim.api.nvim_create_user_command("RoslynBuild", function(opts)
			local cli = require("roslyn_filewatch.dotnet_cli")

			if opts.args ~= "" then
				-- Direct argument provided
				cli.build({ configuration = opts.args })
			else
				-- Show interactive selection
				vim.ui.select({ "Debug", "Release" }, {
					prompt = "Select build configuration:",
					format_item = function(item)
						return item
					end,
				}, function(choice)
					if choice then
						cli.build({ configuration = choice })
					end
				end)
			end
		end, { desc = "Build solution/project", nargs = "?" })

		vim.api.nvim_create_user_command("RoslynRun", function(opts)
			local cli = require("roslyn_filewatch.dotnet_cli")

			if opts.args ~= "" then
				-- Direct argument provided
				cli.run({ configuration = opts.args })
			else
				-- Show interactive selection
				vim.ui.select({ "Debug", "Release" }, {
					prompt = "Select run configuration:",
					format_item = function(item)
						return item
					end,
				}, function(choice)
					if choice then
						cli.run({ configuration = choice })
					end
				end)
			end
		end, { desc = "Run project", nargs = "?" })

		vim.api.nvim_create_user_command("RoslynWatch", function()
			local cli = require("roslyn_filewatch.dotnet_cli")
			cli.watch()
		end, { desc = "Run with hot reload (dotnet watch)" })

		vim.api.nvim_create_user_command("RoslynClean", function()
			local cli = require("roslyn_filewatch.dotnet_cli")
			cli.clean()
		end, { desc = "Clean build outputs" })
	end

	-- NuGet commands
	if config.options.enable_nuget_commands then
		vim.api.nvim_create_user_command("RoslynRestore", function()
			local cli = require("roslyn_filewatch.dotnet_cli")
			cli.restore()
		end, { desc = "Restore NuGet packages" })

		vim.api.nvim_create_user_command("RoslynNuget", function(opts)
			local cli = require("roslyn_filewatch.dotnet_cli")

			if opts.args ~= "" then
				-- Direct argument provided
				cli.nuget_add(opts.args)
			else
				-- Show interactive input
				vim.ui.input({ prompt = "Enter NuGet package name: " }, function(package_name)
					if package_name and package_name ~= "" then
						cli.nuget_add(package_name)
					end
				end)
			end
		end, { desc = "Add NuGet package", nargs = "?" })

		vim.api.nvim_create_user_command("RoslynNugetRemove", function(opts)
			local cli = require("roslyn_filewatch.dotnet_cli")

			if opts.args ~= "" then
				-- Direct argument provided
				cli.nuget_remove(opts.args)
			else
				-- Find nearest csproj and show installed packages
				local csproj_files = vim.fs.find(function(name, _)
					return name:match("%.csproj$")
				end, {
					path = vim.fn.expand("%:p:h"),
					upward = true,
					type = "file",
					limit = 1,
				})

				if #csproj_files == 0 then
					vim.notify("[roslyn-filewatch] No .csproj found", vim.log.levels.WARN)
					return
				end

				local packages = cli.get_installed_packages(csproj_files[1])

				if #packages == 0 then
					vim.notify("[roslyn-filewatch] No packages installed", vim.log.levels.INFO)
					return
				end

				vim.ui.select(packages, {
					prompt = "Select package to remove:",
					format_item = function(item)
						return item
					end,
				}, function(choice)
					if choice then
						cli.nuget_remove(choice)
					end
				end)
			end
		end, { desc = "Remove NuGet package", nargs = "?" })
	end

	-- Project commands
	if config.options.enable_dotnet_commands then
		vim.api.nvim_create_user_command("RoslynNewProject", function(opts)
			local cli = require("roslyn_filewatch.dotnet_cli")

			if opts.args ~= "" then
				-- Direct arguments provided
				local args = vim.split(opts.args, " ")
				cli.new_project(args[1], args[2])
			else
				-- Show interactive template selection
				local templates = cli.get_common_templates()
				local template_items = vim.tbl_map(function(t)
					return string.format("%s (%s) - %s", t.name, t.short, t.desc)
				end, templates)

				vim.ui.select(template_items, {
					prompt = "Select project template:",
					format_item = function(item)
						return item
					end,
				}, function(choice, idx)
					if not choice then
						return
					end

					local selected_template = templates[idx]

					-- Now prompt for project name
					vim.ui.input({
						prompt = "Enter project name (optional): ",
					}, function(project_name)
						cli.new_project(selected_template.short, project_name)
					end)
				end)
			end
		end, { desc = "Create new project (template [name])", nargs = "*" })

		vim.api.nvim_create_user_command("RoslynTemplates", function()
			local cli = require("roslyn_filewatch.dotnet_cli")
			cli.list_templates()
		end, { desc = "List available project templates" })

		vim.api.nvim_create_user_command("RoslynOpenCsproj", function()
			local cli = require("roslyn_filewatch.dotnet_cli")
			cli.open_csproj()
		end, { desc = "Open nearest .csproj file" })

		vim.api.nvim_create_user_command("RoslynOpenSln", function()
			local cli = require("roslyn_filewatch.dotnet_cli")
			cli.open_sln()
		end, { desc = "Open solution file" })
	end

	-- Snippet commands
	if config.options.enable_snippets then
		vim.api.nvim_create_user_command("RoslynSnippets", function()
			local snippets = require("roslyn_filewatch.snippets")
			snippets.show_snippets()
		end, { desc = "Show available C# snippets" })

		vim.api.nvim_create_user_command("RoslynLoadSnippets", function()
			local snippets = require("roslyn_filewatch.snippets")
			snippets.setup_luasnip()
		end, { desc = "Load snippets into LuaSnip" })
	end
end

--- Show current watcher status
function M.status()
	local ok, status_mod = pcall(require, "roslyn_filewatch.status")
	if ok and status_mod and status_mod.show then
		status_mod.show()
	else
		vim.notify("[roslyn-filewatch] Status module not available", vim.log.levels.ERROR)
	end
end

--- Force resync for all active clients
function M.resync()
	if watcher and watcher.resync then
		watcher.resync()
	else
		vim.notify("[roslyn-filewatch] Watcher module not available", vim.log.levels.ERROR)
	end
end

--- Force reload all Roslyn projects
function M.reload()
	if watcher and watcher.reload_projects then
		watcher.reload_projects()
	else
		vim.notify("[roslyn-filewatch] Reload not available", vim.log.levels.ERROR)
	end
end

--- Open Solution Explorer
function M.explorer()
	local ok, explorer_mod = pcall(require, "roslyn_filewatch.explorer")
	if ok and explorer_mod and explorer_mod.show then
		explorer_mod.show()
	else
		vim.notify("[roslyn-filewatch] Explorer module not available", vim.log.levels.ERROR)
	end
end

--- Find C# files in solution
function M.find_files()
	local ok, explorer_mod = pcall(require, "roslyn_filewatch.explorer")
	if ok and explorer_mod and explorer_mod.find_files then
		explorer_mod.find_files()
	else
		vim.notify("[roslyn-filewatch] Explorer module not available", vim.log.levels.ERROR)
	end
end

--- Show game engine context info
function M.engine_info()
	local ok, context_mod = pcall(require, "roslyn_filewatch.game_context")
	if not ok or not context_mod then
		vim.notify("[roslyn-filewatch] Game context module not available", vim.log.levels.ERROR)
		return
	end

	-- Find root from active client
	local root = nil
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			root = client.config and client.config.root_dir
			break
		end
	end

	if not root then
		root = vim.fn.getcwd()
	end

	local info = context_mod.get_info(root)
	if not info then
		vim.notify("[roslyn-filewatch] No game engine detected", vim.log.levels.INFO)
		return
	end

	-- Display engine info
	local lines = {}
	table.insert(lines, "")
	table.insert(lines, "Game Engine: " .. info.engine:upper())
	table.insert(lines, string.rep("─", 30))

	if info.engine == "unity" and info.assembly_definitions then
		table.insert(lines, "Assembly Definitions: " .. #info.assembly_definitions)
		for _, asmdef in ipairs(info.assembly_definitions) do
			table.insert(lines, "  📦 " .. asmdef.name)
		end
	elseif info.engine == "godot" and info.project_info then
		table.insert(lines, "Project: " .. info.project_info.name)
		table.insert(lines, "Version: Godot " .. info.project_info.version)
		table.insert(lines, "Assembly: " .. info.project_info.assembly_name)
	end

	table.insert(lines, "")

	for _, line in ipairs(lines) do
		vim.api.nvim_echo({ { line, "Normal" } }, true, {})
	end
end

--- Get current configuration options
---@return roslyn_filewatch.Options
function M.get_config()
	return config.options
end

--- Get available presets
---@return string[]
function M.get_presets()
	local ok, presets = pcall(require, "roslyn_filewatch.presets")
	if ok and presets and presets.list then
		return presets.list()
	end
	return {}
end

return M
