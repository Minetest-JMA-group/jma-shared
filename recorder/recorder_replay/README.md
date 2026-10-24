# recorder_replay – play a recording back

recorder_replay is the playback half of the `recorder` modpack. It opens a
recording read-only, builds an arena, reconstructs the recorded region inside
it, and shows the recorded players as ghosts to the people watching. Only the
watchers receive the ghosts, and the recording is never written to.

**Status.** The arena and the reconstruction are real: a replay is watched
inside a rebuilt copy of the recording's region, not in the live world. The
recording still carries only what capture records (see *Limits* below).

## Watching

| Command | What it does |
| --- | --- |
| `/replay` | choose a recording from a list and watch it |
| `/replay list` | recordings on disk and replays running |
| `/replay join [id]` | join the running replay; a chooser when there are several |
| `/replay leave` | stop watching |
| `/replay end <id>` | end a replay, tear its arena down and restore everyone in it |
| `/replay status` | where the replay you are watching is |
| `/replay pos1` / `/replay pos2` | mark an arena corner where you stand |
| `/replay unset` | drop your arena marks |

The `replay` privilege is needed. Every formspec this mod handles checks that
privilege again when it is submitted: the engine only shows a formspec to the
player it was sent to, but a client can submit any form name it likes, so the
submission is trusted only because its sender is.

A bare `/replay` first checks that an arena source exists - your own marks, the
game's provider, or the `replay.arena` setting - and refuses with instructions
when there is none. Otherwise it lists every `.sqlite` file in the recording
directory, newest first; selecting one and pressing *Watch* (or double-clicking
it) starts the replay. The chosen recording's region is then checked against
the arena: too small a box, or one already in use, keeps the chooser open with
the reason shown in red. `/replay list` remains the plain-text listing.

A player with the `server` privilege also gets a **Delete** button in the
chooser. It asks for confirmation, removes the recording file and its
write-ahead sidecars, and refuses a recording that is being watched or is
still being recorded.

Every replay is watched in an arena. A player who starts one gets the arena
their marks describe; a game may provide one instead (see *For a game*), and a
server with neither falls back to the `replay.arena` setting. An arena must be
at least the recorded region plus one node on every side: the outer layer of
the box is an invisible, see-through barrier, and the recording is rebuilt one
node in from its low corner. Marked and provided arenas are refused if they
overlap an arena already in use or one another player is about to use.

While watching, the main inventory is replaced by the remote control, in the
hotbar:

| Item | What it does |
| --- | --- |
| pause | pause or resume |
| speed | cycle 1x, 2x, 4x, 0.5x |
| back / forward | move 10 seconds |
| seek | a window with a slider over the whole recording |
| lighting | switch between recorded conditions (recorded light and/or recorded day) and live ones |
| leave | stop watching |

A participant's position and main inventory are saved in their own metadata
when they start watching, and restored when they leave. A disconnect keeps the
save: if the session is still running when they come back they rejoin it, and
the same save waits for the leave that ends their stay; if it has ended in the
meantime, the save is restored on the join. A game whose world is not
persistent (CTF does this through
`recorder_common.game_hooks.world_persistent = false`) keeps that job for
itself: nothing is stashed, `before_enter` can save the player's position and
inventory before replay fills the hotbar, and `on_leave` puts them back. The
game also has to rejoin a participant to a running session itself through
`recorder_replay.sessions`: `find(id)` and `join(session, player, true)`.
`on_leave` runs only while the player is online; a disconnect is the game's
own `on_leaveplayer` business.

## The reconstruction

- Every recording carries a snapshot of its region, taken before the first
  recorded action. Replay reads it and resolves the node names against the
  running game; a node the game does not have becomes `CONTENT_UNKNOWN`.
- Node changes from the recording are applied on top of the snapshot as the
  clock passes them. Seeking rebuilds the region's state from the snapshot and
  every change up to that moment, and writes only the mapblocks whose contents
  actually differ - so seeking backwards undoes changes without touching the
  rest of the arena. Forward playback likewise writes only the mapblocks its
  crossed node and light changes touch, which is what keeps a replay of a large
  region from rewriting it on every step.
- The region is written through a VoxelManip without `update_liquids()`. That
  is what keeps liquids inert: a paused replay holds still, and a seek shows
  the recorded moment rather than a newly started flow.
