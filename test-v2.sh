#!/bin/bash
# test-v2.sh — comprehensive v2 smoke tests
set -euo pipefail
PASS=0 FAIL=0
assert() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

CA="$(cd "$(dirname "$0")" && pwd)/claude-brb.sh"
TEST_STORE=$(mktemp -d)
export CLAUDE_BRB_STORE="$TEST_STORE"
export CLAUDE_BRB_PLIST_DIR="$TEST_STORE/plist"
mkdir -p "$TEST_STORE/plist"

# Mock launchctl to prevent real launchd registration
MOCK_BIN="$TEST_STORE/bin"
mkdir -p "$MOCK_BIN"
printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/launchctl"
chmod +x "$MOCK_BIN/launchctl"
export PATH="$MOCK_BIN:$PATH"

# --- Version ---
output=$(bash "$CA" version 2>&1)
assert "ca version shows version" "echo '$output' | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'"

output=$(bash "$CA" --version 2>&1)
assert "ca --version compat" "echo '$output' | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'"

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

# --- SCHEDULING log line present ---
rm -f "$TEST_STORE"/auto-resume.log "$TEST_STORE"/.last-stop-*
echo '{"session_id":"log-test-abc","last_assistant_message":"resets 1am (Asia/Seoul)","hook_event_name":"StopFailure","error":"rate_limit","cwd":"/tmp"}' \
    | bash "$CA" _hook-auto-resume 2>/dev/null || true
assert "hook: SCHEDULING log line exists" "grep -q 'SCHEDULING:.*log-test-abc' '$TEST_STORE/auto-resume.log'"

# --- Reset time parsing from last_assistant_message ---
rm -f "$TEST_STORE"/auto-resume.log "$TEST_STORE"/.last-stop-*
echo '{"session_id":"time-parse-test","last_assistant_message":"You'\''ve hit your limit · resets 6am (Asia/Seoul)","hook_event_name":"StopFailure","error":"rate_limit","cwd":"/tmp"}' \
    | bash "$CA" _hook-auto-resume 2>/dev/null || true
sched_line=$(grep 'SCHEDULING:' "$TEST_STORE/auto-resume.log" 2>/dev/null | tail -1)
assert "hook: parses reset time from last_assistant_message (not +5h)" "echo '$sched_line' | grep -qv '+5h'"

# --- Idempotent scheduling at brb-at level ---
# First call creates the job
first_out=$(bash "$CA" at +3h -d /tmp "idempotent test prompt" 2>&1)
assert "at: first schedule succeeds" "echo '$first_out' | grep -qF 'Job ID:'"
# Second identical call (same dir + same time + same prompt) — must return "Already scheduled"
second_out=$(bash "$CA" at +3h -d /tmp "idempotent test prompt" 2>&1)
assert "at: idempotent dedup — identical job returns Already scheduled" "echo '$second_out' | grep -qF 'Already scheduled'"
# Different prompt for same time/dir — must create a new job
third_out=$(bash "$CA" at +3h -d /tmp "different prompt" 2>&1)
assert "at: different prompt is allowed" "echo '$third_out' | grep -qvF 'Already scheduled'"

# --- Auto-resume dedup: same session+prompt, different time → still deduped ---
ar_out1=$(_CLAUDE_BRB_SUBTYPE=auto-resume bash "$CA" at 14:00 -d /tmp "resume prompt" 2>&1)
assert "at: auto-resume first schedule" "echo '$ar_out1' | grep -qF 'Job ID:'"
# Simulate hook arriving 1 minute later (crossed minute boundary)
ar_out2=$(_CLAUDE_BRB_SUBTYPE=auto-resume bash "$CA" at 14:01 -d /tmp "resume prompt" 2>&1)
assert "at: auto-resume dedup skips time comparison" "echo '$ar_out2' | grep -qF 'Already scheduled'"

# --- Different session_id, same prompt+time → allowed ---
diff_sid_out=$(bash "$CA" at +3h -d /var/tmp "idempotent test prompt" 2>&1)
assert "at: different dir (no session) is allowed" "echo '$diff_sid_out' | grep -qvF 'Already scheduled'"

# --- Completed job (.sh removed) allows re-scheduling ---
# Remove all runner scripts to simulate all jobs completed
rm -f "$TEST_STORE"/*.sh
resch_out=$(bash "$CA" at +3h -d /tmp "idempotent test prompt" 2>&1)
assert "at: re-schedule after job completion (.sh removed)" "echo '$resch_out' | grep -qvF 'Already scheduled'"

# --- bypass-permissions ---
bp_out=$(bash "$CA" bypass-permissions status 2>&1)
assert "bypass-permissions status (disabled)" "echo '$bp_out' | grep -qi 'disabled\|비활성'"

bp_out=$(bash "$CA" bypass-permissions enable 2>&1)
assert "bypass-permissions enable" "echo '$bp_out' | grep -qi 'enabled\|활성화'"
assert "bypass-permissions sentinel created" "[ -f '$TEST_STORE/.bypass-permissions' ]"

bp_out=$(bash "$CA" bypass-permissions status 2>&1)
assert "bypass-permissions status (enabled)" "echo '$bp_out' | grep -qi 'enabled\|활성'"

bp_out=$(bash "$CA" bypass-permissions disable 2>&1)
assert "bypass-permissions disable" "echo '$bp_out' | grep -qi 'disabled\|비활성화'"
assert "bypass-permissions sentinel removed" "[ ! -f '$TEST_STORE/.bypass-permissions' ]"

# --- -B flag ---
bp_flag_out=$(bash "$CA" at +3h -B -d /tmp "bypass flag test" 2>&1)
assert "at -B: schedule succeeds" "echo '$bp_flag_out' | grep -qF 'Job ID:'"
# Check META_FLAGS contains --dangerously-skip-permissions
bp_jid=$(echo "$bp_flag_out" | grep -o 'Job ID: [^ )]*' | head -1 | sed 's/Job ID: //')
assert "at -B: META_FLAGS has dangerously-skip-permissions" "grep -q 'dangerously-skip-permissions' '$TEST_STORE/${bp_jid}.meta'"

# --- Cleanup ---
rm -rf "$TEST_STORE"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
