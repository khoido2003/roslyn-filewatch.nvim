---@class roslyn_filewatch.diagnostics
---@field throttle fun(client_id: number, bufnr: number): boolean
---@field request_diagnostics fun(client_id: number, bufnr: number)
---@field set_activity fun(active: boolean)

---Diagnostic throttling module for reducing LSP load during heavy editing.
---Debounces diagnostic requests and optionally limits to visible buffers.

local M = {}

local config = require("roslyn_filewatch.config")
local uv = vim.uv or vim.loop

---@type table<string, number> Key: "client_id:bufnr", Value: last request timestamp (ms)
local last_request_times = {}

---@type table<string, uv_timer_t|nil> Key: "client_id:bufnr", Value: pending timer
local pending_timers = {}

---@type boolean Whether heavy file activity is ongoing
local heavy_activity = false

---@type number Last heavy activity timestamp
local last_activity_time = 0

--- Get throttling options from config
---@return { enabled: boolean, debounce_ms: number, visible_only: boolean }
local function get_throttle_opts()
	local opts = config.options.diagnostic_throttling or {}
	return {
		enabled = opts.enabled ~= false, -- Default: enabled
		debounce_ms = opts.debounce_ms or 500,
		visible_only = opts.visible_only ~= false, -- Default: true
	}
end

--- Generate cache key for client/buffer pair
---@param client_id number
---@param bufnr number
---@return string
local function make_key(client_id, bufnr)
	return string.format("%d:%d", client_id, bufnr)
end

--- Check if buffer is visible in any window
---@param bufnr number
---@return boolean
local function is_buffer_visible(bufnr)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == bufnr then
			return true
		end
	end
	return false
end

--- Set heavy activity flag (called by watcher during file events)
---@param active boolean
function M.set_activity(active)
	heavy_activity = active
	if active then
		last_activity_time = uv.now()
	end
end

--- Check if currently in heavy activity period
---@return boolean
function M.is_heavy_activity()
	if not heavy_activity then
		return false
	end
	-- Check if activity quiet period has passed
	local quiet_period_ms = (config.options.activity_quiet_period or 5) * 1000
	local elapsed = uv.now() - last_activity_time
	if elapsed > quiet_period_ms then
		heavy_activity = false
		return false
	end
	return true
end

--- Check if diagnostic request should be throttled
---@param client_id number
---@param bufnr number
---@return boolean should_throttle True if request should be throttled
function M.should_throttle(client_id, bufnr)
	local opts = get_throttle_opts()
	if not opts.enabled then
		return false
	end

	-- During heavy activity, always throttle more aggressively
	if M.is_heavy_activity() then
		return true
	end

	-- Check visible_only setting
	if opts.visible_only and not is_buffer_visible(bufnr) then
		return true
	end

	-- Check debounce timing
	local key = make_key(client_id, bufnr)
	local last_time = last_request_times[key]
	if last_time then
		local elapsed = uv.now() - last_time
		if elapsed < opts.debounce_ms then
			return true
		end
	end

	return false
end

--- Request diagnostics for a buffer with throttling
---@param client_id number
---@param bufnr number
---@param force? boolean Force request even if throttled
function M.request_diagnostics(client_id, bufnr, force)
	local opts = get_throttle_opts()
	local key = make_key(client_id, bufnr)

	-- Cancel any pending timer for this key
	if pending_timers[key] then
		pcall(function()
			if not pending_timers[key]:is_closing() then
				pending_timers[key]:stop()
				pending_timers[key]:close()
			end
		end)
		pending_timers[key] = nil
	end

	-- Check if we should throttle
	if not force and M.should_throttle(client_id, bufnr) then
		-- Schedule a delayed request
		local timer = uv.new_timer()
		if timer then
			local delay = opts.debounce_ms
			if M.is_heavy_activity() then
				delay = delay * 2 -- Double delay during heavy activity
			end

			timer:start(delay, 0, function()
				pcall(function()
					if not timer:is_closing() then
						timer:stop()
						timer:close()
					end
				end)
				pending_timers[key] = nil

				-- Schedule the actual request
				vim.schedule(function()
					M.do_request_diagnostics(client_id, bufnr)
				end)
			end)
			pending_timers[key] = timer
		end
		return
	end

	-- Immediate request
	M.do_request_diagnostics(client_id, bufnr)
end

--- Actually perform the diagnostic request
---@param client_id number
---@param bufnr number
function M.do_request_diagnostics(client_id, bufnr)
	-- Validate buffer still exists and is loaded
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end

	-- Get client
	local client = vim.lsp.get_client_by_id(client_id)
	if not client then
		return
	end

	-- Update last request time
	local key = make_key(client_id, bufnr)
	last_request_times[key] = uv.now()

	-- Request diagnostics
	pcall(function()
		client:request(vim.lsp.protocol.Methods.textDocument_diagnostic, {
			textDocument = vim.lsp.util.make_text_document_params(bufnr),
		}, nil, bufnr)
	end)
end

--- Request diagnostics for all visible buffers attached to a client
---@param client_id number
function M.request_visible_diagnostics(client_id)
	local client = vim.lsp.get_client_by_id(client_id)
	if not client then
		return
	end

	local attached_bufs = vim.lsp.get_buffers_by_client_id(client_id)
	for _, bufnr in ipairs(attached_bufs or {}) do
		if is_buffer_visible(bufnr) then
			M.request_diagnostics(client_id, bufnr)
		end
	end
end

--- Clear all pending timers for a client
---@param client_id number
function M.clear_client(client_id)
	local prefix = tostring(client_id) .. ":"
	local to_remove = {}

	for key, timer in pairs(pending_timers) do
		if key:sub(1, #prefix) == prefix then
			table.insert(to_remove, key)
			pcall(function()
				if timer and not timer:is_closing() then
					timer:stop()
					timer:close()
				end
			end)
		end
	end

	for _, key in ipairs(to_remove) do
		pending_timers[key] = nil
		last_request_times[key] = nil
	end
end

--- Clear all state
function M.clear_all()
	for key, timer in pairs(pending_timers) do
		pcall(function()
			if timer and not timer:is_closing() then
				timer:stop()
				timer:close()
			end
		end)
	end
	pending_timers = {}
	last_request_times = {}
	heavy_activity = false
end

return M
