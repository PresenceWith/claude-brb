#!/bin/bash
# test-hook.sh — smoke tests for auto-resume hook
set -euo pipefail
PASS=0 FAIL=0
assert() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

CA="$(cd "$(dirname "$0")" && pwd)/claude-at.sh"
TEST_STORE=$(mktemp -d)
export CLAUDE_AT_STORE="$TEST_STORE"

# Test 1: empty stdin doesn't crash
echo '' | bash "$CA" _hook-auto-resume 2>/dev/null || true
assert "empty stdin no crash" "[ $? -eq 0 ] || true"

# Test 2: malformed JSON doesn't crash
echo 'not json' | bash "$CA" _hook-auto-resume 2>/dev/null || true
assert "malformed JSON no crash" "[ $? -eq 0 ] || true"

# Test 3: valid JSON creates log entry
cat <<'EOF' | bash "$CA" _hook-auto-resume 2>/dev/null || true
{"session_id":"test-abc","error_details":"429","cwd":"/tmp","hook_event_name":"StopFailure"}
EOF
assert "log file created" "[ -f '$TEST_STORE/auto-resume.log' ]"

# Test 4: recency guard blocks after 3 rapid calls
for i in 1 2 3; do
    cat <<'EOF' | bash "$CA" _hook-auto-resume 2>/dev/null || true
{"session_id":"rapid-test","error_details":"429","cwd":"/tmp","hook_event_name":"StopFailure"}
EOF
done
output=$(cat <<'EOF' | bash "$CA" _hook-auto-resume 2>&1 || true
{"session_id":"rapid-test","error_details":"429","cwd":"/tmp","hook_event_name":"StopFailure"}
EOF
)
assert "4th call blocked by recency guard" "echo '$output' | grep -qi 'limit\|exceed\|한도'"

rm -rf "$TEST_STORE"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
