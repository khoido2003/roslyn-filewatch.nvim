---@class roslyn_filewatch.snippets
---@field setup_luasnip fun()
---@field get_snippets fun(): table

---Game development snippets for Unity and Godot.
---Provides LuaSnip integration and snippet definitions.

local M = {}

--- Get all C# snippets organized by category
---@return table snippets
function M.get_snippets()
	return {
		-- Basic C# snippets
		general = {
			{
				trigger = "prop",
				name = "Auto Property",
				body = "public ${1:string} ${2:Name} { get; set; }",
			},
			{
				trigger = "propfull",
				name = "Full Property",
				body = [[
private ${1:string} _${2:name};
public ${1:string} ${3:Name}
{
    get => _${2:name};
    set => _${2:name} = value;
}]],
			},
			{
				trigger = "ctor",
				name = "Constructor",
				body = [[
public ${1:ClassName}(${2})
{
    ${0}
}]],
			},
			{
				trigger = "class",
				name = "Class",
				body = [[
namespace ${1:Namespace}
{
    public class ${2:ClassName}
    {
        ${0}
    }
}]],
			},
			{
				trigger = "interface",
				name = "Interface",
				body = [[
namespace ${1:Namespace}
{
    public interface I${2:Name}
    {
        ${0}
    }
}]],
			},
			{
				trigger = "async",
				name = "Async Method",
				body = [[
public async Task${1:<${2:T}>} ${3:MethodName}Async(${4})
{
    ${0}
}]],
			},
			{
				trigger = "try",
				name = "Try-Catch",
				body = [[
try
{
    ${0}
}
catch (${1:Exception} ex)
{
    ${2:throw;}
}]],
			},
			{
				trigger = "foreach",
				name = "Foreach Loop",
				body = [[
foreach (var ${1:item} in ${2:collection})
{
    ${0}
}]],
			},
		},

		-- Unity snippets
		unity = {
			{
				trigger = "mono",
				name = "MonoBehaviour Class",
				body = [[
using UnityEngine;

public class ${1:ClassName} : MonoBehaviour
{
    ${0}
}]],
			},
			{
				trigger = "start",
				name = "Start Method",
				body = [[
private void Start()
{
    ${0}
}]],
			},
			{
				trigger = "update",
				name = "Update Method",
				body = [[
private void Update()
{
    ${0}
}]],
			},
			{
				trigger = "fixedupdate",
				name = "FixedUpdate Method",
				body = [[
private void FixedUpdate()
{
    ${0}
}]],
			},
			{
				trigger = "awake",
				name = "Awake Method",
				body = [[
private void Awake()
{
    ${0}
}]],
			},
			{
				trigger = "onenable",
				name = "OnEnable Method",
				body = [[
private void OnEnable()
{
    ${0}
}]],
			},
			{
				trigger = "ondisable",
				name = "OnDisable Method",
				body = [[
private void OnDisable()
{
    ${0}
}]],
			},
			{
				trigger = "oncollision",
				name = "OnCollisionEnter",
				body = [[
private void OnCollisionEnter(Collision collision)
{
    ${0}
}]],
			},
			{
				trigger = "ontrigger",
				name = "OnTriggerEnter",
				body = [[
private void OnTriggerEnter(Collider other)
{
    ${0}
}]],
			},
			{
				trigger = "coroutine",
				name = "Coroutine",
				body = [[
private IEnumerator ${1:CoroutineName}()
{
    ${0}
    yield return null;
}]],
			},
			{
				trigger = "serialize",
				name = "SerializeField",
				body = "[SerializeField] private ${1:type} ${2:name};",
			},
			{
				trigger = "header",
				name = "Header Attribute",
				body = '[Header("${1:Header Text}")]',
			},
			{
				trigger = "scriptable",
				name = "ScriptableObject",
				body = [[
using UnityEngine;

[CreateAssetMenu(fileName = "${1:NewAsset}", menuName = "${2:Category}/${1:NewAsset}")]
public class ${3:ClassName} : ScriptableObject
{
    ${0}
}]],
			},
			{
				trigger = "singleton",
				name = "Unity Singleton",
				body = [[
public static ${1:ClassName} Instance { get; private set; }

private void Awake()
{
    if (Instance != null && Instance != this)
    {
        Destroy(gameObject);
        return;
    }
    Instance = this;
    DontDestroyOnLoad(gameObject);
}]],
			},
		},

		-- Godot snippets
		godot = {
			{
				trigger = "node",
				name = "Node Script",
				body = [[
using Godot;

public partial class ${1:ClassName} : ${2:Node}
{
    ${0}
}]],
			},
			{
				trigger = "ready",
				name = "_Ready Method",
				body = [[
public override void _Ready()
{
    ${0}
}]],
			},
			{
				trigger = "process",
				name = "_Process Method",
				body = [[
public override void _Process(double delta)
{
    ${0}
}]],
			},
			{
				trigger = "physics",
				name = "_PhysicsProcess Method",
				body = [[
public override void _PhysicsProcess(double delta)
{
    ${0}
}]],
			},
			{
				trigger = "input",
				name = "_Input Method",
				body = [[
public override void _Input(InputEvent @event)
{
    ${0}
}]],
			},
			{
				trigger = "export",
				name = "Export Property",
				body = "[Export] public ${1:type} ${2:Name} { get; set; }",
			},
			{
				trigger = "signal",
				name = "Signal Declaration",
				body = "[Signal] public delegate void ${1:SignalName}EventHandler(${2});",
			},
			{
				trigger = "emitsignal",
				name = "Emit Signal",
				body = "EmitSignal(SignalName.${1:SignalName}${2:, args});",
			},
			{
				trigger = "getnode",
				name = "GetNode",
				body = 'GetNode<${1:NodeType}>("${2:Path}");',
			},
			{
				trigger = "resource",
				name = "Resource Class",
				body = [[
using Godot;

[GlobalClass]
public partial class ${1:ClassName} : Resource
{
    ${0}
}]],
			},
			{
				trigger = "autoload",
				name = "Autoload Singleton",
				body = [[
using Godot;

public partial class ${1:ClassName} : Node
{
    public static ${1:ClassName} Instance { get; private set; }

    public override void _Ready()
    {
        Instance = this;
    }
}]],
			},
		},

		-- ASP.NET / Web API snippets
		aspnet = {
			{
				trigger = "controller",
				name = "API Controller",
				body = [[
using Microsoft.AspNetCore.Mvc;

namespace ${1:Namespace}.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class ${2:Name}Controller : ControllerBase
    {
        ${0}
    }
}]],
			},
			{
				trigger = "action",
				name = "Controller Action",
				body = [[
[Http${1|Get,Post,Put,Delete|}("${2:route}")]
public async Task<ActionResult<${3:T}>> ${4:ActionName}(${5})
{
    ${0}
}]],
			},
			{
				trigger = "getall",
				name = "Get All Action",
				body = [[
[HttpGet]
public async Task<ActionResult<IEnumerable<${1:T}>>> GetAll()
{
    ${0}
}]],
			},
			{
				trigger = "getbyid",
				name = "Get By Id Action",
				body = [[
[HttpGet("{id}")]
public async Task<ActionResult<${1:T}>> GetById(${2:int} id)
{
    ${0}
}]],
			},
			{
				trigger = "post",
				name = "Post Action",
				body = [[
[HttpPost]
public async Task<ActionResult<${1:T}>> Create(${1:T} ${2:item})
{
    ${0}
    return CreatedAtAction(nameof(GetById), new { id = ${2:item}.Id }, ${2:item});
}]],
			},
			{
				trigger = "minimal",
				name = "Minimal API Endpoint",
				body = [[
app.Map${1|Get,Post,Put,Delete|}("${2:/api/route}", async (${3}) =>
{
    ${0}
});]],
			},
		},
	}
