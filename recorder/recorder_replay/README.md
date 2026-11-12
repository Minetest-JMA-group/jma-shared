# recorder_replay – arena playback

Opens recordings read-only, reconstructs their regions inside arenas, and shows
recorded players as ghosts visible only to viewers. Playback coverage is limited
to [captured data](../recorder_capture/README.md#what-is-not-recorded).

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

Requires `replay` privilege, rechecked on formspec submissions. `/replay` checks
for an arena source, then offers `.sqlite` files newest first. Choose *Watch* or
double-click; invalid/occupied arenas leave the chooser open with an error.
`/replay list` is the text listing. With `server` privilege, **Delete** asks for
confirmation and removes the file/sidecars, refusing active captures/replays.

Arena precedence is **player marks → game provider → `replay.arena`**. A
registered provider excludes the setting fallback. Arenas need the recorded
region plus a one-node shell on all sides; reconstruction starts one node from
the low corner. The invisible, sunlight-transparent solid shell confines viewers
and provides a viewing platform. Marked/provided arenas cannot overlap active
arenas or another player's pending marks.

While watching, the main inventory is replaced by the remote control, in the
hotbar:

| Item | What it does |
| --- | --- |
| pause | pause or resume |
| speed | cycle 1x, 2x, 4x, 0.5x |
| back / forward | move 10 seconds |
| seek | a window with a slider over the whole recording |
| lighting | switch between recorded conditions (recorded light and/or recorded day) and live ones |
| chat | switch the recording's chat lines on or off |
| leave | stop watching |

Persistent worlds stash position/main inventory in player metadata and restore
them on leaving. Reconnects rejoin an existing session with the original stash,
or restore it if the session ended.

With `world_persistent = false`, the game owns inventory/return handling through
`before_enter`/`on_leave` and must rejoin reconnecting players itself using
`sessions.find(id)` and `sessions.join(session, player, true)`. `on_leave` runs
only for online players; disconnect handling belongs to the game's leave hook.

## The reconstruction

- Resolve snapshot node names against the current game; unknown nodes become
  `CONTENT_UNKNOWN`. Apply node/light changes as playback advances.
- Seeking rebuilds snapshot plus changes through the target time; forward play
  and seeks write only changed mapblocks. VoxelManip writes never call
  `update_liquids()`, so liquids remain inert during pause/seek.
- Restore node metadata/inventories from their tick-0 baseline and later changes.
  Explicitly clear arena metadata during reconstruction/teardown: VoxelManip
  does not clear it.
- Recorded lighting is the default when available. Write stored light without
  recalculation and apply changes/seeks to it. Recorded time of day is captured
  independently of light; `override_day_night_ratio` applies its sunlight per
  viewer, preserving/restoring the game's previous override on leave. The sky
  remains the server's.
- The lighting control switches to live light (`core.fix_light`) and server
  time, then back to recorded conditions. It appears with recorded light, time
  of day, or both; with only time of day it changes sunlight only, with neither
  it is absent. Older recordings without time of day use the server's day/night.
  Live mode fully relights on arena build/clear and clock jumps; recorded mode
  preserves stored values.
- Ending a replay or losing its last viewer clears the arena to air, removes
  ghosts and restores participants. Arena bounds are persisted before writing
  nodes so startup can clear crash leftovers. Non-persistent worlds discard the
  recovery flag because the game already rebuilds the world.

## What is played

- Players join/leave with recorded events, including region crossings. Sparse
  movement samples are applied at their timestamps; client interpolation smooths
  motion. Ghosts use the game's model and recorded textures when available.
- Held items use the latest `wield` since joining, otherwise the `join` item;
  empty items clear the hand. A separate `wielditem` entity attaches to
  `player_api`'s `Arm_Right` or `mcl_player`'s `Wield_Item` bone.
- Recorded animation frames, speed, blend and loop override movement-inferred
  standing/walking/mining poses. Without animation events, infer poses from
  samples. Recorded pitch controls the head in both cases.
- Translate particle definitions into arena coordinates. All viewers see effects
  regardless of original player restrictions. Deletes cancel matching replay
  spawners. Seeking recreates spawners active at the target time, excluding
  deleted/expired ones; their engine timers restart. Past one-off particles are
  not replayed.
- Show final recorded global chat to viewers with a `[replay]` prefix, preserving
  formatting. Seeking does not replay old messages. `replay.chat` sets the
  initial state; the chat control toggles it per session.

## Limits

- Player inventory events are not displayed; node inventories are reconstructed.
  Chat appears as chat lines, not in the 3D scene.
- Object-attached effects and Lua entities (mobs, drops, projectiles) are absent
  from capture. Spawner emission boxes are translated, not clamped to the arena,
  so particles can escape its bounds.
- Node timer state is absent; resulting node changes are replayed.
- The sky remains live even under recorded sunlight.
- Missing snapshots prevent replay; the file is refused.

## A recording that is still being made

By default the chooser hides active captures and replay refuses them.
`replay.allow_unfinished = true` permits read-only WAL access to committed rows,
without blocking capture. Duration is fixed at replay start: it shows only the
portion recorded then and stops. Snapshot-phase files cannot yet be reconstructed.
`/replay list` always includes files being written.

## Settings

See [World settings](../README.md#world-settings) for precedence, commands and
reset behavior. Appearance changes apply to new sessions.

| Setting | Default | Meaning |
| --- | --- | --- |
| `replay.arena` | empty | The fallback arena, `x1,y1,z1,x2,y2,z2`. Used only when the game registers no arena provider; one fixed box can serve one replay at a time. |
| `replay.allow_unfinished` | `false` | Allow viewing active captures; see unfinished-recording behavior above. |
| `replay.max_sessions` | `4` | How many replays may run at once; `0` is no limit. |
| `replay.model` | empty | The model name for ghost bodies, overriding the one picked from the game's registry. |
| `replay.chat` | `true` | Initial chat visibility for new sessions; toggled by the chat control. |
| `replay.wield_item` | `true` | Draw held items. `wield_*` defaults below are `player_api` / `mcl_player`; settings are copied per session. |
| `replay.wield_bone` | `Arm_Right` / `Wield_Item` | The bone the held item attaches to. |
| `replay.wield_pos` | `0,5.5,3` / `0,0,0` | Where the item sits in that bone's space. |
| `replay.wield_rot` | `-90,225,90` / `0,0,0` | The item's rotation at the bone, in degrees. |
| `replay.wield_scale` | `0.3,0.3,0.25` / `0.21,0.21,0.21` | Held-item visual scale. |
| `recorder.directory` | empty | Where recordings are read from, shared with capture. A relative path is taken from the world directory. |

## For a game

Register game-specific hooks through `recorder_common`:

```lua
recorder_common.register_game_hooks({
	arena = function(size, taken)
		-- Return pos1, pos2 fitting size and avoiding taken; or nil, reason.
	end,
	world_persistent = false,          -- its world is rebuilt at boot; it owns inventories
	can_enter = function(player, session)
		-- Pure predicate: false, reason refuses; nil/true allows.
		-- session is nil before start, or the target session on join.
	end,
	before_enter = function(player, session)
		-- Leave the match/save game state before replay changes the player.
	end,
	on_enter = function(player, session) ... end,  -- after the move into the arena
	on_leave = function(player, session) ... end,  -- after replay's own restore
})
```

`can_enter` is a pure predicate, checked once before opening a recording on
start, or before participant registration on join/reconnect. Return false and
a reason to refuse; errors are logged and refuse entry.

`before_enter` runs after arena preparation, before hotbar replacement/teleport,
on every entry including reconnects. On first entry, replay stashes what the hook
leaves behind; reconnects preserve the original stash, so game logic must use
its own match state. `on_enter` follows teleport; `on_leave` follows replay's
restore, letting the game set the final state. Other hook errors are logged
without aborting playback.

Player marks override the game provider; a registered provider overrides
`replay.arena` even when it cannot supply a box. Games can set marks through
`recorder_replay.arena`, access sessions through `recorder_replay.sessions`, and
end one with `recorder_replay.end_session(id, reason)`.
