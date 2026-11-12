# recorder_capture – regional gameplay recording

Captures a cuboid's initial world state, subsequent node/light/metadata changes,
player actions and per-step movement in a self-contained SQLite file. Multiple
recordings can run concurrently, each with its own region and file. Rows share
a timeline id sequence; unchanged movement samples are omitted and writes are
batched. Mods can add metadata and custom events.

## Installation

Install the modpack in `mods/`, enable capture, install `lsqlite3` (for example,
`luarocks install lsqlite3`), and add `recorder_capture` to `secure.trusted_mods`
or `secure.c_mods`. `algorithms` loads the library. The recorder creates its
output directory if permitted; create it manually otherwise.

## API

The global `recorder` table supports concurrent recordings. `start` returns
`id` or `nil, error`; `stop` and `add_meta` return `nil` on success or an error
string. Each caller supplies its region directly or through chat-command marks;
there is no capture-region provider.

```lua
-- A recording needs its region: two corners, in any order.
local id, err = recorder.start("ctf-match", {
	pos1 = {x = 0, y = 0, z = 0},
	pos2 = {x = 63, y = 31, z = 63},
})
if not id then core.log("error", "no recording: " .. tostring(err)) end

recorder.add_meta("ctf:map", "forge", id)   -- only while a recording is in progress
recorder.add_meta("ctf:teams", "red:blue", id)

-- Another mod can put its own happenings into the same timeline
recorder.log_event("ctf:capture", {
	subject = player,                       -- ObjectRef or player name
	item = "ctf:flag_red",
	pos = { x = 1, y = 2, z = 3 },
	data = { team = "red", score = 3 },
})

recorder.stop(id)                           -- nil, or a message
```

| Function | Behaviour |
| --- | --- |
| `recorder.start([name], region)` | Return `id` or `nil, error`. Requires `{pos1, pos2}` corners with numeric `x/y/z`; reject invalid regions or the concurrency limit. `name` defaults to `"unnamed"` and supplies the filename. Snapshotting runs in subsequent steps. |
| `recorder.stop([id], [reason])` | Stop one recording; id is required when several run. Persist `reason`; automatic stops supply their own. Return an error if final writes fail (see *Stopping*). |
| `recorder.add_meta(key, value, [id])` | Store a string pair while capturing. The `recorder.` key prefix is reserved. |
| `recorder.log_event(type, fields)` | Offer a custom event to every active capture, subject to regional filtering. Use `modname:what` types to avoid collisions. |
| `recorder.is_recording()` | `true` while at least one recording is capturing; `false` while a recording is only taking its snapshot. |
| `recorder.list()` | Active entries: id, name, path, capture/snapshot state, elapsed time and region. |
| `recorder.get_recording_name([id])` / `get_recording_path([id])` | Return name/path or `nil`; id is optional with one recording. |

## Chat commands

`/recorder` requires `server` privilege.

