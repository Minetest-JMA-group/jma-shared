# recorder – record what happens on a server, and play it back

`recorder` is a modpack of three mods:

- **`recorder_capture`** writes a recording: one SQLite file per recording,
  holding the world inside a region, the players who were in it, their actions
  and their movement, tick by tick and in order.
- **`recorder_replay`** plays a recording back inside an arena it builds: the
  recorded region is reconstructed from the recording's snapshot, node changes,
  light and node metadata, the recorded players appear as ghosts, and the
  watchers stand on the arena's top face with a remote control for the clock
  and the lighting.
- **`recorder_common`** holds what the two halves have to agree on: the file's
  identity and paths, the region arithmetic, and the snapshot format.

A recording is self-contained: it carries the world it started from, by node
name, so replaying it needs the recording, not the game's map files.

## Requirements

- `lsqlite3`, installed, with `recorder_capture` and `recorder_replay` added to
  `secure.trusted_mods` or `secure.c_mods`.
- `algorithms`, for loading the library.
- A player model for the ghosts: `recorder_replay` reads the model registry of
  `player_api` or `mcl_player`, and falls back to a sprite without either. The
  held item attaches to that model's hand bone; a sprite has none.

## Tests

```sh
./run-tests.sh
```

runs all three suites; each mod also has its own `tests/run_tests.sh`. The
suites drive the real mod code against a mocked engine and a real SQLite file.

## World settings

All capture, replay, and retention settings use the same precedence:

1. A persistent override in this world's `recorder_common` mod storage.
2. A default from `minetest.conf`, cached when `recorder_common` loads.
3. The built-in default listed in the capture/replay documentation.

The effective settings are kept in memory. The recorder does not read
`core.settings` after loading; `/set` changes do not affect it during that run.
Restart to pick up edited configuration defaults. An existing world override
continues to take precedence until reset.

The following commands require the `server` privilege:

```text
/recorder_settings
/recorder_settings recorder.max_size_mb 500
/recorder_settings replay.chat false
/recorder_settings reset recorder.max_size_mb
```

With no arguments, the command lists effective values, their sources, and when
changes take effect. A key alone reads it; a key and value saves an override;
`reset <key>` removes the override and restores the default cached at startup.
Use `""` as a value to save an explicit empty string (for example, to restore
automatic model selection despite a configured model default).

`/recorder settings ...` is an alias with `recorder.` as the default key prefix;
`/replay settings ...` defaults to `replay.`. Full keys work through every alias.
The standalone command also works when only the shared mod is enabled.

Capture options are copied into each new recording. Replay appearance and chat
options are copied into each new session, including ghosts created later by a
seek or recorded join. Running recordings and replays keep those options.
Concurrency limits apply to subsequent start attempts. Directory changes apply
to subsequent directory lookups; existing captures and replays keep their paths.
`replay.allow_unfinished` applies to subsequent lists and replay start attempts.

## Recording retention

Retention is disabled by default. Enable any combination of these settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `recorder.retention_count` | `0` | Maximum number of saved recordings. |
| `recorder.retention_size_mb` | `0` | Combined size budget in MiB, including SQLite `-wal` and `-shm` sidecars. |
| `recorder.retention_age` | `0` | Maximum age since recording start, in seconds or with an `s`, `m`, `h`, `d`, or `w` suffix. |

`0` disables an individual limit. For example:

```text
/recorder settings retention_age 7d
/recorder settings retention_size_mb 4096
/recorder settings retention_count 100
```

Cleanup runs at shared-mod load, after a recording stops, and every 60 seconds.
Changes take effect on the next cleanup. It deletes whole recordings, oldest
first by their UTC start timestamp, until all enabled limits are met. Recordings
currently being captured or watched are protected, but count toward the budget,
so limits can temporarily be exceeded. Once released, they become eligible on
the next cleanup. A single finished recording exceeding the size budget may be
deleted as soon as it stops.

Only the current recording directory is managed. A file must have the recorder's
SQLite application identity and its generated timestamped filename to qualify.
Renamed recordings without that filename format and unrelated files are left
alone. Sidecars are removed together with their recording; deletion failures are
logged. Automatic deletion does not ask for confirmation once a retention limit
has been enabled.
