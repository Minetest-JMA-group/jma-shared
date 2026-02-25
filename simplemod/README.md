# simplemod – Simple Moderation for Minetest

simplemod provides name‑based and IP‑based bans and mutes for Minetest, leveraging the `ipdb` mod for reliable IP tracking and the `algorithms` mod for time utilities. It includes a clean API, chat commands, and a GUI.

## Features

- **Name‑based bans/mutes** – stored in core mod storage.
- **IP‑based bans/mutes** – stored in `ipdb` per‑entry storage, automatically merged when IP‑linked accounts are merged.
- **Per‑player logs** – each player has a combined log showing both name and IP actions (ban/unban/mute/unmute). Logs are capped at the newest 100 entries.
- **Active lists** – commands to list all currently banned or muted players (name + IP).
- **Chat commands** – full set of commands usable from Discord/relays or in‑game.
- **GUI** – three‑tab interface showing active bans, active mutes, and a player’s combined log.
- **API** – other mods can call `simplemod.ban_name()`, `simplemod.is_muted_ip()`, etc.
- **Relay support** – optionally sends action reports to `relays` mod.

## Dependencies

- `algorithms` – for time parsing/formatting.
- `ipdb` – for IP‑based storage and entry merging.
- `chat_lib` – for sending muted messages to privileged players.
- `relays` (optional) – for external notifications.

All dependencies are part of the same modpack and must be enabled.

## Chat Commands

All commands require `ban` privilege (for bans) or `pmute` privilege (for mutes).

| Command | Description |
|--------|-------------|
| `/sbban <player> [time] <reason>` | Ban by name |
| `/sbunban <player> [reason]` | Unban by name |
| `/sbmute <player> [time] <reason>` | Mute by name |
| `/sbunmute <player> [reason]` | Unmute by name |
| `/sbipban <player> [time] <reason>` | Ban by IP (affects all accounts on that IP) |
| `/sbipunban <player> [reason]` | Unban by IP |
| `/sbipmute <player> [time] <reason>` | Mute by IP |
| `/sbipunmute <player> [reason]` | Unmute by IP |
| `/sbbanlist` | List all active bans (name + IP) |
| `/sbmutelist` | List all active mutes (name + IP) |
| `/sblog <player>` | Show combined log for a player |
| `/sb` | Open the GUI |

Time format examples: `30m`, `2h`, `1d`, `2w`, `3M` (month = 30 days). If omitted, the punishment is permanent.

## API

```lua
-- Name bans
simplemod.ban_name(target, source, reason, duration_sec)  → success, err
simplemod.unban_name(target, source, reason)              → success, err
simplemod.is_banned_name(target)                           → boolean

-- Name mutes
simplemod.mute_name(target, source, reason, duration_sec) → success, err
simplemod.unmute_name(target, source, reason)              → success, err
simplemod.is_muted_name(target)                             → boolean

-- IP bans
simplemod.ban_ip(target, source, reason, duration_sec)    → success, err
simplemod.unban_ip(target, source, reason)                 → success, err
simplemod.is_banned_ip(target)                              → boolean

-- IP mutes
simplemod.mute_ip(target, source, reason, duration_sec)   → success, err
simplemod.unmute_ip(target, source, reason)                → success, err
simplemod.is_muted_ip(target)                               → boolean

-- Combined log for a player (table of entries, newest first)
simplemod.get_player_log(player) → { {type, scope, target, source, reason, duration, time}, ... }
```

- `target` – player name (string)
- `source` – moderator name or `"(console)"` (string)
- `reason` – optional reason (string)
- `duration_sec` – seconds, `0` or `nil` = permanent

## GUI

Opened with `/sb`. Three tabs:

- **Active Bans** – lists all name and IP bans.
- **Active Mutes** – lists all name and IP mutes.
- **Player Log** – enter a name and click "View Log" to see that player's combined history.

## Storage Details

- **Name bans/mutes** – stored in core mod storage under keys `name_bans`, `name_mutes`.
- **Name logs** – per player, key `log_name:playername`.
- **IP bans/mutes** – stored in `ipdb` per‑entry storage under keys `"ban"` and `"mute"`. A lightweight copy for listing is kept in core mod storage under `ip_ban_list` and `ip_mute_list`.
- **IP logs** – per player, stored in `ipdb` per‑entry storage under key `"log"`.

## License

GPL‑3.0‑or‑later © 2026 Marko Petrović