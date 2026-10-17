# recorder_replay – play a recording back

recorder_replay is the playback half of the `recorder` modpack. It opens a
recording read-only and shows the recorded players as ghosts to the people
watching: only the watchers receive them, and the recording is never written to.

**Status.** This is the first phase: the ghosts move through the live world. The
recording's region snapshot is already in every file, but rebuilding it in an
arena is the next step; until then a replay is a quick look at who did what,
not a self-contained reconstruction.

## Watching

| Command | What it does |
| --- | --- |
| `/replay list` | recordings on disk and replays running |
| `/replay start <recording>` | start watching a recording, by name or `.sqlite` path |
| `/replay join [id]` | join the running replay; a chooser when there are several |
| `/replay leave` | stop watching |
| `/replay end <id>` | end a replay and restore everyone in it |
| `/replay status` | where the replay you are watching is |

The `replay` privilege is needed.

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

## What is played

- Players appear when the recording says they joined and disappear when it says
  they left, including walking in and out of the recorded region.
- Their motion is the recording's sparse samples: a sample is applied when the
  clock reaches it, and the client's entity interpolation smooths between them.
- The pose follows the sample - walking, mining, standing - and the head follows
  the recorded pitch.
- A ghost wears the game's player model and, when the recording carries them,
  the recorded textures.

This phase does not draw chat, items or world changes; the world's changes are
already in the file and are applied when the region is reconstructed.

## A recording that is still being made

The file is opened read-only, and WAL lets a reader see committed rows, so a
live recording can be watched too. Its length is whatever it was when the replay
started; rows that land later are not followed.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `replay.max_sessions` | `4` | How many replays may run at once; `0` is no limit. |
| `replay.model` | empty | The model name for ghost bodies, overriding the one picked from the game's registry. |
| `recorder.directory` | empty | Where recordings are read from, shared with capture. A relative path is taken from the world directory. |

## For a game

The pack never names a game. A game that wants to own part of the replay
registers hooks in `recorder_common`:

```lua
recorder_common.register_game_hooks({
	world_persistent = false,          -- its world is rebuilt at boot; it owns inventories
	on_enter = function(player, session) ... end,
	on_leave = function(player, session) ... end,
})
```

`recorder_replay.end_session(id, reason)` ends a session the game knows about.
