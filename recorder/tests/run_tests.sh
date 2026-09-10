#!/bin/sh
# Run the recorder test suite. Requires a Lua interpreter (luajit preferred, as
# Luanti uses it) with lsqlite3 installed, and a POSIX shell.
cd "$(dirname "$0")"

LUA=""
for c in luajit lua5.4 lua5.3 lua; do
	if command -v "$c" >/dev/null 2>&1; then LUA="$c"; break; fi
done
if [ -z "$LUA" ]; then
	echo "no Lua interpreter found (need luajit or lua with lsqlite3)"
	exit 1
fi

tmpdir="${TMPDIR:-/tmp}/recorder_tests"
rm -rf "$tmpdir"
mkdir -p "$tmpdir"

run() {
	echo "=== $1 ==="
	shift
	"$LUA" "$@" || exit 1
}

run "test_dbmanager (schema, ordering, dropped batches, closing)" test_dbmanager.lua
run "test_recorder (API, recorded events, settings, failure)" test_recorder.lua
echo "ALL TESTS PASSED"
