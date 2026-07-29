#!/usr/bin/env bash
# WP67's RED anatomy was consumed by WP68. At the current tree the durable
# control is the successor: decoder/internal suites GREEN, schema rows still
# RED-under-control for WP81, and socket parity GREEN. Keeping this named entry
# means a freeze that runs every historical check cannot accidentally execute
# stale expectations from the pre-implementation commit.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "WP67 control: RED corpus consumed; delegating to the WP68 state transition"
exec bash "$DRUSE_ROOT/build/check_wp68_controls.sh"
