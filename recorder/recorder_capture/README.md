# recorder_capture – record what happens on the server, in order, into SQLite

recorder_capture is the recording half of the `recorder` modpack. It writes down
what players do and where they are: every action that Luanti offers a callback
for (digging, placing, punching, talking, crafting, dying, ...) and one sample
per player per server step of the kinematic state that goes with it (position,
orientation, velocity, derived acceleration, pressed keys). All of it lands in a
single SQLite file per recording, in the order in which it happened, so the
recording can later be replayed, analysed, or just read with the `sqlite3`
shell.

A recording covers one cuboid region. It begins with a snapshot of the world
inside that region, and from then on only players and actions inside it are
recorded. That is what makes the file self-contained: a replay needs the
recording, not the game's map files.

## Features

- **One region per recording**: a cuboid, decided when the recording starts.
  Only players and actions inside it are recorded, so a recording of a match
  does not carry the rest of the world.
- **Several recordings at once**: each over its own region and into its own
  file - a match and a practice area, say - with a shared limit on how many.
- **Self-contained**: the world inside the region is stored as a snapshot
  before the recording begins, so a replay does not need the original game's
  map files.
- **World changes, without cooperation**: a changed mapblock is read back and
  diffed, so explosions, flowing liquids, ABMs, node timers and a mod's own
  `set_node` all land in the file as `node_change` rows.

- Records actions with their **subject** (who did it) and **object** (whom it was
  done to), plus the position, node, item and any event-specific detail.
- Records **per-tick player kinematics**: position, pitch, yaw, velocity,
  acceleration, speed, the pressed-key bitmask and the analog movement axes.
- **Ordered across everything**: rows of both tables draw their `id` from one
  sequence, so a single `ORDER BY id` reproduces the recording (see the `Timeline`
  view).
- **One file per recording**, named after the recording and the UTC time it began,
  inside `world/recordings/`.
- **Metadata**: mods can attach their own key/value pairs to a recording (which
  CTF map was being played, what the weather was, ...).
- **Cheap enough to leave running**: rows are committed in batches, not one
  action at a time, and ticks in which nothing changed are not written at all.
- Optional **limits** on the length and size of a recording, useful where the
  world directory lives on a small (or memory-backed) filesystem.

## Requirements

- `lsqlite3` – must be installed on the system and the mod must be added to
  `secure.trusted_mods` or `secure.c_mods` (the same requirement as `ipdb`, which
  the database layer is modelled on).
- `algorithms` – for loading the library.

## Installation

1. Place the modpack folder in your `mods/` directory.
2. Ensure `lsqlite3` is available (e.g. `luarocks install lsqlite3`).
3. Add `"recorder_capture"` to `secure.trusted_mods` in `minetest.conf`.
4. Create `world/recordings/` if you want it somewhere the mod cannot create
   itself (it creates the directory if it can).

## API

The mod exposes a global `recorder` table. `start` returns the recording's id;
`stop` and `add_meta` return `nil` on success and a string describing the
failure otherwise. Several recordings can run at once, each over its own region
and into its own file, and the id says which one a call is about.

A recording needs a region, and it is always the caller's: `start` takes one, and
the chat command uses the marks of the player who asked. There is deliberately
no provider to fall back on - a recording is about a particular place, and only
the caller knows which.

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
| `recorder.start([name], region)` | Starts a recording and returns its id, or `nil` and a message. Fails if `recorder.max_recordings` is reached, or if the region is missing or invalid. `region` is `{pos1 = , pos2 = }`, two corners with numeric `x`, `y` and `z`, and is required. Returns before the region has been read: the snapshot phase runs in the following server steps (see below). `name` is used to build the file name and defaults to `"unnamed"`. |
| `recorder.stop([id], [reason])` | Stops one recording. With a single recording running the id may be left out; with several it is required. Fails if the last rows could not be written (see *Stopping* below). `reason` is stored in the recording; the automatic stops use their own. |
| `recorder.add_meta(key, value, [id])` | Stores a string pair about a recording. Works only while recording. Keys starting with `recorder.` describe the recording itself and are refused. |
| `recorder.log_event(type, fields)` | Records an event of a mod's own making. Offered to every recording; each keeps it if its region says it belongs there. Works only while recording. Use a `modname:what` type to stay clear of the types below. |
| `recorder.is_recording()` | `true` while at least one recording is capturing; `false` while a recording is only taking its snapshot. |
| `recorder.list()` | What is running now: id, name, path, whether it is recording or still snapshotting, elapsed time and region. |
| `recorder.get_recording_name([id])` / `get_recording_path([id])` | The name and the file of a recording, or `nil`. With one recording the id may be left out. |

