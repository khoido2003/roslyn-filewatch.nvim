---@class roslyn_filewatch.explorer
---@field show fun()
---@field find_files fun()
---@field get_solution_structure fun(root: string): roslyn_filewatch.SolutionStructure|nil

---Solution Explorer module for browsing solution/project structure.
---Uses LAZY LOADING to prevent freezing - only scans files when needed.
---Provides Telescope picker if available, otherwise falls back to vim.ui.select.

local M = {}

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")
local utils = require("roslyn_filewatch.watcher.utils")

-- Cache for project files to avoid re-scanning
local _file_cache = {}
local _cache_timeout_ms = 30000 -- 30 seconds

--- Find project root directory
--- First tries active Roslyn client, then falls back to finding .sln/.csproj from cwd
---@return string|nil root Project root directory or nil if not found
local function find_project_root()
	-- Try active Roslyn client first
	local clients = vim.lsp.get_clients()
	for _, client in ipairs(clients) do
		if vim.tbl_contains(config.options.client_names, client.name) then
			local root = client.config and client.config.root_dir
			if root then
				return root
			end
		end
	end

	-- Fallback: Find .sln, .slnx, .slnf, or .csproj from current buffer or cwd
	local start_path = vim.fn.expand("%:p:h")
	if start_path == "" or start_path == "." then
		start_path = vim.fn.getcwd()
	end

	-- Search upward for solution or project files (fast - stops at first match)
	local solution_files = vim.fs.find(function(name, _)
		return name:match("%.sln$") or name:match("%.slnx$") or name:match("%.slnf$")
	end, {
		path = start_path,
		upward = true,
		type = "file",
		limit = 1,
	})

	if #solution_files > 0 then
		return vim.fs.dirname(solution_files[1])
	end

	-- Try .csproj as fallback
	local csproj_files = vim.fs.find(function(name, _)
		return name:match("%.csproj$")
	end, {
		path = start_path,
		upward = true,
		type = "file",
		limit = 1,
	})

	if #csproj_files > 0 then
		return vim.fs.dirname(csproj_files[1])
	end

	return vim.fn.getcwd()
end

---@class roslyn_filewatch.SolutionStructure
---@field solution_path string|nil Path to solution file
---@field solution_name string|nil Solution file name
---@field projects roslyn_filewatch.ProjectInfo[]

---@class roslyn_filewatch.ProjectInfo
---@field name string Project name
---@field path string Path to .csproj file
---@field dir string Project directory
---@field files string[]|nil Source files in project (nil = not loaded yet)

--- Normalize path separators
---@param path string
---@return string
local function normalize_path(path)
	return path:gsub("\\", "/")
end

--- Get solution structure FAST (projects only, no file scanning)
--- This returns immediately without freezing
---@param root string Root directory
---@return roslyn_filewatch.SolutionStructure|nil
function M.get_solution_structure_fast(root)
	if not root or root == "" then
		return nil
	end

	root = normalize_path(root)

	---@type roslyn_filewatch.SolutionStructure
	local structure = {
		solution_path = nil,
		solution_name = nil,
		projects = {},
	}

	-- Find solution file (fast - single file lookup)
	local sln_files = vim.fs.find(function(name, _)
		return name:match("%.slnf$") or name:match("%.slnx$") or name:match("%.sln$")
	end, {
		path = root,
		type = "file",
		limit = 1,
	})

	if #sln_files > 0 then
		structure.solution_path = normalize_path(sln_files[1])
		structure.solution_name = structure.solution_path:match("([^/]+)$")
	end

	-- Find .csproj files (fast - limited depth and count)
	local csproj_files = vim.fs.find(function(name, _)
		return name:match("%.csproj$")
	end, {
		path = root,
		type = "file",
		limit = 50, -- Limit to prevent slow scanning
	})

	for _, csproj_path in ipairs(csproj_files) do
		csproj_path = normalize_path(csproj_path)
		local csproj_name = csproj_path:match("([^/]+)%.csproj$") or csproj_path
		local project_dir = csproj_path:match("^(.+)/[^/]+$") or root

		---@type roslyn_filewatch.ProjectInfo
		local project = {
			name = csproj_name,
			path = csproj_path,
			dir = project_dir,
			files = nil, -- LAZY: don't load files yet
		}

		table.insert(structure.projects, project)
	end

	-- Sort projects by name
	table.sort(structure.projects, function(a, b)
		return a.name < b.name
	end)

	return structure
