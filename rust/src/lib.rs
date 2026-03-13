use ignore::WalkBuilder;
use mlua::prelude::*;
use std::time::UNIX_EPOCH;

/// Fast directory snapshot with optional filtering.
///
/// Arguments:
///   1. directory: string — root path to scan
///   2. options: table (optional) — filtering options:
///      - extensions: string[] — file extensions to include (with dot, e.g. ".cs")
///      - ignore_dirs: string[] — directory names to skip (e.g. "bin", "obj")
///      - respect_gitignore: boolean — whether to respect .gitignore (default: true)
///
/// Returns a table: { [normalized_path] = { mtime = number, size = number } }
fn fast_snapshot<'lua>(
    lua: &'lua Lua,
    args: (String, Option<LuaTable<'lua>>),
) -> LuaResult<LuaTable<'lua>> {
    let (directory, options) = args;
    let table = lua.create_table()?;

    // Parse options
    let mut extensions: Option<Vec<String>> = None;
    let mut ignore_dirs: Option<Vec<String>> = None;
    let mut respect_gitignore = true;

    if let Some(ref opts) = options {
        // Parse extensions
        if let Ok(ext_table) = opts.get::<_, LuaTable>("extensions") {
            let mut exts = Vec::new();
            for pair in ext_table.sequence_values::<String>() {
                if let Ok(ext) = pair {
                    // Store lowercased, without leading dot
                    let cleaned = ext.trim_start_matches('.').to_lowercase();
                    if !cleaned.is_empty() {
                        exts.push(cleaned);
                    }
                }
            }
            if !exts.is_empty() {
                extensions = Some(exts);
            }
        }

        // Parse ignore_dirs
        if let Ok(dirs_table) = opts.get::<_, LuaTable>("ignore_dirs") {
            let mut dirs = Vec::new();
            for pair in dirs_table.sequence_values::<String>() {
                if let Ok(d) = pair {
                    dirs.push(d.to_lowercase());
                }
            }
            if !dirs.is_empty() {
                ignore_dirs = Some(dirs);
            }
        }

        // Parse respect_gitignore
        if let Ok(val) = opts.get::<_, bool>("respect_gitignore") {
            respect_gitignore = val;
        }
    }

    let mut walker_builder = WalkBuilder::new(&directory);
    walker_builder
        .hidden(false)
        .ignore(false)
        .git_ignore(respect_gitignore)
        .git_global(false)
        .git_exclude(false);

    // If we have ignore_dirs, use filter_entry to prune them completely from the traversal
    if let Some(ref dirs) = ignore_dirs {
        walker_builder.filter_entry({
            let dirs_clone = dirs.clone();
            move |entry| {
                if let Some(name) = entry.file_name().to_str() {
                    let lower = name.to_lowercase();
                    if dirs_clone.iter().any(|d| d == &lower) {
                        return false; // Skip this directory/file and its children entirely
                    }
                }
                true
            }
        });
    }

    let walker = walker_builder.build();

    for result in walker {
        let entry = match result {
            Ok(e) => e,
            Err(_) => continue,
        };

        // Skip directories early for processing
        let file_type = match entry.file_type() {
            Some(ft) => ft,
            None => continue,
        };
        if !file_type.is_file() {
            continue;
        }

        let path = entry.path();

        // Check extension filter
        if let Some(ref exts) = extensions {
            let ext_match = path
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| exts.iter().any(|x| x == &e.to_lowercase()))
                .unwrap_or(false);
            if !ext_match {
                continue;
            }
        }

        // Get metadata
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };

        let mtime_dur = metadata
            .modified()
            .unwrap_or(UNIX_EPOCH)
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();

        // Return nanosecond precision
        let mtime_nanos = mtime_dur.as_secs() as i64 * 1_000_000_000 + mtime_dur.subsec_nanos() as i64;
        let size = metadata.len();

        if let Some(path_str) = path.to_str() {
            let normalized = path_str.replace('\\', "/");

            // Lowercase drive letter on Windows (match Lua normalize_path)
            let normalized = if normalized.len() >= 2 {
                let bytes = normalized.as_bytes();
                if bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
                    let mut s = String::with_capacity(normalized.len());
                    s.push((bytes[0] as char).to_ascii_lowercase());
                    s.push_str(&normalized[1..]);
                    s
                } else {
                    normalized
                }
            } else {
                normalized
            };

            if let Ok(file_info) = lua.create_table() {
                let _ = file_info.set("mtime", mtime_nanos);
                let _ = file_info.set("size", size);
                let _ = table.set(normalized, file_info);
            }
        }
    }

    Ok(table)
}

#[mlua::lua_module]
fn roslyn_filewatch_rs(lua: &Lua) -> LuaResult<LuaTable<'_>> {
    let exports = lua.create_table()?;
    exports.set("fast_snapshot", lua.create_function(fast_snapshot)?)?;
    Ok(exports)
}
