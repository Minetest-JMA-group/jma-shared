# ipdb – Identity management and database for Minetest

ipdb is a mod providing a database and identity management system bundled into one. With its flexible design, it can accomodate many different data models and can serve both as a more versatile alternative to the engine-provided modstorage and as a provider of metadata storage associated with player identities instead of just usernames. An identity consists of all usernames and IP addresses that have some connection to each other.

## Features
- Automatically records usernames and IPs of connecting players.
- Groups names and IPs belonging to the same user into a single entry.
- Merges entries when a known name connects from a known IP previously associated with a different entry.
- **Whitelist mode** (`no_newentries`): blocks creation of new entries on login (useful for private servers).
- Per-mod persistent data storage attached to each user entry.
- Custom merge function support for mods to resolve data conflicts during entry merges.
- Chat commands for manual management and inspection.
- Migration tools for xban and EUBan databases.
- Support for ancillary data and for multiple stored values under one key (multimap).
- Synthetic entries can be created to provide regular modstorage outside identity management system.

## Why multimap support?
Imagine that you have an array of data that you want to save, e.g. many log entries from some actions your mod is doing. You have roughly 3 options:
- serialize the array into a string when saving and deserialize when loading. It's simple, but downside is that you get or change just a few elements, you need to deserialize/serialize the whole thing. Becomes a problem if the array is large.
- Store each element under key<i>, embedding the index into the key. For large arrays, it's better in some ways than storing under it serialized one key, but:
1) Your merger function can face collisions if the same index exists in both of the entries being merged, and so you'll potentially have to load the whole thing again to find collisions and rewrite indexes.
2) Sorting is less efficient; SQL can use an index for at most one range condition. If you already use it up for finding all keys that start with your prefix, you won't be able to use the index for sorting by ancillary.
- Multimap 🎉; store all elements under the same key.
1) You can now easily use the index for sorting by ancillary, as it's not being used to find the range of keys since there's only one key.
2) Merging is much easier as you don't need to worry about collisions, you can just reassociate all elements with the new user entry.

## Dependencies
- `lsqlite3` – must be installed on the system and the mod must be added to `secure.trusted_mods` or `secure.c_mods`.
- An engine patch giving on_authplayer callbacks ability to deny server access by returning a string.

## Installation
1. Place the mod folder in your `mods/` directory.
2. Ensure `lsqlite3` is available (e.g., `luarocks install lsqlite3`).
3. Add `"ipdb"` to `secure.trusted_mods` in `minetest.conf`.

## Configuration
The setting `no_newentries` controls whether new user entries can be created:
- `false` (default): any new name/IP combination creates a new entry.
- `true`: new entries are blocked; players must be pre‑registered via commands or migration.
The setting `log_merges` controls whether merge events trigger logging to the log tables
- `false`: Merge is performed with nothing being logged. It is irreversible.
- `true` (default): A new MergeEvent row is created and the state of Modstorage, IPs and Usernames is saved so that enough information persists to be able to walk back the merge.

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
| `/ipdb list <IP\|username>` | List all IPs and usernames linked with the given one. |
| `/ipdb log_merges [yes\|no]` | Show or change whether entry merge events are logged. |

### Migration Commands
Requires `dev` privilege.
- `/ipdb_migrate xban` – Import data from xban.
- `/ipdb_migrate euban` – Import data from EUBan.

## API for Mods
_`ipdb.disabled` can be quickly checked to determine whether ipdb is functional_

### Register a Merger Function
Called when two user entries are merged. Must be registered at load time.
```lua
ipdb.register_merger(function(entry1_data, entry2_data)
    --[[ entryX_data is the table of { key = data_under_key }
	- For multimap keys, data_under_key is a table of { modstorage_id = ValueFormat }
	- For regular map keys, data_under_key is just ValueFormat
	- ValueFormat is either a data string, or { value = dataString, ancillary = ancillary } if ancillary integer exists
	]]
	entryExample = {
		-- Map
		key1 = dataString1,
		-- Ancillary
		key2 = {
			value = dataString2,
			ancillary = 15
		},
		-- Multimap
		key3 = {
			[3] = dataString3,
			[13] = {
				value = dataString4,
				ancillary = 20
			}
		}
	}
    -- Return a merged table in the same format, that will replace entry2’s data.
end)
-- Alternatively you can register a callback that gets entry IDs and merges them with custom database operations
ipdb.register_entryid_merger(function(entrysrcid, entrydestid)
	-- Have good knowledge of ipdb and use dbmanager or connection object to more efficiently merge data directly
	-- Check ipdb.get_internal() in source
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
- `:finalize()` – commit the transaction.
- `:get_linked_ids()` - Get a table with names and IPs belonging to this entry
_Sensible only for regular map keys_
- `:set_string(key, value, ancillary)` – store a string (or `nil` to delete) with an optional ancillary integer.
- `:get_string(key)` – retrieve a string.
_Works for all keys (multimap supported)_
- `:get_strings(key, limit)` - retrieve strings under the given key in the form of a `table<modstorage_id, {value = dataString, ancillary = integer|nil}>`
- `:update_value(modstorage_id, key, value, ...[ancillary])` - Update key (if not nil), value (if not nil) and optionally ancillary on the given modstorage row
- `:remove(modstorage_id)` - Remove the value from modstorage based on id
- `:add_string(key, value, ancillary)` - Same as set_string, except that it doesn't overwrite existing values

**Note:** A transaction is started when you obtain a context; always call `:finalize()`

### Manual Entry Registration
```lua
ipdb.register_new_ids(name, ip)   -- both can be nil; creates/updates links without enforcing no_newentries.
```

### Register callbacks
Call func(name, ip) when a player successfully authenticates and is processed by ipdb, but before they join the game.
Can return a string representing a reason for denying player's access to the server.
```lua
ipdb.register_on_login(func)
```

## Database Schema
The database (`worldpath/ipdb.sqlite`) contains tables:
- `UserEntry` – each distinct user.
- `Usernames` – names linked to an entry.
- `IPs` – IP addresses linked to an entry.
- `Modstorage` – per‑mod per-player-entry key‑value(s) data.
- `Metadata` – settings like `no_new_entries`, database version.
- `Modstorage_log` - Logs the state of modstorage at the time of merge
- `MergeEvent` - Records merge events themselves.
- `Usernames_log` - Records usernames from the entry that's about to be destroyed in the merge process
- `IPs_log` - Records IPs from the entry that's about to be destroyed in the merge process

Foreign keys and triggers ensure orphaned entries are cleaned up automatically.
All ipdb data is contained within its database file. It does not use engine-provided modstorage.

## License
GPL-3.0-or-later © 2026 Marko Petrović