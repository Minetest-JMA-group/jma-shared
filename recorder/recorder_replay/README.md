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
| leave | stop watching |

A participant's position and main inventory are saved in their own metadata
when they start watching, and restored when they leave. A disconnect keeps the
save, so coming back returns them to the replay while it is still running and
restores them otherwise. A game whose world is not persistent (CTF does this
through `recorder_common.game_hooks.world_persistent = false`) keeps that job
for itself: the game's `on_enter`/`on_leave` hooks put the player back.

## The reconstruction

- Every recording carries a snapshot of its region, taken before the first
  recorded action. Replay reads it and resolves the node names against the
  running game; a node the game does not have becomes `CONTENT_UNKNOWN`.
- Node changes from the recording are applied on top of the snapshot as the
  clock passes them. Seeking rebuilds the region from the snapshot and every
  change up to that moment and writes it once, so seeking backwards undoes
  changes.
- The region is written through a VoxelManip without `update_liquids()`. That
  is what keeps liquids inert: a paused replay holds still, and a seek shows
  the recorded moment rather than a newly started flow.
- The shell lets sunlight through: it is invisible, not a lid. The arena's
  light is recalculated in full when it is built, when it is cleared and
  whenever the clock jumps; node changes during forward playback rely on the
  light the engine recalculates as the changed blocks are written.
- Ending the replay - or the last participant leaving - fills the whole arena
  with air, removes the ghosts and restores the participants. The arena's
  bounds are written to mod storage before its first node, so if the server
  dies mid-replay the next boot clears the leftover shell (on a world the game
  rebuilds from scratch there is nothing to clear, and the flag is erased).

## What is played

- Players appear when the recording says they joined and disappear when it says
  they left, including walking in and out of the recorded region.
- Their motion is the recording's sparse samples: a sample is applied when the
  clock reaches it, and the client's entity interpolation smooths between them.
- The pose follows the sample - walking, mining, standing - and the head follows
  the recorded pitch.
- A ghost wears the game's player model and, when the recording carries them,
  the recorded textures.

## Limits

- Chat, items and inventories are not drawn.
- Lua entities are not recorded, so mobs, dropped items and the like do not
  appear.
- Node metadata and node timers' state are not recorded or replayed; a node
  timer's `node_change` output is replayed because it changes a node.
- Light values are not recorded. A reconstruction is lit by the replay
  server's sky and by the nodes themselves, not by the light the recorded
  world had: a cave, a lamp-lit room or a night-time scene will look
  different.
- A recording made before the snapshot existed (or one missing it) cannot be
  rebuilt; replay refuses it with that reason.

## A recording that is still being made

The file is opened read-only, and WAL lets a reader see committed rows, so a
live recording can be watched too. Its length is whatever it was when the replay
started, and only the rows it had then are followed.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `replay.arena` | empty | The fallback arena, `x1,y1,z1,x2,y2,z2`. Used only when the game registers no arena provider; one fixed box can serve one replay at a time. |
| `replay.max_sessions` | `4` | How many replays may run at once; `0` is no limit. |
| `replay.model` | empty | The model name for ghost bodies, overriding the one picked from the game's registry. |
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
	on_enter = function(player, session) ... end,
	on_leave = function(player, session) ... end,
})
```

A registered `arena` provider is the only arena source consulted when the
starting player has no marks of their own; `replay.arena` is not used next to
it. A game can also mark arenas on a player's behalf through
`recorder_replay.arena`, and end a session it knows about with
`recorder_replay.end_session(id, reason)`.