- A recording made with `recorder.light` (capture's default; the setting can
  turn it off) carries the region's lighting, air included. The arena shows it
  by default: the light bytes are written into the blocks and the engine is
  told not to recalculate them, so a cave stays dark and a lamp-lit room keeps
  its glow. Changes are applied as the clock crosses them, and a seek rebuilds
  the layer for that moment. The lighting item switches to live lighting
  instead - the light the arena's own world would give those nodes,
  recalculated with `core.fix_light`, under the server's current time of day -
  and back to the recorded light and the recorded day. The switch is offered
  whenever the file has something recorded to switch: a light layer, a
  recorded time of day, or both. With only the time of day it changes just the
  day and leaves the light to the arena; with neither, no switch is shown.
- In live mode the shell still lets sunlight through (it is invisible, not a
  lid), and the arena is relit in full when it is built, cleared and whenever
  the clock jumps. The recorded mode does not recalculate anything.
- The recording also carries the time of day it was made at; capture writes it
  regardless of the light setting. In recorded mode each participant is given
  that day's sunlight for themselves with `override_day_night_ratio`, so a
  recording made in daylight does not turn dark because the replay server
  happens to be at night; in live mode the override is removed again and the
  server's own time applies. Whatever override the game had set is remembered
  and put back on leaving. The sky itself (sun, moon, stars) remains the
  server's. Recordings made before the time of day was stored play under the
  server's current day/night.
- Ending the replay - or the last participant leaving - fills the whole arena
  with air, removes the ghosts and restores the participants. The arena's
  bounds are written to mod storage before its first node, so if the server
  dies mid-replay the next boot clears the leftover shell (on a world the game
  rebuilds from scratch there is nothing to clear, and the flag is erased).
- Node metadata and inventories are restored with the nodes: a chest shows what
  it held, a sign shows its text. Changes are applied as the clock reaches
  them, and a seek rebuilds them from the baseline for that moment. VoxelManip
  writes do not touch metadata, so the arena's metadata is cleared explicitly
  before a reconstruction and when the arena is torn down - otherwise a live
  world's chest could leave its inventory behind on a replay node.

## What is played

- Players appear when the recording says they joined and disappear when it says
  they left, including walking in and out of the recorded region.
- Their motion is the recording's sparse samples: a sample is applied when the
  clock reaches it, and the client's entity interpolation smooths between them.
- A ghost holds the item its player held: the last `wield` event at or before
  the moment shown, or the item carried by the `join` event before the player
  first switched. An empty hand is a recorded empty item and shows as one. The
  item is a separate `wielditem` entity attached to the model's hand bone
  (`Arm_Right` for a `player_api` model, `Wield_Item` for an `mcl_player`
  model), so it follows the pose animations; `set_wielded_item` is
  player-only.
- The pose is the recording's when it has one: an `animation` event carries the
  engine's frame range, speed, blend and loop, so a game's own pose (lying down
  while dead, sitting) is shown exactly, and later movement samples do not
  overwrite it. Without an animation event - an older recording, or a game that
  never sets one - the pose follows the sample as before: walking, mining,
  standing, with the head following the recorded pitch either way.
- A ghost wears the game's player model and, when the recording carries them,
  the recorded textures.
- Particle effects are replayed inside the arena: a single particle at the
  moment the clock reaches it, and a spawner as an engine spawner moved by the
  session's offset. A recorded player restriction is dropped, so every watcher
  sees an effect that was private on the recording server. A recorded delete
  cancels the spawner the session created. Seeking cancels every spawner the
  session made and re-creates the ones the recording had running at that
  moment, minus those whose own lifetime had ended; their timers restart,
  which is all a seek can do to an engine spawner. A one-off particle from
  before the seek is not replayed - it was over long before.
- Recorded global chat is shown to the participants as chat lines when the
  clock reaches each message, prefixed with `[replay]` so it is not mistaken
  for the replay server's own chat. The line is the final one the recording
  server delivered, prefixes and colours included. Like a one-off particle it
  is transient: a seek does not replay the backlog (`replay.chat` turns it
  off).

## Limits

- Chat and inventories are not drawn in the world. Recorded chat appears as
  chat lines to the participants, not as anything in the 3D scene.
- Particle effects attached to an object (a smoke trail following a projectile,
  an aura around a player) are not recorded, so they do not replay. A
  spawner's emission box is translated whole rather than clamped to the
  arena's walls; a box that reaches outside the arena may put particles
  outside it, where the shell hides them or the live world shows through.
