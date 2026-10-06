#!/usr/bin/env bash
# Runs the unit tests. With only the Command Line Tools installed, the Swift
# Testing macro plugin lives outside the compiler's default plugin path.
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$PLUGINS" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  exec swift test "$@"
fi
