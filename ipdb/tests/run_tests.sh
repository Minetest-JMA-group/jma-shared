#!/bin/sh
# Run the ipdb test suite. Requires a Lua interpreter (luajit preferred, as
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

tmpdir="${TMPDIR:-/tmp}/ipdb_tests"
rm -rf "$tmpdir"
mkdir -p "$tmpdir"

run() {
	echo "=== $1 ==="
	shift
	"$LUA" "$@" || exit 1
}

run "test_main (fresh install, merge history, rollback)" test_main.lua
run "test_upgrade phase 1 (build a v4 database)" test_upgrade.lua build-v4
run "test_upgrade phase 2 (migrate it to v5)" test_upgrade.lua upgrade
run "test_cli (chat commands and merge_gui flow)" test_cli.lua
echo "ALL TESTS PASSED"
