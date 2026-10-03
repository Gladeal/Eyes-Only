#!/bin/bash
# Run the tests. With Xcode installed, plain `swift test` works too; with only the Command Line Tools,
# the Swift Testing framework is there but SwiftPM doesn't look for it, so this points it there.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  F="$DEV/Library/Developer/Frameworks"; L="$DEV/Library/Developer/usr/lib"
  exec swift test --scratch-path .build/test -Xswiftc -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test --scratch-path .build/test "$@"
