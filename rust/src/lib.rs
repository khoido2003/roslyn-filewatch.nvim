use ignore::WalkBuilder;
use mlua::prelude::*;
use std::collections::HashSet;
use std::sync::Arc;
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
    let mut extensions: Option<Arc<HashSet<String>>> = None;
    let mut ignore_dirs: Option<Arc<HashSet<Box<str>>>> = None;
    let mut respect_gitignore = true;

    if let Some(ref opts) = options {
        // Parse extensions
        if let Ok(ext_table) = opts.get::<_, LuaTable>("extensions") {
            let mut exts = HashSet::new();
            for pair in ext_table.sequence_values::<String>() {
                if let Ok(ext) = pair {
                    let cleaned = ext.trim_start_matches('.');
                    if !cleaned.is_empty() {
                        // Store lowercase for O(1) insensitive lookups later
                        exts.insert(cleaned.to_ascii_lowercase());
                    }
                }
            }
            if !exts.is_empty() {
                extensions = Some(Arc::new(exts));
            }
        }

        // Parse ignore_dirs
        if let Ok(dirs_table) = opts.get::<_, LuaTable>("ignore_dirs") {
            let mut dirs: HashSet<Box<str>> = HashSet::new();
            for pair in dirs_table.sequence_values::<String>() {
                if let Ok(d) = pair {
                    dirs.insert(d.to_ascii_lowercase().into_boxed_str()); // Store lowercase boxed strings for zero allocation lookups
                }
            }
            if !dirs.is_empty() {
                ignore_dirs = Some(Arc::new(dirs));
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
        .git_exclude(false)
        .parents(false);

    // Use multiple threads to traverse directories faster for large projects
    walker_builder.threads(
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or_else(|_| 4),
    );

    // Use build_parallel since we set threads
    let walker = walker_builder.build_parallel();
    let (tx, rx) = crossbeam_channel::unbounded();

    walker.run(|| {
        let tx = tx.clone();
        let extensions = extensions.clone();
        let ignore_dirs = ignore_dirs.clone();

        Box::new(move |result| {
            if let Ok(entry) = result {
                let file_type = match entry.file_type() {
                    Some(ft) => ft,
                    None => return ignore::WalkState::Continue,
                };

                // Prune ignored directories manually for `build_parallel` correctly
                if file_type.is_dir() {
                    if let Some(ref dirs) = ignore_dirs {
                        if let Some(name) = entry.file_name().to_str() {
                            if dirs.contains(name.to_ascii_lowercase().as_str()) {
                                return ignore::WalkState::Skip;
                            }
                        }
                    }
                    return ignore::WalkState::Continue;
                }

                let path = entry.path();

                // Check extension filter
                if let Some(ref exts) = extensions {
                    let ext_match = path
                        .extension()
                        .and_then(|e| e.to_str())
                        .map(|e| exts.contains(&e.to_ascii_lowercase()))
                        .unwrap_or(false);
                    if !ext_match {
                        return ignore::WalkState::Continue;
                    }
                }

                // Get metadata
                let metadata = match entry.metadata().ok() {
                    Some(m) => m,
                    None => return ignore::WalkState::Continue,
                };

                let mtime_dur = metadata
                    .modified()
                    .unwrap_or(UNIX_EPOCH)
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default();

                let mtime_nanos = (mtime_dur.as_secs() as i64)
                    .saturating_mul(1_000_000_000)
                    .saturating_add(mtime_dur.subsec_nanos() as i64);
                let size = metadata.len();

                if let Some(path_str) = path.to_str() {
                    let mut normalized = String::with_capacity(path_str.len());
                    let mut chars = path_str.chars();

                    if path_str.len() >= 2 {
                        let bytes = path_str.as_bytes();
                        if bytes[1] == b':'
                            && bytes[0].is_ascii_alphabetic()
                            && bytes[0].is_ascii_uppercase()
                        {
                            if let (Some(c1), Some(c2)) = (chars.next(), chars.next()) {
                                normalized.push(c1.to_ascii_lowercase());
                                normalized.push(c2); // ':'
                            }
                        }
                    }

                    for c in chars {
                        if c == '\\' {
                            normalized.push('/');
                        } else {
                            normalized.push(c);
                        }
                    }

                    if tx.send((normalized, mtime_nanos, size)).is_err() {
                        return ignore::WalkState::Quit;
                    }
                }
            }
            ignore::WalkState::Continue
        })
    });

    drop(tx);

    for (normalized, mtime_nanos, size) in rx {
        let file_info = lua.create_table()?;
        file_info.set("mtime", mtime_nanos)?;
        file_info.set("size", size)?;
        table.set(normalized, file_info)?;
    }

    Ok(table)
}

#[mlua::lua_module]
fn roslyn_filewatch_rs(lua: &Lua) -> LuaResult<LuaTable<'_>> {
    let exports = lua.create_table()?;
    exports.set("fast_snapshot", lua.create_function(fast_snapshot)?)?;
    Ok(exports)
}
