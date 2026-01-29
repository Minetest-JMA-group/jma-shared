# Filter

Filter is a Luanti (Minetest) chat-filtering mod that blocks unwanted messages by matching player chat against a server-managed regex blacklist.

## Features

* **Regex blacklist** – messages are checked against PCRE2 patterns (case-insensitive + Unicode aware)
* **Enforcing / Permissive modes** – `/filter setenforce 1|0` toggles between blocking and reporting-only
* **Escalating punishments** – warning → mute → kick with Discord notifications
* **Unified commands** – `/filter` handles both pattern management and filter settings

## Command Reference

```
/filter getenforce              # show current mode
/filter setenforce <0|1|name>  # switch mode

# Pattern management (handled by regex mod):
/filter export blacklist        # write to filter/blacklist
/filter dump                    # print blacklist contents
/filter last                    # show last matched regex
/filter reload                  # reload from filter/blacklist
/filter add <regex>             # add regex to blacklist
/filter rm <regex>              # remove regex from blacklist
/filter help                    # show command list
```

Requires `filtering` privilege.

## API

* `filter.register_on_violation(func)` – override enforcement flow (return `true` to stop)
* `filter.check_message(message) → bool, violation_type`
* `filter.on_violation(name, message, violation_type)`
* `filter.get_mode()` – returns 1 (Enforcing) or 0 (Permissive)
* `filter.get_lastreg()` – returns last matched regex

## Storage

* **Mod storage**: Blacklist serialized under the key `blacklist`
* **File**: `filter/blacklist` for manual editing
* **Version**: Stored as `version = 2` for future migrations

## Dependencies

* **Required**: `regex` mod for pattern management
* **Optional**: xban (muting), discord (notifications), rules (formspec integration)
