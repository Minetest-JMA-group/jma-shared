# ipdb – IP-based Player Entry Database for Minetest

ipdb is a mod that maintains a persistent database of player names and IP addresses, linking them into *entries* that represent distinct users. It provides automatic name/IP linking on join, configurable prevention of new entries (whitelist mode), and a per-mod storage system tied to each user entry. Merging of entries is handled gracefully with support for custom conflict resolution.

## Features
- Automatically records usernames and IPs of connecting players.
- Groups names and IPs belonging to the same user into a single entry.
- Merges entries when a known name connects from a known IP previously associated with a different entry.
- **Whitelist mode** (`no_newentries`): blocks creation of new entries (useful for private servers).
- Per-mod persistent data storage attached to each user entry.
- Custom merge function support for mods to resolve data conflicts during entry merges.
- Chat commands for manual management and inspection.
- Migration tools for xban and EUBan databases.

## Dependencies
- `lsqlite3` – must be installed on the system and the mod must be added to `secure.trusted_mods` or `secure.c_mods`.

## Installation
1. Place the mod folder in your `mods/` directory.
2. Ensure `lsqlite3` is available (e.g., `luarocks install lsqlite3`).
3. Add `ipdb` to your `world.mt` or enable it in the Minetest launcher.
4. If using a secure server, add `"ipdb"` to `secure.trusted_mods` in `minetest.conf`.

## Configuration
The setting `no_newentries` (stored in the database) controls whether new user entries can be created:
- `false` (default): any new name/IP combination creates a new entry.
- `true`: new entries are blocked; players must be pre‑registered via commands or migration.

Use `/ipdb newentries [yes|no]` to toggle.

## Chat Commands
Requires `ban` privilege.

| Command | Description |
|--------|-------------|
| `/ipdb help` | Show help text. |
| `/ipdb add_name <username>` | Record a username (creates entry if needed). |
| `/ipdb add_ip <IPv4>` | Record an IP address. |
| `/ipdb rm_name <username>` | Remove a username from the database. |
| `/ipdb rm_ip <IPv4>` | Remove an IP address from the database. |
| `/ipdb isolate name\|ip <identifier>` | Create an isolated entry (cannot be merged) and move/add the identifier to it. |
| `/ipdb newentries [yes\|no]` | Show or change whether new entries are allowed. |

### Migration Commands
Requires `dev` privilege.
- `/ipdb_migrate xban` – Import data from xban.
- `/ipdb_migrate euban` – Import data from EUBan.

## API for Mods

### Register a Merger Function
Called when two user entries are merged. Must be registered at load time.
```lua
ipdb.register_merger(function(entry1_data, entry2_data)
    -- entryX_data is a table of key‑value pairs from modstorage for that entry.
    -- Return a merged table that will replace entry2’s data.
end)
```

### Access Mod Storage
Get a context object to read/write per‑entry data for your mod.
```lua
local mod_storage = ipdb.get_mod_storage([merger_function])
```
Returns a table with methods:
- `:get_context_by_name(name)` – obtain a context for the user entry associated with that name.
- `:get_context_by_ip(ip)` – obtain a context for the user entry associated with that IP.

The context object provides:
- `:set_string(key, value)` – store a string (or `nil` to delete).
- `:get_string(key)` – retrieve a string.
- `:finalize()` – commit the transaction (automatically called when context is garbage‑collected).

**Note:** A transaction is started when you obtain a context; always call `:finalize()` or let the context go out of scope.

### Manual Entry Registration
```lua
ipdb.register_new_ids(name, ip)   -- both can be nil; creates/updates links without enforcing no_newentries.
```

## Database Schema
The database (`worldpath/ipdb.sqlite`) contains tables:
- `UserEntry` – each distinct user.
- `Usernames` – names linked to an entry.
- `IPs` – IP addresses linked to an entry.
- `Modstorage` – per‑mod key‑value data.
- `Metadata` – settings like `no_new_entries`.

Foreign keys and triggers ensure orphaned entries are cleaned up automatically.

## License
GPL-3.0-or-later © 2026 Marko Petrović