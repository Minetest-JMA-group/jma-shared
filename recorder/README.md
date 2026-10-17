# recorder – record what happens on a server, and play it back

`recorder` is a modpack of three mods:

- **`recorder_capture`** writes a recording: one SQLite file per recording,
  holding the world inside a region, the players who were in it, their actions
  and their movement, tick by tick and in order.
- **`recorder_replay`** plays a recording back: the recorded players appear as
  ghosts to the people watching, with a remote control for the clock.
- **`recorder_common`** holds what the two halves have to agree on: the file's
  identity and paths, the region arithmetic, and the snapshot format.

A recording is self-contained: it carries the world it started from, by node
name, so replaying it needs the recording, not the game's map files.

## Requirements

- `lsqlite3`, installed, with `recorder_capture` and `recorder_replay` added to
  `secure.trusted_mods` or `secure.c_mods`.
- `algorithms`, for loading the library.
- A player model for the ghosts: `recorder_replay` reads the model registry of
  `player_api` or `mcl_player`, and falls back to a sprite without either.

## Tests

```sh
./run-tests.sh
```

runs all three suites; each mod also has its own `tests/run_tests.sh`. The
suites drive the real mod code against a mocked engine and a real SQLite file.
