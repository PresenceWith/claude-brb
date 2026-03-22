#!/bin/bash
# test-v2.sh — comprehensive v2 smoke tests
set -euo pipefail
PASS=0 FAIL=0
assert() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

CA="$(cd "$(dirname "$0")" && pwd)/claude-brb.sh"
TEST_STORE=$(mktemp -d)
export CLAUDE_BRB_STORE="$TEST_STORE"

# --- Version ---
output=$(bash "$CA" version 2>&1)
assert "ca version shows version" "echo '$output' | grep -q '0.2.0'"

output=$(bash "$CA" --version 2>&1)
assert "ca --version compat" "echo '$output' | grep -q '0.2.0'"

# --- Help ---
output=$(bash "$CA" help 2>&1)
assert "ca help shows usage" "echo '$output' | grep -q 'brb at'"

output=$(bash "$CA" --help 2>&1)
assert "ca --help compat" "echo '$output' | grep -q 'brb at'"

# --- Status summary (no args) ---
output=$(bash "$CA" 2>&1)
assert "ca (no args) shows status" "echo '$output' | grep -q 'auto-resume'"

# --- auto-resume ---
# Need _SETTINGS_PATH for testing
export _SETTINGS_PATH="$TEST_STORE/test-settings.json"

output=$(bash "$CA" auto-resume status 2>&1)
assert "auto-resume status (disabled)" "echo '$output' | grep -qi 'disabled\|비활성'"

output=$(bash "$CA" auto-resume enable 2>&1)
assert "auto-resume enable" "echo '$output' | grep -qi 'enabled\|활성화'"

output=$(bash "$CA" auto-resume status 2>&1)
assert "auto-resume status (enabled)" "echo '$output' | grep -qi 'enabled\|활성'"

output=$(bash "$CA" auto-resume disable 2>&1)
assert "auto-resume disable" "echo '$output' | grep -qi 'disabled\|비활성화'"

# --- Invalid command ---
output=$(bash "$CA" foobar 2>&1 || true)
assert "invalid command error" "echo '$output' | grep -qi 'unknown\|알 수 없는'"

# --- Hook smoke tests ---
echo '' | bash "$CA" _hook-auto-resume 2>/dev/null || true
assert "hook: empty stdin no crash" "true"

echo 'not json' | bash "$CA" _hook-auto-resume 2>/dev/null || true
assert "hook: malformed JSON no crash" "true"

cat <<'EOF' | bash "$CA" _hook-auto-resume 2>/dev/null || true
{"session_id":"test-abc","error_details":"429","cwd":"/tmp","hook_event_name":"StopFailure"}
EOF
assert "hook: log file created" "[ -f '$TEST_STORE/auto-resume.log' ]"

# --- Cleanup ---
rm -rf "$TEST_STORE"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