## Chat commands

`/recorder` needs the `server` privilege.

- `/recorder` or `/recorder status [id]` – what is being recorded, for how long,
  how much has been written, how much was lost, and how big the file is. With no
  id it describes every running recording. While the snapshot is being taken it
  reports that instead, with its progress.
- `/recorder pos1` / `/recorder pos2` – mark a corner of the region at your
  current position. The marks are yours, and are dropped when you disconnect.
- `/recorder unset` – forget your marks.
- `/recorder start [name] [x1,y1,z1 x2,y2,z2]` – start recording; the reply
  carries the new recording's id. Without coordinates it uses your marks.
- `/recorder stop [id]` – stop a recording. With one running the id may be left
  out.
- `/recorder meta <key> <value>` – attach a pair to the current recording.

## Settings

Settings are read when a recording starts, so a change applies to the next one.

| Setting | Default | Meaning |
| --- | --- | --- |
| `recorder.directory` | empty | Where recordings are written. A relative path is taken from the world directory, an absolute path as it is. Empty means `world/recordings/`. |
| `recorder.max_recordings` | `4` | How many recordings may run at once; `0` is no limit. |
| `recorder.snapshot_budget` | `20000` | Region nodes examined per server step while the snapshot is taken. Lower it on a server that must stay responsive while snapshotting a large region. |
| `recorder.compression_level` | `6` | Deflate level for the snapshot body and the light layer: `1` is fastest, `9` smallest. The final compression runs in one step, so lower it if a large snapshot causes a pause. |
| `recorder.diff_budget` | `8` | Mapblock entries diffed per server step while reconciling the opening state before the recording starts, and while catching up during it. `0` processes them all at once. Lower it if those steps pause; raising it shortens the wait before the recording starts. |
| `recorder.flush_interval` | `2.0` | Seconds of server time between commits. |
| `recorder.max_buffered` | `20000` | Rows buffered before a commit is forced early. `0` leaves the timing to `flush_interval` alone. |
| `recorder.max_duration` | `0` | Stop the recording after this many seconds. `0` is no limit. |
| `recorder.max_size_mb` | `0` | Stop the recording once the file reaches this size. `0` is no limit. |
| `recorder.disabled_events` | empty | Comma-separated event types not to record, e.g. `dig, particle`. The recording's own markers (`recording_start`, `recording_stop`, `write_error`) and `node_change` cannot be disabled. |
| `recorder.metadata` | `true` | Record node metadata and inventories (chest contents, sign text, ...). With `false` the recording holds no metadata rows; replay handles both kinds of file the same way. |
| `recorder.light` | `true` | Record the region's lighting (a byte per node, air included). With `false` the snapshot holds no light layer and replay recalculates the light instead. The time of day is recorded either way. |
| `recorder.particles` | `true` | Record particle and particle-spawner calls. With `false` none of the three particle event types is written; `recorder.disabled_events` turns them off one at a time. |
| `recorder.chat` | `true` | Record the final client-visible global chat line (`chat`). With `false` no chat rows are written; `recorder.disabled_events = chat` does the same per type. |

## The recording file

Each recording is a new file, `world/recordings/<name>-<YYYYmmddTHHMMSSZ>.sqlite`,
named after the recording and the UTC time at which it began. The name is reduced
to letters, digits, `-`, `_` and `.` (leading dots dropped), and if the file name
is already taken `-2`, `-3`, ... is appended – an existing recording is never
appended to or overwritten.

