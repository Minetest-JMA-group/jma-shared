#!/bin/sh
# Run every test suite in the recorder modpack.
set -e
cd "$(dirname "$0")"

for suite in recorder_common recorder_capture; do
	echo "######## $suite ########"
	"$suite/tests/run_tests.sh"
done