- Lua entities are not recorded, so mobs, dropped items and the like do not
  appear.
- Node timers' state is not recorded or replayed; a node timer's `node_change`
  output is replayed because it changes a node.
- The sky (sun, moon, stars) is the server's, even though the arena's sunlight
  follows the recording's time of day; see *The reconstruction*.
- A recording made before the snapshot existed (or one missing it) cannot be
  rebuilt; replay refuses it with that reason.

## A recording that is still being made

By default a recording can only be watched when it is finished: the chooser
leaves out files capture is still writing, and a session refuses to start on
one. A file that is still taking its snapshot has nothing to rebuild from yet
in any case.

With `replay.allow_unfinished = true` the older behaviour returns. The file is
opened read-only, and WAL lets a reader see committed rows without blocking the
writer; the replay's length is whatever it was when it started, so it shows the
part recorded so far and stops. `/replay list` always shows every file,
including the one being written.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `replay.arena` | empty | The fallback arena, `x1,y1,z1,x2,y2,z2`. Used only when the game registers no arena provider; one fixed box can serve one replay at a time. |
| `replay.allow_unfinished` | `false` | Offer recordings that capture is still making, and let sessions start on them. Off by default: the chooser hides them and a session refuses one. |
| `replay.max_sessions` | `4` | How many replays may run at once; `0` is no limit. |
| `replay.model` | empty | The model name for ghost bodies, overriding the one picked from the game's registry. |
| `replay.chat` | `true` | Show the recording's `chat` lines to the participants as chat. Read when a session starts. |
| `replay.wield_item` | `true` | Draw the item a ghost holds. The `wield_*` rows give `player_api` / `mcl_player` defaults; they are read when the mod loads. |
| `replay.wield_bone` | `Arm_Right` / `Wield_Item` | The bone the held item attaches to. |
| `replay.wield_pos` | `0,5.5,3` / `0,0,0` | Where the item sits in that bone's space. |
| `replay.wield_rot` | `-90,225,90` / `0,0,0` | The item's rotation at the bone, in degrees. |
| `replay.wield_scale` | `0.3,0.3,0.25` / `0.21,0.21,0.21` | The item entity's visual size, so a node-sized item looks hand-sized. |
| `recorder.directory` | empty | Where recordings are read from, shared with capture. A relative path is taken from the world directory. |

## For a game

The pack never names a game. A game that wants to own part of the replay
registers hooks in `recorder_common`:

```lua
recorder_common.register_game_hooks({
	arena = function(size, taken)
		-- Return two corners of a box at least `size` nodes on every axis that
		-- does not overlap any box in `taken`; nil and a reason when there is
		-- no room. Several replays can run at once.
	end,
	world_persistent = false,          -- its world is rebuilt at boot; it owns inventories
	can_enter = function(player, session)
		-- No side effects: return false and a reason to refuse before a
		-- recording is opened or an arena is prepared; session is nil
		-- before a start and the session itself on a join.
	end,
	before_enter = function(player, session)
		-- Still where the game left them, with their own inventory: take the
		-- player out of a running match here (and save what they had, on a
		-- non-persistent world). Replay fills the hotbar and then teleports.
	end,
	on_enter = function(player, session) ... end,  -- after the move into the arena
	on_leave = function(player, session) ... end,  -- after replay's own restore
})
```

`can_enter` is the game's veto. It runs before anything expensive happens: at
the top of `start()`, before the recording is opened, and again when the
participant is joined (a start does both). It must be a pure predicate; a
failing hook is logged and refuses the player. `before_enter` runs later, once
the arena exists and just before the hotbar is replaced and the player is
teleported.

`before_enter` runs on every entry, including a reconnect into a running
session. On a first entry the player is still where the game left them, with
their own inventory; replay stashes what the hook leaves behind, and restores
that stash when they leave. On a reconnect the original stash is kept, so the
game should rely on its own match state rather than on the player's position
or inventory. `on_enter` runs after the teleport into the arena; `on_leave`
after replay has put the participant back, so the game's hook has the last
word. A hook that raises is logged and does not abort the replay.

A registered `arena` provider is the only arena source consulted when the
starting player has no marks of their own; `replay.arena` is not used next to
it. A game can also mark arenas on a player's behalf through
`recorder_replay.arena`, and end a session it knows about with
`recorder_replay.end_session(id, reason)`.