The database is opened in WAL mode, so a query against a recording that is still
being written does not block the server. While recording there is a `-wal` file
next to the `.sqlite`; stopping checkpoints it back in and the file is on its own.
If the server dies without stopping the recording, everything committed so far is
still in the file, up to one `flush_interval` of rows is missing, and a `-wal`
file is left behind – moving the `.sqlite` somewhere else on its own would drop
those rows, so either take both or open the database once to fold them in. A
recording that was cut short has no `recording_stop` event.

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

A recording covers one cuboid, decided before the snapshot. Everything the file
says lies inside it:

- Only players inside the region are sampled. A player who walks out gets a
  `leave` with `data.reason = "region"`; a player who walks back in gets a
  `join` with the same reason. Their per-player state is dropped on the way out,
  so a re-entry starts like a fresh join (no acceleration from a stale sample).
- An event is recorded when the subject, and the object when there is one, is
  inside the region. An event with no player in it (a mob's dig, an explosion)
  is judged by the position it is about. A mod's own event with neither a
  player nor a position is kept: nothing in it could lie outside.
- `join`, `leave`, `recording_start`, `recording_stop` and `write_error` are
  never filtered: they are about the recording, not about the world.

### The snapshot

The snapshot is taken before the first recorded action and written as one row
before `recording_start`. Only non-air nodes are stored, by name and param2, in
the region's flat-array order (x fastest, then y, then z - the order VoxelManip
numbers nodes); the body is deflated, and `encoding` says whether it is
(`deflate`) or was stored raw. Content IDs are never stored: an id is only
stable for one run of one server, and the file has to be readable elsewhere and
later.

Taking it happens in server steps: the area is emerged first, then read with one
VoxelManip, then walked in slices of `recorder.snapshot_budget` nodes. The node
body and the light layer are encoded as the walk proceeds, so only the final
compression and the database write happen when the phase ends; the deflate
level is `recorder.compression_level`. Until the phase finishes the recording
is not active - events and samples are dropped exactly as they are when nothing
is being recorded - and `/recorder status` reports the phase. Stopping during
the phase abandons the recording and removes the file.

When the walk finishes the recorder is still not active. The mapblocks that
changed during the snapshot are queued, and they are the opening state: they are
diffed a few per step (`recorder.diff_budget`) before the recording starts, so
every one of them is tick 0 and no sampled tick can inherit a change that
happened before it. The `recording_start` marker is written first; the joins
and the first sample follow once that queue is empty. The wait is reported by
`/recorder status`, and stopping while it lasts removes the file, just as
stopping during the snapshot does.

### World changes

The snapshot is kept true by watching the region, not by asking mods to report.
The engine says which mapblocks changed, at most once per server step; it names
them by their mapblock position in mapblock units (the hash format is shared
with `hash_node_position`, but the position inside is not a node position), and
the recorder turns that into the node-space base corner. It reads those blocks
back and compares them with what it last knew, and every node that differs
becomes a `node_change` row carrying the node it became and, in `data`, what it
was. That is what captures an explosion, a flowing liquid, an ABM, a node timer
and a mod's own `set_node`, with no cooperation from any of them.

The comparison is against the snapshot plus every change since, so the rows are
exactly the difference between the snapshot and the world. A change that
happened while the snapshot was being taken is queued and diffed when the
recording starts; the catch-up is limited to `recorder.diff_budget` entries per
step, so a long snapshot does not turn into one long first step. Those rows
keep the tick they were queued on (usually 0). A row is buffered one step after
the step it belongs to, so its `id` can be later than that of other rows sharing
its `tick`; the `tick` and `t` columns are what say when it happened.
`node_change` cannot be switched off: a recording whose world drifts from its
snapshot would be a recording of something else.

### Node metadata

`id`, `tick`, `t`, `pos_x/y/z`, `data`.

`data` is `NodeMetaRef:to_table()` serialized with `core.serialize`, with
inventory slots reduced to itemstrings: `fields` holds the metadata fields
(sign text, owner, formspec, infotext, ...) and `inventory` holds every list,
slot for slot, so a chest keeps both its contents and its size. An empty
string is a deliberate clearing: the node stopped having metadata, or the node
went away.

