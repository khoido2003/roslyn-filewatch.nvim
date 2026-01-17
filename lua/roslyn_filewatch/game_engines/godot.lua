---@class roslyn_filewatch.game_engines.godot
---@field detect fun(root: string): boolean
---@field get_project_info fun(root: string): table|nil

---Godot 4.x C# game engine integration module.
---Provides Godot-specific features:
---  - Project detection via project.godot
---  - GDScript-style naming hints
---  - Node script context

local M = {}

local uv = vim.uv or vim.loop
local config = require("roslyn_filewatch.config")

--- Normalize path separators
---@param path string
---@return string
local function normalize_path(path)
	return path:gsub("\\", "/")
end

--- Check if path is a Godot project
---@param root string
---@return boolean
function M.detect(root)
	if not root or root == "" then
		return false
	end

	root = normalize_path(root)
	if not root:match("/$") then
		root = root .. "/"
	end

	-- Check for project.godot file
	local project_godot = uv.fs_stat(root .. "project.godot")
	if project_godot and project_godot.type == "file" then
		return true
	end

	-- Check for .godot folder (Godot 4.x)
	local godot_dir = uv.fs_stat(root .. ".godot")
	if godot_dir and godot_dir.type == "directory" then
		return true
	end

	return false
end

--- Parse project.godot file for project info
---@param root string
---@return table|nil info Project info
function M.get_project_info(root)
	if not root or root == "" then
		return nil
	end

	root = normalize_path(root)
	if not root:match("/$") then
		root = root .. "/"
	end

	local project_file = root .. "project.godot"
	local fd = uv.fs_open(project_file, "r", 438)
	if not fd then
		return nil
	end

	local stat = uv.fs_fstat(fd)
	if not stat then
		uv.fs_close(fd)
		return nil
	end

	local content = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)

	if not content then
		return nil
	end

	-- Parse key project settings
	local info = {
		name = content:match('config/name="([^"]+)"') or "GodotProject",
		version = content:match('config/features=PackedStringArray%("([%d%.]+)"') or "4.0",
		has_csharp = content:match("dotnet/project/assembly_name") ~= nil,
		root = root,
	}

	-- Get C# assembly name if available
	info.assembly_name = content:match('dotnet/project/assembly_name="([^"]+)"') or info.name

	return info
end

--- Get Godot-specific Roslyn settings
---@return table settings
function M.get_analyzer_settings()
	return {
		-- Godot naming conventions (PascalCase for public, _camelCase for private)
		["dotnet_naming_rule.godot_private_field.severity"] = "suggestion",
		["dotnet_naming_symbols.godot_private_field.applicable_kinds"] = "field",
		["dotnet_naming_symbols.godot_private_field.applicable_accessibilities"] = "private",
		["dotnet_naming_style.godot_private_field.required_prefix"] = "_",
		["dotnet_naming_style.godot_private_field.capitalization"] = "camel_case",
		-- Godot export hints
		["dotnet_diagnostic.CS0649.severity"] = "none", -- Suppress "never assigned" for [Export] fields
	}
end

--- Setup Godot analyzers for a Roslyn client
---@param client vim.lsp.Client
function M.setup_analyzers(client)
	if not client or (client.is_stopped and client.is_stopped()) then
		return
	end

	local root = client.config and client.config.root_dir
	if not root then
		return
	end

	-- Only apply to Godot projects
	if not M.detect(root) then
		return
	end

	local settings = M.get_analyzer_settings()
	local project_info = M.get_project_info(root)

	local configuration = {
		settings = {
			csharp = settings,
		},
	}

	pcall(function()
		client:notify("workspace/didChangeConfiguration", configuration)
	end)

	if config.options.log_level and config.options.log_level <= vim.log.levels.DEBUG then
		local name = project_info and project_info.name or "Godot"
		vim.notify("[roslyn-filewatch] Applied Godot analyzer settings for " .. name, vim.log.levels.DEBUG)
	end
end

--- Godot asset file extensions
M.asset_extensions = {
	".tscn", -- Text scene files
	".scn", -- Binary scene files
	".tres", -- Text resource files
	".res", -- Binary resource files
	".import", -- Import files (similar to Unity .meta)
}

--- Check if a file is a Godot scene/resource that may need attention
---@param path string File path
---@return boolean is_important_asset
function M.is_important_asset(path)
	path = normalize_path(path)

	-- .import files track dependencies
	if path:match("%.import$") then
		return true
	end

	-- Resource files may contain code references
	if path:match("%.tres$") or path:match("%.res$") then
		return true
	end

	-- Scene files generally don't need LSP notifications
	return false
end

--- Check if a path should be ignored (Godot generated folders)
---@param path string File path
---@return boolean should_ignore
function M.should_ignore_path(path)
	path = normalize_path(path)

	local ignore_patterns = {
		"/.godot/",
		"/.mono/",
		"/.import/",
		"/bin/",
		"/obj/",
	}

	for _, pattern in ipairs(ignore_patterns) do
		if path:find(pattern, 1, true) then
			return true
		end
	end

	return false
end

return M
