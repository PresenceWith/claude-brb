#!/bin/bash
# test-settings-json.sh
set -euo pipefail
PASS=0 FAIL=0
assert() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

TMPDIR=$(mktemp -d)
SETTINGS="$TMPDIR/settings.json"

# Source just the utility functions (will need to extract or source whole script)
source_dir="$(cd "$(dirname "$0")" && pwd)"
export _SETTINGS_PATH="$SETTINGS"
export CLAUDE_BRB_STORE="$TMPDIR"

# Test add to nonexistent file
"$source_dir/claude-brb.sh" _test-settings-add "/usr/local/bin/claude-brb _hook-auto-resume"
assert "creates settings.json" "[ -f '$SETTINGS' ]"
assert "contains hook command" "grep -q '_hook-auto-resume' '$SETTINGS'"

# Test idempotency
"$source_dir/claude-brb.sh" _test-settings-add "/usr/local/bin/claude-brb _hook-auto-resume"
count=$(grep -c '_hook-auto-resume' "$SETTINGS")
assert "idempotent (count=1)" "[ '$count' -eq 1 ]"

# Test remove
"$source_dir/claude-brb.sh" _test-settings-remove
assert "hook removed" "! grep -q '_hook-auto-resume' '$SETTINGS'"

rm -rf "$TMPDIR"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