| Command | Purpose |
| --- | --- |
| `/recorder [status [id]]` | Active captures/snapshot progress, duration, row/loss counts and file size; no id shows all. |
| `/recorder pos1` / `pos2` | Mark a region corner at your position; marks are cleared on disconnect. |
| `/recorder unset` | Clear region marks. |
| `/recorder start [name] [x1,y1,z1 x2,y2,z2]` | Start and return an id; use your marks if coordinates are omitted. |
| `/recorder stop [id]` | Stop; id is optional when only one recording runs. |
| `/recorder meta [id] <key> <value>` | Add recording metadata. |
| `/recorder settings ...` | [Inspect/change/reset world settings](../README.md#world-settings). |

## Settings

[World settings](../README.md#world-settings) defines precedence and commands.
Capture options apply to new recordings; [retention](../README.md#recording-retention)
limits manage saved files.

| Setting | Default | Meaning |
| --- | --- | --- |
| `recorder.directory` | empty | Where recordings are written. A relative path is taken from the world directory, an absolute path as it is. Empty means `world/recordings/`. |
| `recorder.max_recordings` | `4` | How many recordings may run at once; `0` is no limit. |
| `recorder.snapshot_budget` | `20000` | Snapshot nodes processed per step; lower values reduce traversal stalls. |
| `recorder.compression_level` | `6` | Snapshot/light deflate level: `1` fastest, `9` smallest. Final compression runs in one step. |
| `recorder.diff_budget` | `8` | Mapblocks diffed per step during opening reconciliation and capture. `0` processes all; smaller budgets reduce stalls but delay catch-up. |
| `recorder.flush_interval` | `2.0` | Seconds of server time between commits. |
| `recorder.max_buffered` | `20000` | Rows buffered before a commit is forced early. `0` leaves the timing to `flush_interval` alone. |
| `recorder.max_duration` | `0` | Stop the recording after this many seconds. `0` is no limit. |
| `recorder.max_size_mb` | `0` | Stop the recording once the file reaches this size. `0` is no limit. |
| `recorder.disabled_events` | empty | Comma-separated event types not to record, e.g. `dig, particle`. The recording's own markers (`recording_start`, `recording_stop`, `write_error`) and `node_change` cannot be disabled. |
| `recorder.metadata` | `true` | Record node metadata/inventories. Disabled files contain no metadata rows and remain replayable. |
| `recorder.light` | `true` | Record dense lighting, including air. If disabled, replay recalculates light; time of day is always recorded. |
| `recorder.particles` | `true` | Record all three particle event types; `disabled_events` can exclude them individually. |
| `recorder.chat` | `true` | Record final globally delivered chat; `disabled_events = chat` also disables it. |

## The recording file

Files are `<directory>/<name>-<YYYYmmddTHHMMSSZ>.sqlite` (UTC), defaulting to
`world/recordings/`. Names retain letters, digits, `-`, `_`, `.`; leading dots
are removed. Collisions append `-2`, `-3`, etc.; existing files are never reused.

WAL permits concurrent readers. A clean stop checkpoints the `-wal` into the
main file. After a crash, committed rows survive, up to one `flush_interval` of
rows may be missing, and there is no `recording_stop` marker. Preserve any `-wal`
when moving a recording, or checkpoint it first; the `.sqlite` alone may omit
committed rows.

## Format

`PRAGMA user_version` is the schema version (`1`), and
`PRAGMA application_id = 0x4A4D4152` (`'JMAR'`) marks the file as a recording.
See `schema.sql` for the same information next to the tables.

| Table | Holds |
| --- | --- |
| `Metadata` | `key`, `value` – what `recorder.add_meta` writes, plus the `recorder.*` keys describing the recording (name, start and stop times, time of day, engine version, game, tick count, why it ended, and any player whose row could not be written). |
| `Snapshot` | One row: the region's low corner and size, the node names it uses, the compressed body of non-air nodes as the world was when the recording began, and optionally the light layer. |
| `Players` | `id`, `name` – one row per player seen during the recording. |
| `Movement` | Player kinematics, one row per player per server step in which something about that player changed. |
| `Events` | One row per action. |
| `NodeMetadata` | Node metadata and inventories: a baseline at tick 0, then one row whenever the periodic scan sees a change. |
| `LightChanges` | The light values that changed, one row per diff round. |

### The region

- Sample players inside the cuboid. Crossing its boundary emits `leave`/`join`
  with `data.reason = "region"`; re-entry resets per-player state, including
  derived acceleration.
- Player events require the subject and any object player inside. Events without
  players use their position; custom events with neither player nor position
  are kept.
- Lifecycle/gap markers (`join`, `leave`, `recording_start`, `recording_stop`,
  `write_error`) bypass filtering. Global chat also bypasses regional filtering.

### The snapshot

The snapshot precedes recorded actions. It stores non-air node names and param2
in VoxelManip flat order (x fastest, then y, then z), with `encoding` set to
`deflate` or `raw`. Content ids are run-specific and never stored.

Startup emerges the region, reads one VoxelManip, then walks/encodes slices of
`recorder.snapshot_budget` nodes per step. Final compression and the database
write run in one step; `recorder.compression_level` controls compression cost.

Capture remains inactive during snapshotting and opening-state catch-up: other
events/samples are dropped and status reports progress. `recording_start` is
written before queued mapblock changes are reconciled at tick 0, bounded by
`recorder.diff_budget`. Joins and sampling follow once the queue empties.
Stopping during either phase abandons the file.

### World changes

Mapblock-change notifications trigger diffs against the snapshot plus known
changes, capturing explosions, liquids, ABMs, timers and mod writes without
cooperation. Callback hashes encode mapblock positions, converted to node
coordinates by multiplying by 16. Each changed node produces `node_change` with
its new node/param2 and previous values in `data`.

Diffs are limited by `recorder.diff_budget` per step and retain their queued
`tick`/`t`. Buffering occurs later, so their ids can follow other rows from the
same tick. Opening-state changes use tick 0. `node_change` cannot be disabled.

### Node metadata

`id`, `tick`, `t`, `pos_x/y/z`, `data`.

`data` is `core.serialize(NodeMetaRef:to_table())`, with inventory ItemStacks
converted to itemstrings. Preserve every list and slot, including empty slots,
to retain inventory sizes. Empty data clears metadata when a node loses it or
is removed.

Tick 0 holds the snapshot baseline. Later changes are detected by a once-per-second
`find_nodes_with_meta` scan and timestamped at that scan; only differences are
stored. Unloaded mapblocks are skipped. `recorder.metadata = false` disables
metadata capture.

### Lighting

`recorder.light` defaults on. Snapshot `light` is dense, one byte per region
node in snapshot order: low 4 bits skylight, high 4 artificial light. Air must be
included because visible faces sample adjacent light values.

Mapblock diffs also report light-only changes. Each diff round stores changed
region indexes and new light bytes in `LightChanges`, using the snapshot codec
and compression; no light polling is needed.

### Movement

`id`, `tick`, `t`, `dtime`, `player_id`, `pos_x/y/z`, `pitch`, `yaw`,
`vel_x/y/z`, `acc_x/y/z`, `speed`, `controls`, `move_x`, `move_y`.

- `pitch`/`yaw` are radians from the player's look getters; `speed` is `|vel|`.
- `acc_*` is velocity delta / `dtime` for that player, NULL on the first sample.
- `controls`: bit 0 up, 1 down, 2 left, 3 right, 4 jump, 5 aux1, 6 sneak,
  7 dig, 8 place, 9 zoom (`get_player_control_bits()`). `move_x/y` are analog
  axes from `get_player_control()`.
- Unchanged samples are omitted; readers carry the previous state forward.
  Acceleration participates in comparison: the initial unknown value followed
  by zero produces two samples even for a stationary player.

### Events

`id`, `tick`, `t`, `type`, `subject_player`, `object_player`, `pos_x/y/z`, `node`,
`param2`, `item`, `data`.

`subject_player` is the actor; `object_player` is the affected player. Missing
participants are NULL. Non-player actors use `data.actor`: `entity:<name>`,
`object`, `unknown`, or absent when there is no actor.

`pos_*` describes the action target; the actor's position is in `Movement`.
`node`/`param2` describes the node; engine-derived `param1` is omitted. `item`
is an itemstring and `data` is event-specific JSON, queryable with SQLite JSON
functions, e.g. `json_extract(data, '$.reason.type')`.

| `type` | subject | object | columns filled | `data` |
| --- | --- | --- | --- | --- |
| `recording_start` | – | – | – | – |
| `recording_stop` | – | – | – | `reason` (`api`, `shutdown`, `limit_duration`, `limit_size`, `write_error`) |
| `write_error` | – | – | – | `dropped_rows`, `message` – a gap in the recording, see below |
| `join` | player | – | `pos`, `item` (wielded) | `at_start`, `last_login`, `reason` (`region` for a walk-in), `hp`, `breath`, `pitch`, `yaw`, `textures`, `inventory` |
| `leave` | player | – | `pos` (where they were, if the engine still answers for them) | `timed_out`, `reason` (`region` for a walk-out) |
| `die` | player | – | `pos` | `reason` |
| `respawn` | player | – | `pos` (before being moved) | – |
| `hp_change` | player | – | `pos` | `amount`, `reason` |
| `wield` | player | – | `item` | – |
| `animation` | player | – | – | `frames` (`{x, y}`), `speed`, `blend`, `loop` – the engine's animation values while the player wears that pose |
| `punch_player` | hitter | punched player | `pos` (of the punched) | `damage`, `dir`, `time_from_last_punch`, `tool`, `actor` |
| `punch_node` | puncher | – | `pos`, `node`, `param2`, `item` | `actor` |
| `dig` | digger | – | `pos`, `node` (dug), `param2`, `item` (tool) | `actor` |
| `place` | placer | – | `pos`, `node` (placed), `param2`, `item` (stack) | `old_node`, `old_param2`, `actor` |
| `rightclick_player` | clicker | clicked player | `pos` (of the clicked), `item` | `actor` |
| `craft` | player | – | `item` (output) | `grid` |
| `item_eat` | player | – | `item` | `hp_change`, `replace_with`, `actor` |
| `item_pickup` | picker | – | `item` | `actor` |
| `inventory_move`, `inventory_put`, `inventory_take` | player | – | `item` | `from_list`, `to_list`, `from_index`, `to_index`, `listname`, `index`, `count` |
| `chat` | player or – | – | `pos` (when the sender is online) | `message` (the line as clients received it), `source` (the funnel or relay tag) |
| `protection_violation` | player | – | `pos` | – |
| `cheat` | player | – | `pos` | `cheat` |
| `node_change` | – | – | `pos`, `node` (what it became), `param2` | `old_node`, `old_param2` |
| `particle` | – | – | `pos` | `definition` (the engine's particle table) |
| `particlespawner` | – | – | `pos` (centre of the emission box) | `definition`, `id` (the engine's spawner id) |
| `particlespawner_delete` | – | – | – | `id`, `playername` |

`reason` is a `PlayerHPChangeReason` (`type`, `custom_type`, `from`, `object`,
`node`, `node_pos`) with ObjectRefs replaced by player names. `grid` and
`inventory` preserve itemstrings slot-for-slot; empty slots are empty strings.
For inventory moves, `item` describes the destination stack after the move and
`count` gives the amount moved.

### Particles

Capture wraps `core.add_particle`, `core.add_particlespawner` and
`core.delete_particlespawner`, preserving arguments/results. Deprecated
positional calls are normalized to definition tables and stored as JSON.
Particles must lie inside the region; spawner emission boxes must intersect it.
Spawner events retain engine ids for matching deletes.

Object-attached effects (`attached` or attractor `*_attached`) are skipped with
one warning: their position/yaw needs the absent entity. Player restrictions
(`playername`/`exclude_player`) are stored, but replay shows effects to all
viewers. `recorder.particles = false` disables all three event types;
`recorder.disabled_events` can disable them individually.

### Chat

`chat` stores final globally delivered lines, including filters, prefixes,
colours and case changes. It is global, so it bypasses regional filtering.
Player lines have a sender/position when available; broadcasts have no sender.

After mods load, `chathooks.lua` observes independent delivery paths:

- `block_msgs.chat_send_all` for formatted player lines sent to non-blocking
  recipients; `data.source = "block_msgs"`.
- `chat_lib` send-all callbacks for broadcasts/relays; source is the library's
  tag (`discordmt`, `xmpp_relay`, etc.) or `chat_send_all`.
- Without a working `block_msgs` backend, `core.format_chat_message` is the
  fallback for player lines, with source `format_chat_message`.

Hooks preserve cancellation/results and avoid duplicate formatted broadcasts.
Raw input, commands as commands, private/team chat, per-player feedback and
engine-originated messages outside Lua are not captured. Calls bypassing hooks
via a saved original chat function are also invisible. Disable chat with
`recorder.chat = false` or `recorder.disabled_events = chat`.

### How a recording opens and closes

After the snapshot, `recording_start` precedes opening node changes at tick 0.
Initial `join` events (`data.at_start`) and samples are taken on the first active
server step, after opening-state reconciliation; simultaneous actual joins are
not duplicated. This also permits starting capture while mods load, before
world reads are available. `recording_stop` closes the timeline with `data.reason`.

### Order and time

`id` is assigned when buffering and orders rows across timeline tables.
`tick` counts server steps; `t` is elapsed server time in seconds, shared by rows
of a tick. Step lengths vary; `Movement.dtime` records each step's length.
Neither is a wall clock: wall time is `Metadata['recorder.started_at'] + t`.
Delayed world diffs retain their original tick even if buffered later.

```sql
-- Everything that happened, in order
SELECT * FROM Timeline ORDER BY id;

-- What Alice did, with where she was at the time
SELECT e.tick, e.type, m.pos_x, m.pos_y, m.pos_z
FROM Events e JOIN Movement m ON m.player_id = e.subject_player AND m.tick = e.tick
WHERE e.subject_player = (SELECT id FROM Players WHERE name = 'Alice')
ORDER BY e.id;

-- Who was punched, by whom, with what
SELECT s.name AS puncher, o.name AS punched, e.tick, e.data
FROM Events e
JOIN Players s ON s.id = e.subject_player
JOIN Players o ON o.id = e.object_player
WHERE e.type = 'punch_player';
```

### Gaps

Failed batches are dropped to bound memory; `write_error` records lost-row
counts and the error. The next player samples are forced, and lost wield
changes are re-announced. SQLite lock waits are bounded to 250 ms per statement.
After repeated failures, capture stops with reason `write_error`.

Look for these events if you need to know whether a recording is complete:

```sql
SELECT tick, data FROM Events WHERE type IN ('write_error', 'recording_stop');
```

Failed `Players` inserts are retried on the next sighting. Until then events
have no subject; `Metadata['recorder.player_errors']` records the failures,
attempted immediately and retried after successful commits. Lifecycle/gap
markers cannot be disabled through `recorder.disabled_events`.

### Stopping

`recorder.stop()` stops even when final writes fail, returning an error string.
Such recordings lack a reliable final marker/stop metadata. Active readers may
prevent a WAL checkpoint; capture logs/reports that failure, and `-wal` must
remain with the `.sqlite`.

## What is not recorded

- Item use/rightclicks without a global callback; formspec/GUI input and other
  actions without hooks. Dig/place/eat/craft are captured through their hooks.
- Lua entities: mobs, drops and projectiles.
- Node timer state; resulting node changes are captured.
- Login/IP data (`ipdb` handles connection data).

## Performance

Callbacks buffer rows; globalstep commits batches every `recorder.flush_interval`
seconds or at `recorder.max_buffered`. Player sampling still polls wielded
ItemStacks and animation each step even when no movement row is written. The
engine's unset animation (frames 1..1 at 15 fps) is ignored so replay can infer
movement poses.

Per-step particle emitters can dominate row counts; spawners need only create
and delete rows. Disable `recorder.particles` or just `particle` events when
appropriate. Snapshot/diff budgets bound traversal work, but final snapshot
compression and writing remain single-step operations.

## Tests

Run `tests/run_tests.sh` with LuaJIT (preferred) and `lsqlite3`. Tests use a
mocked engine and real SQLite to cover the schema, API, capture, ordering,
settings, failure handling and retention.

## License

GPL-3.0-or-later, see the SPDX headers in the source files.