end

--- Scan project files ASYNC with chunked processing
--- Calls callback when done to avoid blocking UI
---@param project_dir string Project directory to scan
---@param callback fun(files: string[]) Callback with file list
local function scan_project_files_async(project_dir, callback)
	local files = {}
	local dirs_to_scan = { project_dir }
	local max_depth = 5
	local chunk_size = 20 -- Process 20 items then yield

	local function scan_next()
		if #dirs_to_scan == 0 then
			vim.schedule(function()
				callback(files)
			end)
			return
		end

		local current_dir = table.remove(dirs_to_scan, 1)
		local depth = current_dir.depth or 0

		if type(current_dir) == "table" then
			depth = current_dir.depth
			current_dir = current_dir.path
		end

		if depth > max_depth then
			vim.schedule(scan_next)
			return
		end

		-- Use async scandir
		uv.fs_scandir(current_dir, function(err, scanner)
			if err or not scanner then
				vim.schedule(scan_next)
				return
			end

			local count = 0
			while true do
				local name, typ = uv.fs_scandir_next(scanner)
				if not name then
					break
				end

				local full_path = normalize_path(current_dir .. "/" .. name)

				if typ == "directory" then
					local lower_name = name:lower()
					-- Check against config.ignore_dirs (exact match)
					-- Also keep hardcoded safety ignores for .git/.vs if not covered
					if name ~= ".git" and name ~= ".vs" and not config.is_ignored_dir(name) then
						-- Check against ignore_patterns
						if not utils.matches_any_pattern(full_path, config.options.ignore_patterns) then
							table.insert(dirs_to_scan, { path = full_path, depth = depth + 1 })
						end
					end
				elseif typ == "file" then
					if
						utils.should_watch_path(full_path, config.options.ignore_dirs, config.options.watch_extensions)
					then
						table.insert(files, full_path)
					end
				end

				count = count + 1
				if count >= chunk_size then
					-- Yield to UI
					vim.schedule(scan_next)
					return
				end
			end

			vim.schedule(scan_next)
		end)
	end

	scan_next()
end

--- Show solution explorer using Telescope if available
function M.show()
	-- Find root from active Roslyn client or fallback to cwd
	local root = find_project_root()

	if not root then
		vim.notify(
			"[roslyn-filewatch] No C# project found. Open a folder with .sln or .csproj files.",
			vim.log.levels.WARN
		)
		return
	end

	-- FAST: Get structure without scanning files
	local structure = M.get_solution_structure_fast(root)
	if not structure or #structure.projects == 0 then
		vim.notify("[roslyn-filewatch] No projects found in solution", vim.log.levels.WARN)
		return
	end

	-- Try Telescope first
	local has_telescope = pcall(require, "telescope.builtin")
	if has_telescope then
		M.show_telescope_projects(structure)
	else
		M.show_fallback_projects(structure)
	end
end

--- Show project picker with Telescope
---@param structure roslyn_filewatch.SolutionStructure
function M.show_telescope_projects(structure)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	-- Build project list
	local items = {}

	-- Add solution header if exists
	if structure.solution_name then
		table.insert(items, {
			display = "📦 " .. structure.solution_name,
			type = "solution",
			path = structure.solution_path,
		})
	end

	-- Add projects
	for _, project in ipairs(structure.projects) do
		table.insert(items, {
			display = "📁 " .. project.name,
			type = "project",
			path = project.path,
			dir = project.dir,
		})
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
					if selection and selection.value then
						if selection.value.type == "project" then
							-- Show files in project (async loaded)
							M.show_project_files_telescope(selection.value)
						elseif selection.value.type == "solution" then
							vim.cmd("edit " .. vim.fn.fnameescape(selection.value.path))
						end
					end
				end)
				return true
			end,
		})
		:find()
end

