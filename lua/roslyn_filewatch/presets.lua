---@class roslyn_filewatch.presets
---@field apply fun(preset_name: string, options: roslyn_filewatch.Options): roslyn_filewatch.Options
---@field detect fun(root: string): string|nil
---@field get fun(preset_name: string): roslyn_filewatch.Options|nil

---Project presets for optimizing roslyn-filewatch settings based on project type.
---Supports auto-detection of project type (Unity, console, etc.)

local M = {}

local uv = vim.uv or vim.loop

---@type table<string, roslyn_filewatch.Options>
M.presets = {
	--- Unity projects: optimized for large codebases with heavy regeneration
	unity = {
		batching = {
			enabled = true,
			interval = 500, -- More batching for Unity's many files
		},
		activity_quiet_period = 10, -- Unity regeneration can take 10-30+ seconds
		poll_interval = 10000, -- Less frequent polling
		processing_debounce_ms = 300, -- Higher debounce for regeneration storms
		-- Additional Unity-specific ignore dirs
		ignore_dirs = {
			-- Unity-specific
			"Library",
			"Temp",
			"Logs",
			"UserSettings",
			"MemoryCaptures",
			"CrashReports",
			"ScriptAssemblies",
			"bee_backend",
			"StateCache",
			"ShaderCache",
			"AssetBundleCache",
			"Recorder",
			"TextMesh Pro",
			"Plugins",
			"StreamingAssets",
			-- .NET / Build
			"Obj",
			"obj",
			"Bin",
			"bin",
			"Build",
			"Builds",
			"packages",
			"TestResults",
			-- General
			".git",
			".idea",
			".vs",
			".vscode",
			"node_modules",
		},
		-- Deferred loading helps with large Unity solutions
		deferred_loading = true,
		deferred_loading_delay_ms = 1000,
		-- Diagnostic throttling for better performance
		diagnostic_throttling = {
			enabled = true,
			debounce_ms = 1000, -- Longer debounce for Unity
			visible_only = true,
		},
	},

	--- Console/small projects: fast and responsive
	console = {
		batching = {
			enabled = true,
			interval = 200, -- Faster batching
		},
		activity_quiet_period = 3, -- Faster scans
		poll_interval = 3000, -- More responsive
		processing_debounce_ms = 100,
		deferred_loading = false, -- Immediate loading for small projects
		diagnostic_throttling = {
			enabled = true,
			debounce_ms = 300, -- Faster diagnostics
			visible_only = false, -- Full diagnostics for small projects
		},
	},

	--- Large solution: balanced settings for big non-Unity projects
	large = {
		batching = {
			enabled = true,
			interval = 400,
		},
		activity_quiet_period = 8,
		poll_interval = 8000,
		processing_debounce_ms = 200,
		deferred_loading = true,
		deferred_loading_delay_ms = 500,
		diagnostic_throttling = {
			enabled = true,
			debounce_ms = 500,
			visible_only = true,
		},
	},
}

--- Detect project type based on root directory contents
---@param root string Root directory path
---@return string|nil preset_name Detected preset name, or nil for default
function M.detect(root)
	if not root or root == "" then
		return nil
	end

	-- Normalize path
	root = root:gsub("\\", "/")
	if not root:match("/$") then
		root = root .. "/"
	end

	-- Check for Unity project markers
	local unity_markers = {
		"Assets",
		"ProjectSettings",
		"Library",
	}

	local unity_count = 0
	for _, marker in ipairs(unity_markers) do
		local stat = uv.fs_stat(root .. marker)
		if stat and stat.type == "directory" then
			unity_count = unity_count + 1
		end
	end

	-- Unity project has at least 2 of these directories
	if unity_count >= 2 then
		return "unity"
	end

	-- Check for solution file to determine project size
	local has_sln = false
	local csproj_count = 0

	local fd = uv.fs_scandir(root)
	if fd then
		while true do
			local name, typ = uv.fs_scandir_next(fd)
			if not name then
				break
			end
			if typ == "file" then
				if name:match("%.sln$") or name:match("%.slnx?$") then
					has_sln = true
				elseif name:match("%.csproj$") then
					csproj_count = csproj_count + 1
				end
			end
		end
	end

	-- Large solution (has .sln with multiple projects likely)
	if has_sln then
		-- Try to count projects in solution file
		local sln_files = vim.fn.glob(root .. "*.sln", false, true)
		if #sln_files > 0 then
			local content = vim.fn.readfile(sln_files[1])
			local project_count = 0
			for _, line in ipairs(content) do
				if line:match("^Project%(") then
					project_count = project_count + 1
				end
			end
			if project_count > 10 then
				return "large"
			end
		end
	end

	-- Simple console project
	if csproj_count <= 3 then
		return "console"
	end

	return nil -- Use default settings
end

--- Get preset options by name
---@param preset_name string Preset name
---@return roslyn_filewatch.Options|nil options Preset options, or nil if not found
function M.get(preset_name)
	return M.presets[preset_name]
end

--- Apply preset to options
---@param preset_name string Preset name ("auto", "unity", "console", "large", "none")
---@param options roslyn_filewatch.Options Current options
---@param root? string Root directory for auto-detection
---@return roslyn_filewatch.Options options Options with preset applied
function M.apply(preset_name, options, root)
	if preset_name == "none" then
		return options
	end

	local actual_preset = preset_name
	if preset_name == "auto" and root then
		actual_preset = M.detect(root) or "console"
	end

	local preset_opts = M.get(actual_preset)
	if not preset_opts then
		return options
	end

	-- Deep merge preset into options (preset has lower priority than user config)
	-- User options override preset
	local result = vim.tbl_deep_extend("force", preset_opts, options)

	-- Store which preset was applied for status display
	result._applied_preset = actual_preset

	return result
end

--- Get list of available preset names
---@return string[] preset_names List of preset names
function M.list()
	local names = { "auto", "none" }
	for name, _ in pairs(M.presets) do
		table.insert(names, name)
	end
	return names
end

return M