end

--- Setup LuaSnip integration if available
function M.setup_luasnip()
	local ok, luasnip = pcall(require, "luasnip")
	if not ok then
		vim.notify("[roslyn-filewatch] LuaSnip not found. Snippets not loaded.", vim.log.levels.WARN)
		return false
	end

	local ok_snip, s = pcall(function()
		return luasnip.snippet
	end)
	if not ok_snip then
		return false
	end

	local ok_nodes, nodes = pcall(function()
		return {
			t = require("luasnip.nodes.textNode").T,
			i = require("luasnip.nodes.insertNode").I,
			c = require("luasnip.nodes.choiceNode").C,
		}
	end)

	-- Convert our snippet format to LuaSnip format
	local snippets = M.get_snippets()
	local ls_snippets = {}

	for category, category_snippets in pairs(snippets) do
		for _, snip in ipairs(category_snippets) do
			-- Simple text snippet (LuaSnip can parse VSCode-style snippets)
			local ls_snip = luasnip.parser.parse_snippet(snip.trigger, snip.body)
			ls_snip.name = snip.name
			ls_snip.description = category .. ": " .. snip.name
			table.insert(ls_snippets, ls_snip)
		end
	end

	-- Add snippets for C# filetype
	luasnip.add_snippets("cs", ls_snippets)

	vim.notify("[roslyn-filewatch] Loaded " .. #ls_snippets .. " C# snippets", vim.log.levels.INFO)
	return true
end

--- Show available snippets in a floating window
function M.show_snippets()
	local snippets = M.get_snippets()
	local lines = {}

	table.insert(lines, "C# Snippets for Game & Web Development")
	table.insert(lines, string.rep("─", 50))
	table.insert(lines, "")

	for category, category_snippets in pairs(snippets) do
		table.insert(lines, "▸ " .. category:upper())
		for _, snip in ipairs(category_snippets) do
			table.insert(lines, "  " .. snip.trigger .. " → " .. snip.name)
		end
		table.insert(lines, "")
	end

	-- Create floating window
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	local width = 60
	local height = math.min(#lines, 30)

	vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
		title = " C# Snippets ",
		title_pos = "center",
	})

	-- Close on q or Escape
	vim.keymap.set("n", "q", ":close<CR>", { buffer = buf, silent = true })
	vim.keymap.set("n", "<Esc>", ":close<CR>", { buffer = buf, silent = true })
end

return M