The first rows are the baseline at tick 0, taken with the snapshot. Later
changes have no engine callback, so the region is scanned once a second
(`find_nodes_with_meta`) and compared with what the recording knows; only
differences become rows, and their `tick`/`t` are those of the scan that saw
them. A position whose mapblock is unloaded is left alone rather than mistaken
for an emptied node. `recorder.metadata = false` turns the whole thing off.

### Lighting

With `recorder.light` on (the default), the snapshot's `light` column holds one
byte per node of the region, in the same flat order as the node body, and
`LightChanges` holds the values that change later. A byte is the engine's own
format: the low 4 bits are skylight and the high 4 bits artificial light.

Air is part of the layer, and it is the important part: a face is shaded by the
light of the node in front of it, so the values that light a wall live in the
air beside it. The layer is therefore dense, not sparse like the node body (it
compresses well because lighting is smooth).

Light changes ride the same mapblock diff as `node_change`: the callback reports
blocks whose light changed even when no node did, so a torch lighting a room is
caught. The diff records one row per round, holding the region indexes whose
light changed and their new values, encoded with the snapshot codec and
compressed. There is no polling.

### Movement

`id`, `tick`, `t`, `dtime`, `player_id`, `pos_x/y/z`, `pitch`, `yaw`,
`vel_x/y/z`, `acc_x/y/z`, `speed`, `controls`, `move_x`, `move_y`.

- `pitch` (up/down) and `yaw` (around) are radians, as returned by
  `get_look_vertical()` and `get_look_horizontal()`.
- `speed` is `|vel|`, kept because filtering by speed is the common query.
- `acc_x/y/z` is derived from the difference between this sample and the previous
  one of the same player, divided by `dtime`. It is NULL for a player's first
  sample: there is nothing to derive it from.
- `controls` is the bitmask documented for `ObjectRef:get_player_control_bits()`
  (bit 0 `up`, 1 `down`, 2 `left`, 3 `right`, 4 `jump`, 5 `aux1`, 6 `sneak`,
  7 `dig`, 8 `place`, 9 `zoom`), and `move_x`/`move_y` are the analog axes from
  `get_player_control()`, which carry joystick input the buttons do not describe.
- **Ticks in which nothing about a player changed are not written.** A reader
  carries the previous row of that player forward; the player was still there and
  still where the last row put them. Acceleration is part of the comparison, so a
  sample is only left out when it says nothing new – including the two samples
  right after a player appears, where the first says the acceleration is unknown
  and the second says it is zero.

### Events

`id`, `tick`, `t`, `type`, `subject_player`, `object_player`, `pos_x/y/z`, `node`,
`param2`, `item`, `data`.

`subject_player` is who performed the action and `object_player` is the player it
was performed on; either is NULL when the event has no such participant. An actor
that is not a player (a mob digging, an explosion) has no `Players` row to point
at, so `data.actor` describes it instead – as `entity:<entity name>`, `object`,
`unknown`, or absent when there was no actor at all. `pos_x/y/z` is the position
the event is *about* (the dug node, the player who was hit, where somebody spoke);
the actor's own position is in `Movement` for the same tick. `node` is a node name
with its `param2` (`param1` is derived by the engine from lighting and flow, so it
is not stored). `item` is an itemstring. `data` is a JSON object with the rest –
SQLite's JSON functions can dig into it, e.g.
`json_extract(data, '$.reason.type')`.

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

`reason` is a `PlayerHPChangeReason` with its ObjectRef replaced by the name of the
player it points at: `type`, `custom_type`, `from`, `object`, `node`, `node_pos`.
`grid` is the crafting grid as itemstrings, slot for slot. `inventory` is every
list of the player's inventory at that moment, as itemstrings, slot for slot, with
an empty string for an empty slot. `item` on an inventory action is the stack the
action moved – for a `move` within one inventory, which does not say what it
moved, it is what the move left in the destination slot, with `count` telling how
much of it moved.

### Particles

