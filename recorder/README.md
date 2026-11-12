# recorder – capture and replay regional gameplay

- **`recorder_capture`** saves regional world state, player actions and movement
  in one self-contained SQLite file per recording.
- **`recorder_replay`** reconstructs that region in an arena and displays players
  as ghosts visible only to viewers, with playback and lighting controls.
- **`recorder_common`** provides settings, retention, paths and file-format codecs.

See [capture](recorder_capture/README.md) for its API and file format, and
[replay](recorder_replay/README.md) for controls and game integration.

## Requirements

`algorithms` and `lsqlite3`; add the enabled capture/replay mods to
`secure.trusted_mods` or `secure.c_mods`. Ghost models use `player_api` or
`mcl_player`, falling back to sprites without either.

## World settings

Precedence: **world override → startup `minetest.conf` default → built-in default**.
Overrides persist in `recorder_common` mod storage. Defaults are cached at load;
editing configuration requires a restart, and `/set` has no runtime effect on
recorder settings. Overrides remain until reset.

Commands require `server` privilege:

```text
/recorder_settings [key [value] | reset key]
/recorder settings max_size_mb 500
/replay settings chat false
/recorder settings reset max_size_mb
```

No arguments lists effective values, sources and activation times; a key reads
one, a value saves an override, and `reset` restores its cached default. Use `""`
for an explicit empty value. Full `recorder.*`/`replay.*` keys work everywhere;
short keys default to `recorder.` except under `/replay settings`. The standalone
command also works with only `recorder_common` enabled.

| Setting group | Changes apply to |
| --- | --- |
| Capture options; replay appearance/chat | New recordings/sessions, including ghosts recreated later. Existing ones keep their options. |
| Concurrency limits | Subsequent start attempts. |
| `recorder.directory` | Subsequent directory lookups; active captures/replays keep their paths. |
| `replay.allow_unfinished` | Subsequent file lists and replay starts. |
| Retention limits | Next cleanup. |

## Recording retention

**Recordings are kept indefinitely by default.** Configure any combination of
limits to enable automatic deletion; all default to `0` (no limit).

| Setting | Meaning |
| --- | --- |
| `recorder.retention_count` | Maximum saved recordings. |
| `recorder.retention_size_mb` | Combined MiB budget, including SQLite `-wal`/`-shm` sidecars. |
| `recorder.retention_age` | Maximum age since recording start: seconds or an `s`, `m`, `h`, `d`, `w` suffix. |

For example, `/recorder settings retention_age 7d` and
`/recorder settings retention_size_mb 4096` keep up to seven days within 4 GiB.

Cleanup runs at shared-mod load, after recordings stop, and every 60 seconds.
It deletes whole recordings and sidecars, oldest UTC start first, until all
enabled limits fit. Captured/watched recordings count toward the budget but are
protected until released, so limits may temporarily be exceeded. A finished
recording larger than the budget can be deleted immediately on stopping.

Only the current recording directory is managed. Files need the recorder SQLite
identity and generated timestamped name; unrelated files and recordings renamed
outside that format are untouched. Deletion failures are logged.

## Tests

Run `./run-tests.sh` for all suites, or a mod's `tests/run_tests.sh`. Tests use a
mocked engine and real SQLite; LuaJIT with `lsqlite3` is preferred.
