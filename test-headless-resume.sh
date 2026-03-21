#!/bin/bash
# test-headless-resume.sh — verify headless+resume is allowed
set -euo pipefail
PASS=0 FAIL=0
assert() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi; }

# Test: headless + resume should NOT produce error
output=$(bash claude-at.sh -H 03:00 test-session-id "continue" 2>&1 || true)
assert "headless+resume no longer blocked" "! echo '$output' | grep -q 'does not support session resume'"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
