local uv = vim.uv or vim.loop
local sysname = uv.os_uname().sysname:lower()
local arch = jit and jit.arch or "x64"

local is_win = sysname:match("windows")
local is_mac = sysname:match("darwin") or sysname:match("mac")
local is_linux = sysname:match("linux")

local ext = is_win and "dll" or "so"

local function build_from_source()
  print("Found cargo. Building native rust module from source...")
  local cmd = "cargo build --release"

  -- Run cargo build
  local exit_code = os.execute("cd rust && " .. cmd)
  if exit_code ~= 0 then
    print("Cargo build failed. Falling back to Lua scanners.")
    return false
  end

  -- Copy artifacts
  local source_file = ""
  if is_win then
    source_file = "rust/target/release/roslyn_filewatch_rs.dll"
  elseif is_mac then
    source_file = "rust/target/release/libroslyn_filewatch_rs.dylib"
  else
    source_file = "rust/target/release/libroslyn_filewatch_rs.so"
  end

  local dest_file = "lua/roslyn_filewatch_rs." .. ext

  local copy_cmd = is_win and ('copy /Y "' .. source_file:gsub("/", "\\") .. '" "' .. dest_file:gsub("/", "\\") .. '"')
    or ('cp "' .. source_file .. '" "' .. dest_file .. '"')
  os.execute(copy_cmd)

  print("Successfully compiled and installed roslyn_filewatch_rs!")
  return true
end

local function download_binary()
  print("Cargo not found. Attempting to download pre-compiled binary from GitHub...")

  local repo = "khoido2003/roslyn-filewatch.nvim"
  local asset_name = ""

  if is_win then
    asset_name = "roslyn_filewatch_rs-windows-x86_64.dll"
  elseif is_mac then
    if arch == "x64" or arch == "x86_64" then
      asset_name = "roslyn_filewatch_rs-macos-x86_64.so"
    else
      asset_name = "roslyn_filewatch_rs-macos-arm64.so"
    end
  elseif is_linux then
    asset_name = "roslyn_filewatch_rs-linux-x86_64.so"
  end

  local url = "https://github.com/" .. repo .. "/releases/latest/download/" .. asset_name
  local dest_file = "lua/roslyn_filewatch_rs." .. ext

  local curl_cmd = 'curl -fLo "' .. dest_file .. '" "' .. url .. '"'

  if vim.fn.executable("curl") == 0 then
    print("curl is not installed. Cannot download binary.")
    return false
  end

  local exit_code = os.execute(curl_cmd)
  if exit_code == 0 then
    print("Successfully downloaded pre-compiled binary!")
    return true
  else
    print("Failed to download binary from GitHub. (Are there releases published?)")
    print("The plugin will safely fall back to pure-Lua scanning.")
    return false
  end
end

-- Create lua folder if it doesn't exist just in case
if is_win then
  os.execute('if not exist "lua" mkdir lua')
else
  os.execute("mkdir -p lua")
end

if vim.fn.executable("cargo") == 1 then
  build_from_source()
else
  download_binary()
end