`core.add_particle`, `core.add_particlespawner` and
`core.delete_particlespawner` have no callback, so capture wraps them at load.
The original is always called with the caller's arguments, and its return
values are returned unchanged – the recorder is watching, not substituting.
Definitions are written as the JSON table the engine documents today (the
deprecated positional calls are normalized to it) and are filtered by the
recording's region: a single particle by its position, a spawner by the box it
can emit in, which has to intersect the region at all. A spawner's row also
carries the id the engine returned, so a later `particlespawner_delete` can
name it.

A definition attached to an object (`attached`, or an attractor's
`*_attached` field) is not recorded: it follows that object's position and
yaw, which a file cannot reproduce, so it is reported once in the log rather
than replayed at a wrong, fixed position. A per-player definition
(`playername`/`exclude_player`) is recorded as it is; replay shows it to every
watcher.

A per-step emitter – a rocket's smoke trail, say – writes one `particle` row
per step for as long as it runs. `recorder.particles = false` turns all three
types off; `recorder.disabled_events` names them one at a time.

### Chat

The `chat` event is the line clients actually received, after every filter,
cap-lowering, prefix and colour: that is the line replay shows. It is not the
player's raw input, and commands are not a separate event; `chat` exists only
when something was delivered globally.

There is no single engine callback that sees all delivered global chat, so
capture installs its witnesses after all mods have loaded, on the two funnels
the server's chat plumbing exposes:

- normal player chat, at the call that delivers the formatted line to the
  players who did not block the sender (`block_msgs.chat_send_all`);
- mod broadcasts – spectator chat, `/g`, `/me`, announcements, messages
  relayed in from Discord or XMPP – through the chat library's send-all
  callback list.

When that plumbing is absent (or `block_msgs`' backend failed, in which case
it registers no chat callback), the engine formats player chat itself and
calls the Lua formatter last, so a wrapper around `core.format_chat_message`
takes its place. The module that decides this is `chathooks.lua`; it reads
`chat_lib`/`block_msgs` only when they exist and never changes their return
values or cancellation behaviour.

A `chat` row's `data.source` says where the line came from: `block_msgs` for
normal player chat, `format_chat_message` for the fallback, the chat
library's own tag for a relayed broadcast (`discordmt`, `xmpp_relay`, ...),
or `chat_send_all` when the caller gave none. Player lines carry their
sender; broadcasts have none. Chat is global, so it is not filtered by the
recording's region – a recording keeps the conversation around it even when
the speaker is elsewhere.

What is not recorded: the player's raw input before formatting, slash
commands as commands (`/g` and `/me` appear only as their broadcast line),
private messages, team chat and command feedback (per-player, not global),
and the messages the engine itself sends – chat throttling and length
errors, shutdown notices – which never pass through Lua. A mod that calls
the chat library's saved original function directly also bypasses every
witness. `recorder.chat = false` (default true) keeps the event out;
`recorder.disabled_events = chat` does the same per type.

### How a recording opens and closes

Before any of that, `start()` takes the region's snapshot (see *The snapshot*
above). When the snapshot is done the file holds the world as it was, the
recorder writes its opening marker, and it then reconciles the changes queued
during the snapshot before it samples anything. The recording's first sampled
tick is the first one after that.

A recording opens with a `recording_start` event; any node changes that are part
of the opening state follow at tick 0, and then a `join` event for everyone in
the region at the moment the recorder becomes active (with `data.at_start`). It
closes with a `recording_stop` event carrying `data.reason`. The `at_start`
joins are written at the first server step after the recording becomes active,
because a mod may start a recording while it is still loading and the engine
answers no questions about the world before the server is running; a player who
joins in that same moment is joined once, not twice.

### Order and time

`id` counts rows in the order in which they happened, across both tables – it is
handed out when a row is buffered, not when it is written. `tick` counts server
steps since the recording started and `t` is the server time since then, in
seconds; rows of the same tick share a `t`, because a `t` is the time of the step
they belong to. Neither is a wall clock – wall time is
`Metadata['recorder.started_at']` plus `t`. Server steps are not a fixed length,
which is why `Movement` also carries `dtime`, the length of that particular step.

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

