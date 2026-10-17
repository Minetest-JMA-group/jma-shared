#!/bin/sh
# Run the recorder_common test suite. Requires a Lua interpreter (luajit
# preferred, as Luanti uses it) with lsqlite3 installed, and a POSIX shell.
cd "$(dirname "$0")"

LUA=""
for c in luajit lua5.4 lua5.3 lua; do
	if command -v "$c" >/dev/null 2>&1; then LUA="$c"; break; fi
done
if [ -z "$LUA" ]; then
	echo "no Lua interpreter found (need luajit or lua with lsqlite3)"
	exit 1
fi

tmpdir="${TMPDIR:-/tmp}/recorder_common_tests"
rm -rf "$tmpdir"
mkdir -p "$tmpdir"

run() {
	echo "=== $1 ==="
	shift
	"$LUA" "$@" || exit 1
}

run "test_snapshot (the snapshot body codec)" test_snapshot.lua
run "test_region (the region arithmetic)" test_region.lua
run "test_common (paths, names, game hooks, read-only access)" test_common.lua
echo "ALL TESTS PASSED"
