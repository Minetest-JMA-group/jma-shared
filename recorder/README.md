# recorder – record what happens on the server, in order, into SQLite

recorder writes down what players do and where they are: every action that Luanti
offers a callback for (digging, placing, punching, talking, crafting, dying, ...)
and one sample per player per server step of the kinematic state that goes with it
(position, orientation, velocity, derived acceleration, pressed keys). All of it
lands in a single SQLite file per recording, in the order in which it happened, so
the recording can later be replayed, analysed, or just read with the `sqlite3`
shell.

## Features

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

1. Place the mod folder in your `mods/` directory.
2. Ensure `lsqlite3` is available (e.g. `luarocks install lsqlite3`).
3. Add `"recorder"` to `secure.trusted_mods` in `minetest.conf`.
4. Create `world/recordings/` if you want it somewhere the mod cannot create
   itself (it creates the directory if it can).

## API

The mod exposes a global `recorder` table. `start`, `stop` and `add_meta` return
`nil` on success and a string describing the failure otherwise.

```lua
local err = recorder.start("ctf-match")     -- nil, or a message
if err then core.log("error", err) end

recorder.add_meta("ctf:map", "forge")       -- only while a recording is in progress
recorder.add_meta("ctf:teams", "red:blue")

-- Another mod can put its own happenings into the same timeline
recorder.log_event("ctf:capture", {
	subject = player,                       -- ObjectRef or player name
	item = "ctf:flag_red",
	pos = { x = 1, y = 2, z = 3 },
	data = { team = "red", score = 3 },
})

recorder.stop()                             -- nil, or a message
```

| Function | Behaviour |
| --- | --- |
| `recorder.start([name])` | Starts a recording. Fails if one is already running. `name` is used to build the file name and defaults to `"unnamed"`. |
| `recorder.stop([reason])` | Stops the recording in progress. Fails if there is none, or if its last rows could not be written (see *Stopping* below). `reason` is stored in the recording; the automatic stops use their own. |
| `recorder.add_meta(key, value)` | Stores a string pair about the recording. Works only while recording. Keys starting with `recorder.` describe the recording itself and are refused. |
| `recorder.log_event(type, fields)` | Records an event of a mod's own making. Works only while recording. Use a `modname:what` type to stay clear of the types below. |
| `recorder.is_recording()` | `true` while a recording is in progress. |
| `recorder.get_recording_name()` / `get_recording_path()` | The name and the file of the recording in progress, or `nil`. |

## Chat commands

`/recorder` needs the `server` privilege.

- `/recorder` or `/recorder status` – what is being recorded, for how long, how
  much has been written, how much was lost, and how big the file is.
- `/recorder start [name]` – start recording.
- `/recorder stop` – stop recording.
- `/recorder meta <key> <value>` – attach a pair to the current recording.

## Settings

Settings are read when a recording starts, so a change applies to the next one.

| Setting | Default | Meaning |
| --- | --- | --- |
| `recorder.directory` | empty | Where recordings are written. Empty means `world/recordings/`. |
| `recorder.flush_interval` | `2.0` | Seconds of server time between commits. |
| `recorder.max_buffered` | `20000` | Rows buffered before a commit is forced early. `0` leaves the timing to `flush_interval` alone. |
| `recorder.max_duration` | `0` | Stop the recording after this many seconds. `0` is no limit. |
| `recorder.max_size_mb` | `0` | Stop the recording once the file reaches this size. `0` is no limit. |
| `recorder.disabled_events` | empty | Comma-separated event types not to record, e.g. `chat, chatcommand, punch_node`. The recording's own markers (`recording_start`, `recording_stop`, `write_error`) cannot be disabled. |

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
| `Metadata` | `key`, `value` – what `recorder.add_meta` writes, plus the `recorder.*` keys describing the recording (name, start and stop times, engine version, game, tick count, why it ended, and any player whose row could not be written). |
| `Players` | `id`, `name` – one row per player seen during the recording. |
| `Movement` | Player kinematics, one row per player per server step in which something about that player changed. |
| `Events` | One row per action. |

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
| `join` | player | – | `pos`, `item` (wielded) | `at_start`, `last_login`, `hp`, `breath`, `pitch`, `yaw`, `inventory` |
| `leave` | player | – | – | `timed_out` |
| `die` | player | – | `pos` | `reason` |
| `respawn` | player | – | `pos` (before being moved) | – |
| `hp_change` | player | – | `pos` | `amount`, `reason` |
| `wield` | player | – | `item` | – |
| `punch_player` | hitter | punched player | `pos` (of the punched) | `damage`, `dir`, `time_from_last_punch`, `tool`, `actor` |
| `punch_node` | puncher | – | `pos`, `node`, `param2`, `item` | `actor` |
| `dig` | digger | – | `pos`, `node` (dug), `param2`, `item` (tool) | `actor` |
| `place` | placer | – | `pos`, `node` (placed), `param2`, `item` (stack) | `old_node`, `old_param2`, `actor` |
| `rightclick_player` | clicker | clicked player | `pos` (of the clicked), `item` | `actor` |
| `craft` | player | – | `item` (output) | `grid` |
| `item_eat` | player | – | `item` | `hp_change`, `replace_with`, `actor` |
| `item_pickup` | picker | – | `item` | `actor` |
| `inventory_move`, `inventory_put`, `inventory_take` | player | – | `item` | `from_list`, `to_list`, `from_index`, `to_index`, `listname`, `index`, `count` |
| `chat` | player | – | `pos` | `message` |
| `chatcommand` | player | – | `pos` | `command`, `params` |
| `protection_violation` | player | – | `pos` | – |
| `cheat` | player | – | `pos` | `cheat` |

`reason` is a `PlayerHPChangeReason` with its ObjectRef replaced by the name of the
player it points at: `type`, `custom_type`, `from`, `object`, `node`, `node_pos`.
`grid` is the crafting grid as itemstrings, slot for slot. `inventory` is every
list of the player's inventory at that moment, as itemstrings, slot for slot, with
an empty string for an empty slot. `item` on an inventory action is the stack the
action moved – for a `move` within one inventory, which does not say what it
moved, it is what the move left in the destination slot, with `count` telling how
much of it moved.

### How a recording opens and closes

A recording opens with a `recording_start` event, followed by a `join` event for
everyone who was online at that moment (with `data.at_start`), and closes with a
`recording_stop` event carrying `data.reason`. The `at_start` joins are written
at the first server step after `start()`, because a mod may start a recording
while it is still loading and the engine answers no questions about the world
before the server is running; a player who joins in that same moment is joined
once, not twice.

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
- **World changes that no player caused**, unless they come through the callbacks
  above: TNT explosions (which remove nodes without digging them), liquid flow,
  ABMs, node timers, and any `set_node` a mod does on its own. The recording is a
  record of what players did, not a full world diff.
- **Node inventories.** Chests and other node metadata inventories can only be
  watched per node definition, not globally. Player inventories are covered
  (`inventory_*` events, plus the snapshot in `join`).
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
because nothing tells a mod that the held item changed. It is one stack copy and
one string per player per step, which is small next to what the engine does with
those players anyway – but it is why the sampling is not free for a player who
is standing still.

## Tests

`tests/run_tests.sh` runs the mod against a real SQLite file with a mocked engine:
the schema, the ordering and NULL guarantees, dropped batches, the API contract,
what each callback records, the settings and the failure path. It needs a Lua
interpreter (luajit preferred) with `lsqlite3`:

```sh
cd recorder/tests && ./run_tests.sh
```

## License

GPL-3.0-or-later, see the SPDX headers in the source files.
