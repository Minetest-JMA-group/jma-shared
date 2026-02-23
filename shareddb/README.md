# shareddb

A Minetest mod that provides a cross‑server key‑value store using PostgreSQL. Data is automatically synchronised between all connected servers.

## Quick Start

1. Install system‑wide [luapgsql](https://github.com/arcapos/luapgsql)
2. Add to `minetest.conf`:
```ini
shareddb.host     = localhost
shareddb.port     = 5432
shareddb.user     = postgres
shareddb.password = your_password
shareddb.database = shareddb
```

## API

```lua
-- Get a mod-specific storage object (must be called at load time)
local modstorage = shareddb.get_mod_storage()

-- Start a transaction and get a context
local ctx = modstorage:get_context()

ctx:set_string(key, value)   -- value = nil deletes the key
local val = ctx:get_string(key)
ctx:finalize()                -- commit transaction (auto-commits on GC)

-- Listen for changes from other servers
shareddb.register_listener(function(key)
    -- called when your mod's key changes anywhere
end)
```

All operations within a context are atomic (single transaction). Only one transaction can be active at a time.

## License

GPLv3 or later © 2026 Marko Petrović