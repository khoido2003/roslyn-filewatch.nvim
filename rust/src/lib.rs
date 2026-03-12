use mlua::prelude::*;
use ignore::WalkBuilder;
use std::time::UNIX_EPOCH;

fn fast_snapshot(lua: &Lua, directory: String) -> LuaResult<LuaTable> {
    let table = lua.create_table()?;

    let walker = WalkBuilder::new(directory)
        .hidden(false)
        .ignore(false)
        .git_ignore(false)
        .build();

    for result in walker {
        if let Ok(entry) = result {
            if let Ok(metadata) = entry.metadata() {
                if metadata.is_file() {
                    let mtime = metadata
                        .modified()
                        .unwrap_or(UNIX_EPOCH)
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs();
                        
                    let size = metadata.len();

                    if let Some(path_str) = entry.path().to_str() {
                        let normalized = path_str.replace("\\", "/");
                        
                        if let Ok(file_info) = lua.create_table() {
                            let _ = file_info.set("mtime", mtime);
                            let _ = file_info.set("size", size);
                            let _ = table.set(normalized, file_info);
                        }
                    }
                }
            }
        }
    }

    Ok(table)
}

#[mlua::lua_module]
fn roslyn_filewatch_rs(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;
    exports.set("fast_snapshot", lua.create_function(fast_snapshot)?)?;
    Ok(exports)
}