A batch of rows that cannot be written is dropped rather than retried forever
(buffering while the disk stays full would end with the server out of memory), and
the recording says so: a `write_error` event carries how many rows were lost and
why. After such a gap every player's next sample is written even if nothing
changed, and a held item that changed while the rows were lost is announced
again, so a reader is never left carrying a state that may have been lost. A
statement waits at most a quarter of a second for a lock before its batch is
given up on: this runs inside a server step, and a step that stalls is worse for
the players than rows that are reported as lost.

Look for these events if you need to know whether a recording is complete:

```sql
SELECT tick, data FROM Events WHERE type IN ('write_error', 'recording_stop');
```

A player whose row in `Players` cannot be written (a locked or full database)
is retried the next time they are seen rather than struck off the recording,
so a moment of trouble does not cost every action they take afterwards. While
it lasts, their events carry no subject; what happened is written down in
`Metadata['recorder.player_errors']`, which is attempted immediately and again
after the next commit that goes through.

`write_error`, `recording_start` and `recording_stop` are always recorded, even
if `recorder.disabled_events` names them: a recording that cannot say where it
begins, where it ends and where its holes are cannot be read for what it is.

### Stopping

`recorder.stop()` returns a message rather than `nil` if the last rows could not
be written. The recording is stopped either way, but such a file has no
`recording_stop` event and its metadata does not claim a stop time – which is the
same shape as a recording the server never got to close, and means the same
thing: the end is missing.

If something else is still reading the recording when it stops, SQLite cannot
fold the write-ahead log back into the main file; the recorder says so in the log
rather than reporting a clean stop, and the `-wal` file has to travel with the
`.sqlite`.

## What is not recorded

- **Actions with no callback.** Using an item (rightclicking on air or on a node)
  has no global callback; hooking it would mean wrapping every item definition of
  every mod, so it is not done. Digging, placing, eating and crafting are covered
  because they do have one.
- **Entities.** Mobs, item drops and projectiles are not recorded; the recording
  follows players and the region's nodes, not other objects.
- **Node timers and their state.** Node metadata and inventories are recorded
  (see *Node metadata*), and the lighting (see *Lighting*), but a node timer's
  state is engine state, not metadata, and is not. A timer's effect on the
  world is still recorded as the `node_change` it produces.
- **Formspec and GUI input**, and anything else a mod does without a callback.
- **Login and IP data.** `ipdb` is the place for who connected from where.

## Performance

Recording is deliberately out of the way of the server loop: a callback only
appends a row to a buffer, and a globalstep commits the whole batch in one
transaction every `recorder.flush_interval` seconds. The number of rows is
whatever the players do – at 20 players moving continuously, a few hundred rows a
second, a few MB per hour, and nothing at all while they stand still.

Reading a player costs more than comparing them: the wielded stack has to be
pulled out of the engine and turned into an itemstring once per player per step,
because nothing tells a mod that the held item changed, and the animation is
polled the same way. It is one stack copy, one string and one `get_animation()`
per player per step, which is small next to what the engine does with those
players anyway – but it is why the sampling is not free for a player who is
standing still. An animation the engine reports as its own default (frames
1..1 at 15 fps) is not a pose the game chose and is not recorded.

Particle calls are the one source that can add rows quickly: an effect emitted
every step writes one `particle` row per step (twenty a second at the default
step rate) for as long as it runs. A spawner is one row however many particles
it emits, and its delete is one more. `recorder.particles = false`, or
`recorder.disabled_events = particle`, keeps a busy server's recordings small.

## Tests

`tests/run_tests.sh` runs the mod against a real SQLite file with a mocked engine:
the schema, the ordering and NULL guarantees, dropped batches, the API contract,
what each callback records, the settings and the failure path. It needs a Lua
interpreter (luajit preferred) with `lsqlite3`:

```sh
cd recorder/recorder_capture/tests && ./run_tests.sh
```

## License

GPL-3.0-or-later, see the SPDX headers in the source files.
