# Filter

Filter is a Luanti (Minetest) chat-filtering mod that blocks unwanted messages
by matching player chat against a server-managed regex blacklist. The backend
is implemented entirely in Lua and uses `lrexlib-pcre2` (loaded through
`algorithms.require("rex_pcre2")`) so the mod no longer depends on the old
native `libfilter.so`.

## Features

* **Regex blacklist** – every message is checked against a compiled list of
  PCRE2 patterns (case-insensitive + Unicode aware). A match blocks the
  message, logs it, and feeds the violation pipeline.
* **Enforcing / Permissive modes** – `/filter setenforce 1|0` toggles between
  blocking (`Enforcing`) and reporting-only (`Permissive`) behaviour.
* **Escalating punishments** – first hit shows a warning formspec, repeated
  hits mute via xban, and sustained abuse triggers a kick plus optional Discord
  + email notifications.
* **Chat command console** – `/filter` lets privileged players dump, add, remove,
  reload, export, or query regexes at runtime without restarting the server.

## Command Reference

```
/filter export blacklist        # write blacklist to filter/blacklist
/filter getenforce              # show current mode
/filter setenforce <0|1|name>   # switch mode
/filter dump                    # print blacklist contents
/filter last                    # show last matched regex
/filter reload                  # reload blacklist from filter/blacklist
/filter add <regex>             # prepend regex to blacklist
/filter rm <regex>              # remove all identical entries
```

All commands require the `filtering` privilege. Regex arguments keep every
character after the command (including spaces) so complex patterns round-trip
unchanged.

## API

* `filter.register_on_violation(func(name, message, violations, violation_type))`  
  Register callbacks to override the built-in enforcement flow. Return `true`
  to stop further processing.
* `filter.check_message(message) -> bool, violation_type`  
  Returns `false,"blacklisted"` when the blacklist matches the message.
* `filter.on_violation(name, message, violation_type)`  
  Updates the violation counter, calls callbacks, and applies the default
  punishments.
* `filter.mute(name, minutes, violation_type, message)`  
  Helper that wraps the xban mute call.
* `filter.show_warning_formspec(name, violation_type)`  
  Displays the standard warning UI.
* `filter.is_blacklisted(message)`  
  Internal helper exposed for compatibility; returns `true` when the current
  blacklist matches and records the matched pattern for staff.
* `filter.export_regex("blacklist")`  
  Writes the blacklist to `filter/blacklist`, mirroring `/filter export`.
* `filter.get_mode()`  
  Returns `1` (Enforcing) or `0` (Permissive).
* `filter.get_lastreg()`  
  Returns the last regex that matched or `""` if none did since startup.

## Storage & Migration

Blacklist data is stored in mod storage under the `blacklist` key using
`core.serialize`. On startup the backend checks the `version` key:

* Missing version ⇒ the mod assumes this is a migration from the legacy C++
  implementation, attempts to read the JSON list (or `filter/blacklist`),
  re-serializes it with `core.serialize`, wipes unused keys (`whitelist`,
  `words`, `maxLen`, `max_len`), and writes `version = 2`.
* Version `2` ⇒ the blacklist is loaded with `core.deserialize`.

You can still edit `filter/blacklist` directly and run `/filter reload` to
recompile everything on the fly.