--- Show files in a project using Telescope (async loading)
---@param project table Project info
function M.show_project_files_telescope(project)
	vim.notify("[roslyn-filewatch] Scanning " .. project.display .. "...", vim.log.levels.INFO)

	scan_project_files_async(project.dir, function(files)
		if #files == 0 then
			vim.notify("[roslyn-filewatch] No C# files found in " .. project.display, vim.log.levels.WARN)
			return
		end

		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")

		local items = {}
		for _, file in ipairs(files) do
			local file_name = file:match("([^/]+)$") or file
			table.insert(items, {
				display = "📄 " .. file_name,
				path = file,
			})
		end

		pickers
			.new({}, {
				prompt_title = project.display:gsub("📁 ", "") .. " Files",
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
	end)
end

--- Fallback project picker using vim.ui.select
---@param structure roslyn_filewatch.SolutionStructure
function M.show_fallback_projects(structure)
	local project_names = {}
	local project_map = {}
	for _, project in ipairs(structure.projects) do
		table.insert(project_names, project.name)
		project_map[project.name] = project
	end

	vim.ui.select(project_names, {
		prompt = "Select Project:",
	}, function(choice)
		if not choice then
			return
		end

		local selected_project = project_map[choice]
		if not selected_project then
			return
		end

		-- Load files async
		vim.notify("[roslyn-filewatch] Scanning " .. choice .. "...", vim.log.levels.INFO)

		scan_project_files_async(selected_project.dir, function(files)
			if #files == 0 then
				vim.notify("[roslyn-filewatch] No C# files found in " .. choice, vim.log.levels.WARN)
				return
			end

			local file_names = {}
			local file_paths = {}
			for _, file in ipairs(files) do
				local name = file:match("([^/]+)$") or file
				table.insert(file_names, name)
				file_paths[name] = file
			end

			vim.ui.select(file_names, {
				prompt = "Select File in " .. choice .. ":",
			}, function(file_choice)
				if file_choice and file_paths[file_choice] then
					vim.cmd("edit " .. vim.fn.fnameescape(file_paths[file_choice]))
				end
			end)
		end)
	end)
end

--- Quick file finder - flat list of all C# files (async with progress)
function M.find_files()
	-- Find root from active Roslyn client or fallback to cwd
	local root = find_project_root()

	if not root then
		vim.notify(
			"[roslyn-filewatch] No C# project found. Open a folder with .sln or .csproj files.",
			vim.log.levels.WARN
		)
		return
	end

	-- Get structure first (fast)
	local structure = M.get_solution_structure_fast(root)
	if not structure or #structure.projects == 0 then
		vim.notify("[roslyn-filewatch] No projects found", vim.log.levels.WARN)
		return
	end

	vim.notify("[roslyn-filewatch] Scanning " .. #structure.projects .. " project(s)...", vim.log.levels.INFO)

	-- Collect files from all projects async
	local all_files = {}
	local projects_scanned = 0
	local total_projects = #structure.projects

	local function on_project_scanned()
		projects_scanned = projects_scanned + 1
		if projects_scanned >= total_projects then
			-- All projects scanned, show picker
			if #all_files == 0 then
				vim.notify("[roslyn-filewatch] No C# files found", vim.log.levels.WARN)
				return
			end

			-- Sort by file name
			table.sort(all_files, function(a, b)
				return a.name < b.name
			end)

			-- Show picker
			local has_telescope = pcall(require, "telescope.builtin")
			if has_telescope then
				M.show_files_telescope(all_files)
			else
				M.show_files_fallback(all_files)
			end
		end
	end

	for _, project in ipairs(structure.projects) do
		scan_project_files_async(project.dir, function(files)
			for _, file in ipairs(files) do
				table.insert(all_files, {
					path = file,
					name = file:match("([^/]+)$") or file,
					project = project.name,
				})
			end
			on_project_scanned()
		end)
	end
end

--- Show files with Telescope
---@param files table[] List of file info
function M.show_files_telescope(files)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "C# Files (" .. #files .. ")",
			finder = finders.new_table({
				results = files,
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
end

--- Show files with vim.ui.select fallback
---@param files table[] List of file info
function M.show_files_fallback(files)
	local file_displays = {}
	local path_map = {}
	for _, f in ipairs(files) do
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

--- Legacy sync version for compatibility (deprecated)
--- @deprecated Use get_solution_structure_fast instead
function M.get_solution_structure(root)
	return M.get_solution_structure_fast(root)
end

return M
