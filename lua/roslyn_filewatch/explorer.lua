---@class roslyn_filewatch.explorer
---@field show fun()
---@field get_solution_structure fun(root: string): roslyn_filewatch.SolutionStructure|nil

---Solution Explorer module for browsing solution/project structure.
---Provides Telescope picker if available, otherwise falls back to vim.ui.select.

local M = {}

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

---@class roslyn_filewatch.SolutionStructure
---@field solution_path string|nil Path to solution file
---@field solution_name string|nil Solution file name
---@field projects roslyn_filewatch.ProjectInfo[]

---@class roslyn_filewatch.ProjectInfo
---@field name string Project name
---@field path string Path to .csproj file
---@field dir string Project directory
---@field files string[] Source files in project

--- Normalize path separators
---@param path string
---@return string
local function normalize_path(path)
	return path:gsub("\\", "/")
end

--- Get file extension
---@param path string
---@return string|nil
local function get_extension(path)
	return path:match("%.([^%.]+)$")
end

--- Parse .csproj file to get source files
---@param csproj_path string
---@return string[] files List of source file paths
local function parse_csproj_files(csproj_path)
	local files = {}
	local project_dir = normalize_path(csproj_path):match("^(.+)/[^/]+$") or "."

	-- Read csproj content
	local ok, content = pcall(function()
		local fd = uv.fs_open(csproj_path, "r", 438)
		if not fd then
			return nil
		end
		local stat = uv.fs_fstat(fd)
		if not stat then
			uv.fs_close(fd)
			return nil
		end
		local data = uv.fs_read(fd, stat.size, 0)
		uv.fs_close(fd)
		return data
	end)

	if not ok or not content then
		-- Fallback: scan directory for .cs files
		local scanner = uv.fs_scandir(project_dir)
		if scanner then
			while true do
				local name, typ = uv.fs_scandir_next(scanner)
				if not name then
					break
				end
				if typ == "file" and name:match("%.cs$") then
					table.insert(files, normalize_path(project_dir .. "/" .. name))
				end
			end
		end
		return files
	end

	-- Try to parse Compile includes (older format)
	for include_path in content:gmatch('<Compile%s+Include="([^"]+)"') do
		local full_path = normalize_path(project_dir .. "/" .. include_path)
		table.insert(files, full_path)
	end

	-- For SDK-style projects, scan directory for .cs files
	-- (SDK-style includes all .cs files by default)
	if content:match('Sdk="Microsoft%.NET%.Sdk') or content:match("<TargetFramework") then
		local function scan_dir_recursive(dir, depth)
			if depth > 5 then
				return
			end -- Limit recursion
			local scanner = uv.fs_scandir(dir)
			if not scanner then
				return
			end

			while true do
				local name, typ = uv.fs_scandir_next(scanner)
				if not name then
					break
				end

				local full_path = normalize_path(dir .. "/" .. name)

				if typ == "directory" then
					-- Skip common ignore dirs
					local lower_name = name:lower()
					if lower_name ~= "obj" and lower_name ~= "bin" and not name:match("^%.") then
						scan_dir_recursive(full_path, depth + 1)
					end
				elseif typ == "file" and name:match("%.cs$") then
					-- Avoid duplicates
					local found = false
					for _, f in ipairs(files) do
						if f == full_path then
							found = true
							break
						end
					end
					if not found then
						table.insert(files, full_path)
					end
				end
			end
		end

		scan_dir_recursive(project_dir, 0)
	end

	return files
end

--- Get solution structure for a root directory
---@param root string Root directory
---@return roslyn_filewatch.SolutionStructure|nil
function M.get_solution_structure(root)
	if not root or root == "" then
		return nil
	end

	root = normalize_path(root)

	local ok, sln_parser = pcall(require, "roslyn_filewatch.watcher.sln_parser")
	if not ok or not sln_parser then
		return nil
	end

	---@type roslyn_filewatch.SolutionStructure
	local structure = {
		solution_path = nil,
		solution_name = nil,
		projects = {},
	}

	-- Find solution file
	local sln_path, sln_type = sln_parser.find_sln(root)
	if sln_path then
		structure.solution_path = sln_path
		structure.solution_name = sln_path:match("([^/]+)$")
	end

	-- Get project directories
	local csproj_files = sln_parser.find_csproj_files(root)

	for _, csproj_path in ipairs(csproj_files) do
		local csproj_name = csproj_path:match("([^/]+)%.csproj$") or csproj_path
		local project_dir = normalize_path(csproj_path):match("^(.+)/[^/]+$") or root

		---@type roslyn_filewatch.ProjectInfo
		local project = {
			name = csproj_name,
			path = csproj_path,
			dir = project_dir,
			files = parse_csproj_files(csproj_path),
		}

		table.insert(structure.projects, project)
	end

	-- Sort projects by name
	table.sort(structure.projects, function(a, b)
		return a.name < b.name
	end)

	return structure
end

--- Show solution explorer using Telescope if available
function M.show()
	-- Find root from active Roslyn client
	local root = nil
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			root = client.config and client.config.root_dir
			break
		end
	end

	if not root then
		vim.notify("[roslyn-filewatch] No active Roslyn client found", vim.log.levels.WARN)
		return
	end

	local structure = M.get_solution_structure(root)
	if not structure or #structure.projects == 0 then
		vim.notify("[roslyn-filewatch] No projects found in solution", vim.log.levels.WARN)
		return
	end

	-- Try Telescope first
	local has_telescope, telescope = pcall(require, "telescope.builtin")
	local has_pickers, pickers = pcall(require, "telescope.pickers")
	local has_finders, finders = pcall(require, "telescope.finders")
	local has_conf, conf = pcall(function()
		return require("telescope.config").values
	end)
	local has_actions, actions = pcall(require, "telescope.actions")
	local has_action_state, action_state = pcall(require, "telescope.actions.state")

	if has_telescope and has_pickers and has_finders and has_conf and has_actions and has_action_state then
		M.show_telescope(structure, pickers, finders, conf, actions, action_state)
	else
		M.show_fallback(structure)
	end
