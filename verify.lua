local files = {
  "lua/roslyn_filewatch/watcher.lua",
  "lua/roslyn_filewatch/watcher/fs_event.lua",
  "lua/roslyn_filewatch/watcher/fs_poll.lua",
  "lua/roslyn_filewatch/watcher/snapshot.lua",
  "lua/roslyn_filewatch/watcher/notify.lua",
  "lua/roslyn_filewatch/watcher/sln_parser.lua",
  "lua/roslyn_filewatch/watcher/utils.lua",
  "lua/roslyn_filewatch/watcher/watchdog.lua",
  "lua/roslyn_filewatch/watcher/gitignore.lua",
  "lua/roslyn_filewatch/watcher/rename.lua",
  "lua/roslyn_filewatch/watcher/regen_detector.lua",
  "lua/roslyn_filewatch/watcher/backends/fswatch.lua",
  "lua/roslyn_filewatch/watcher/backends/init.lua",
  "lua/roslyn_filewatch/watcher/backends/fs_event_adapter.lua",
  "lua/roslyn_filewatch/watcher/backends/watchman.lua",
  "lua/roslyn_filewatch/config.lua",
  "lua/roslyn_filewatch/health.lua",
  "lua/roslyn_filewatch/init.lua",
}

local has_err = false
for _, f in ipairs(files) do
  local chunk, err = loadfile(f)
  if not chunk then
    print("Syntax Error in " .. f .. ":\n" .. tostring(err))
    has_err = true
  else
    print("Syntax OK: " .. f)
  end
end

if has_err then
  print("\nSyntax check FAILED")
  os.exit(1)
else
  print("\nAll syntax checks passed (" .. #files .. " files)")
end

package.cpath = package.cpath .. ";./lua/?.dll"
local ok, rs = pcall(require, "roslyn_filewatch_rs")
if ok and rs and rs.fast_snapshot then
  print("Native Rust Module Loaded Successfully!")
  os.exit(0)
else
  print("Failed to load Native Rust Module: " .. tostring(rs))
  os.exit(1)
end
