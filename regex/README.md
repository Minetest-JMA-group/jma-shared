# regex – Minetest Regex Pattern Manager

A flexible module for managing regex pattern lists (e.g., blacklists, whitelists) with persistent storage, file import/export, and built-in chat commands. Patterns are compiled and validated, and invalid ones are skipped automatically.

## Features

- Create independent regex contexts (e.g., one for blacklist, another for whitelist)
- Persistent storage: save patterns to mod storage or a shared database
- File import/export: load from and save to a file
- Automatic validation: only valid PCRE2 patterns (with `iu` flags) are kept
- Built-in chat commands: add, remove, dump, reload, export, and more
- Customizable logging and help prefix
- Tracks the last matched pattern

## Dependencies

- **rex_pcre2** – Lua bindings for PCRE2 (optional; without it the module does nothing and returns an error)

## Usage

### Creating a Context

```lua
local regex = dofile("/path/to/init.lua")   -- or load via mod loader

local mylist = regex.create({
    storage = minetest.get_mod_storage(),   -- or shared database context
    path    = minetest.get_modpath("mymod") .. "/lists/blacklist.txt",
    list_name      = "blacklist",           -- used in help text
    storage_key    = "my_blacklist",        -- key for mod storage (defaults to list_name)
    save_path      = "/custom/path/save.txt", -- optional, defaults to path
    help_prefix    = "[mymod] ",             -- optional
    logger         = function(level, msg)    -- optional custom logger
        minetest.log(level, "[mymod] " .. msg)
    end,
})
```

### Methods

| Method | Description |
|--------|-------------|
| `:match(text)` | Returns `true` if `text` matches any pattern, stores the matched pattern in `last_match`. |
| `:add(pattern)` | Adds a new regex pattern to the top of the list. Returns `true, err` on failure. |
| `:remove(pattern)` | Removes **all** occurrences of the exact pattern string. Returns the number removed. |
| `:get_patterns()` | Returns the table of current pattern strings (in order). |
| `:get_last_match()` | Returns the last pattern that matched (or `""` if none). |
| `:load()` | Loads patterns from mod storage; falls back to file if storage empty. Called automatically on creation. |
| `:save()` | Saves current patterns to mod storage. |
| `:load_file()` | Reloads patterns from `save_path` (or `path`). |
| `:save_file()` | Exports patterns to `save_path`. |
| `:handle_command(name, param)` | Processes a chat command (see below). Returns `(handled, message)`. |

### Command Interface

The `:handle_command(name, param)` method can be used to implement in-game management. The `name` parameter is the player name (for logging), and `param` is the full command string after the command name.

Available commands (inside `handle_command`):

- `add <regex>` – Add a regex pattern.
- `rm <regex>` – Remove all occurrences of the exact pattern string.
- `dump` – List all patterns.
- `last` – Show the last matched pattern.
- `reload` – Reload patterns from file (overwrites current in‑memory list).
- `export <storage_key>` – Write current patterns to file (requires exact storage key as confirmation).
- `help` – Show command help.

Example integration with a chat command:

```lua
minetest.register_chatcommand("filter", {
    func = function(name, param)
		-- Handle filter-specific commands above
        local ok, msg = mylist:handle_command(name, param)
        if ok then
            return true, msg
        end
        return false, "Unknown subcommand. Use /filter help"
    end
})
```

## License

Copyright © 2026 Marko Petrović  
SPDX-License-Identifier: GPL-3.0-or-later