end

--- Show solution explorer with Telescope
---@param structure roslyn_filewatch.SolutionStructure
function M.show_telescope(structure, pickers, finders, conf, actions, action_state)
	-- Build flat list of items
	local items = {}

	-- Add solution header if exists
	if structure.solution_name then
		table.insert(items, {
			display = "📦 " .. structure.solution_name,
			type = "solution",
			path = structure.solution_path,
		})
	end

	-- Add projects and files
	for _, project in ipairs(structure.projects) do
		table.insert(items, {
			display = "  📁 " .. project.name,
			type = "project",
			path = project.path,
		})

		for _, file in ipairs(project.files) do
			local file_name = file:match("([^/]+)$") or file
			table.insert(items, {
				display = "    📄 " .. file_name,
				type = "file",
				path = file,
			})
		end
	end

	pickers
		.new({}, {
			prompt_title = "Solution Explorer",
			finder = finders.new_table({
				results = items,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display,
						ordinal = entry.display,
						path = entry.path,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection and selection.value.path then
						if selection.value.type == "file" then
							vim.cmd("edit " .. vim.fn.fnameescape(selection.value.path))
						elseif selection.value.type == "project" then
							-- Open project directory in file explorer or show files
							local project_dir = selection.value.path:match("^(.+)/[^/]+$")
							if project_dir then
								vim.cmd("edit " .. vim.fn.fnameescape(project_dir))
							end
						end
					end
				end)
				return true
			end,
		})
		:find()
end

--- Fallback solution explorer using vim.ui.select
---@param structure roslyn_filewatch.SolutionStructure
function M.show_fallback(structure)
	-- First, show project selection
	local project_names = {}
	for _, project in ipairs(structure.projects) do
		table.insert(project_names, project.name)
	end

	vim.ui.select(project_names, {
		prompt = "Select Project:",
	}, function(choice)
		if not choice then
			return
		end

		-- Find selected project
		local selected_project = nil
		for _, project in ipairs(structure.projects) do
			if project.name == choice then
				selected_project = project
				break
			end
		end

		if not selected_project then
			return
		end

		-- Show files in project
		local file_names = {}
		local file_paths = {}
		for _, file in ipairs(selected_project.files) do
			local name = file:match("([^/]+)$") or file
			table.insert(file_names, name)
			file_paths[name] = file
		end

		vim.ui.select(file_names, {
			prompt = "Select File in " .. selected_project.name .. ":",
		}, function(file_choice)
			if file_choice and file_paths[file_choice] then
				vim.cmd("edit " .. vim.fn.fnameescape(file_paths[file_choice]))
			end
		end)
	end)
end

--- Quick file finder - flat list of all C# files
function M.find_files()
	-- Find root from active Roslyn client
	local root = nil
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			root = client.config and client.config.root_dir
			break
		end
	end

	if not root then
		vim.notify("[roslyn-filewatch] No active Roslyn client found", vim.log.levels.WARN)
		return
	end

	local structure = M.get_solution_structure(root)
	if not structure or #structure.projects == 0 then
		vim.notify("[roslyn-filewatch] No projects found", vim.log.levels.WARN)
		return
	end

	-- Collect all files
	local all_files = {}
	for _, project in ipairs(structure.projects) do
		for _, file in ipairs(project.files) do
			table.insert(all_files, {
				path = file,
				name = file:match("([^/]+)$") or file,
				project = project.name,
			})
		end
	end

	-- Sort by file name
	table.sort(all_files, function(a, b)
		return a.name < b.name
	end)

	-- Try Telescope
	local has_telescope = pcall(require, "telescope.builtin")
	if has_telescope then
		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")

		pickers
			.new({}, {
				prompt_title = "C# Files",
				finder = finders.new_table({
					results = all_files,
					entry_maker = function(entry)
						return {
							value = entry,
							display = entry.name .. " (" .. entry.project .. ")",
							ordinal = entry.name .. " " .. entry.project,
							path = entry.path,
						}
					end,
				}),
				sorter = conf.generic_sorter({}),
				previewer = conf.file_previewer({}),
				attach_mappings = function(prompt_bufnr, map)
					actions.select_default:replace(function()
						actions.close(prompt_bufnr)
						local selection = action_state.get_selected_entry()
						if selection and selection.value.path then
							vim.cmd("edit " .. vim.fn.fnameescape(selection.value.path))
						end
					end)
					return true
				end,
			})
			:find()
	else
		-- Fallback
		local file_displays = {}
		local path_map = {}
		for _, f in ipairs(all_files) do
			local display = f.name .. " (" .. f.project .. ")"
			table.insert(file_displays, display)
			path_map[display] = f.path
		end

		vim.ui.select(file_displays, {
			prompt = "Select C# File:",
		}, function(choice)
			if choice and path_map[choice] then
				vim.cmd("edit " .. vim.fn.fnameescape(path_map[choice]))
			end
		end)
	end
end

return M
