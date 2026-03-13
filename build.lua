local uv = vim.uv or vim.loop
local sysname = uv.os_uname().sysname:lower()
local arch = uv.os_uname().machine:lower()
local is_win = sysname:match("windows")
local is_mac = sysname:match("darwin") or sysname:match("mac")
local is_linux = sysname:match("linux")
local ext = is_win and "dll" or "so"

local script_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(script_path, ":h")

local function exec(cmd)
  local exit_code = os.execute(cmd)
  -- LuaJIT (Neovim): returns integer. Lua 5.2+: returns true/nil, "exit", code
  if type(exit_code) == "boolean" then
    return exit_code and 0 or 1
  end
  return exit_code
end

local function build_from_source()
  print("Found cargo. Building native rust module from source...")

  local rust_dir = plugin_root .. "/rust"
  local cmd = is_win and ('pushd "' .. rust_dir .. '" && cargo build --release && popd')
    or ('cd "' .. rust_dir .. '" && cargo build --release')

  if exec(cmd) ~= 0 then
    print("Cargo build failed. Falling back to Lua scanners.")
    return false
  end

  local source_file
  if is_win then
    source_file = rust_dir .. "/target/release/roslyn_filewatch_rs.dll"
  elseif is_mac then
    source_file = rust_dir .. "/target/release/libroslyn_filewatch_rs.dylib"
  else
    source_file = rust_dir .. "/target/release/libroslyn_filewatch_rs.so"
  end

  local dest_file = plugin_root .. "/lua/roslyn_filewatch_rs." .. ext
  local copy_cmd = is_win and ('copy /Y "' .. source_file:gsub("/", "\\") .. '" "' .. dest_file:gsub("/", "\\") .. '"')
    or ('cp "' .. source_file .. '" "' .. dest_file .. '"')

  exec(copy_cmd)
  print("Successfully compiled and installed roslyn_filewatch_rs!")
  return true
end

local function download_binary()
  print("Cargo not found. Attempting to download pre-compiled binary from GitHub...")

  if vim.fn.executable("curl") == 0 then
    print("curl is not installed. Cannot download binary.")
    return false
  end

  local repo = "khoido2003/roslyn-filewatch.nvim"
  local asset_name

  if is_win then
    asset_name = "roslyn_filewatch_rs-windows-x86_64.dll"
  elseif is_mac then
    -- uv.os_uname().machine returns "arm64" on Apple Silicon, "x86_64" on Intel
    if arch:match("x86_64") then
      asset_name = "roslyn_filewatch_rs-macos-x86_64.so"
    else
      asset_name = "roslyn_filewatch_rs-macos-arm64.so"
    end
  elseif is_linux then
    asset_name = "roslyn_filewatch_rs-linux-x86_64.so"
  else
    print("Unsupported platform: " .. sysname)
    return false
  end

  local dest_file = plugin_root .. "/lua/roslyn_filewatch_rs." .. ext
  local url = "https://github.com/" .. repo .. "/releases/latest/download/" .. asset_name
  local curl_cmd = 'curl -fLo "' .. dest_file .. '" "' .. url .. '"'

  if exec(curl_cmd) == 0 then
    print("Successfully downloaded pre-compiled binary!")
    return true
  else
    print("Failed to download binary. (No releases published yet?)")
    print("The plugin will fall back to pure-Lua scanning.")
    return false
  end
end

-- Ensure lua/ dir exists
local lua_dir = plugin_root .. "/lua"
if is_win then
  os.execute('if not exist "' .. lua_dir:gsub("/", "\\") .. '" mkdir "' .. lua_dir:gsub("/", "\\") .. '"')
else
  os.execute('mkdir -p "' .. lua_dir .. '"')
end

if vim.fn.executable("cargo") == 1 then
  build_from_source()
else
  download_binary()
end
