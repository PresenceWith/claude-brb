#!/bin/bash
# claude-brb — be right back with Claude Code
set -euo pipefail
umask 077

VERSION="0.3.4"

# --- i18n: detect locale once, cache result ---
_lang_code="${CLAUDE_BRB_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
[[ "$_lang_code" == ko* ]] && _LANG_KO=1 || _LANG_KO=0
_t() { if [ "$_LANG_KO" -eq 1 ]; then echo "$2"; else echo "$1"; fi; }
_err() { echo "$@" >&2; }

# --- headless mode messages ---
_MSG_QUIET_REQUIRES_HEADLESS() { _t "-q/--quiet requires -H/--headless" "-q/--quiet는 -H/--headless와 함께 사용해야 합니다"; }
_MSG_HEADLESS_PERM_WARN() {
    if [ "$_LANG_KO" -eq 1 ]; then
        cat <<'MSG'
⚠ 헤드리스 모드는 터미널 없이 실행됩니다. Claude가 대화형으로
  권한을 요청할 수 없습니다. --dangerously-skip-permissions 없이는
  작업이 승인 대기 중 멈출 수 있습니다.
MSG
    else
        cat <<'MSG'
⚠ Headless mode runs without a terminal. Claude cannot ask for
  permission interactively. Without --dangerously-skip-permissions,
  the job may hang waiting for approval.
MSG
    fi
}

# --- macOS only ---
[[ "$(uname)" == "Darwin" ]] || { _err "$(_t "Error: macOS only" "Error: macOS 전용입니다")"; exit 1; }

# --- configuration ---
# Regex for safe path characters (used in validation functions)
_SAFE_PATH_RE='^[a-zA-Z0-9/_. -]+$'
STORE="${CLAUDE_BRB_STORE:-$HOME/.claude-brb}"
# Validate store path characters (prevent injection into generated scripts/plist)
if [[ ! "$STORE" =~ $_SAFE_PATH_RE ]]; then
    _err "$(_t "Error: CLAUDE_BRB_STORE contains unsupported characters" "Error: CLAUDE_BRB_STORE에 지원되지 않는 문자 포함"): $STORE"
    exit 1
fi
PLIST_DIR="${CLAUDE_BRB_PLIST_DIR:-$HOME/Library/LaunchAgents}"
LABEL_PREFIX="com.claude-brb"
CLAUDE_BRB_TERMINAL="${CLAUDE_BRB_TERMINAL:-Terminal}"
CLAUDE_BRB_FLAGS="${CLAUDE_BRB_FLAGS:-}"
CLAUDE_BRB_MIN_INTERVAL="${CLAUDE_BRB_MIN_INTERVAL:-120}"
if ! [[ "$CLAUDE_BRB_MIN_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    CLAUDE_BRB_MIN_INTERVAL=120
fi

# --- validate terminal (prevent AppleScript injection) ---
case "$CLAUDE_BRB_TERMINAL" in
    Terminal|iTerm|iTerm2) ;;
    *) _err "$(_t "Error: unsupported terminal" "Error: 지원하지 않는 터미널"): $CLAUDE_BRB_TERMINAL (Terminal, iTerm, iTerm2)"; exit 1 ;;
esac

show_help() {
    if [ "$_LANG_KO" -eq 1 ]; then
        cat <<'HELP'
claude-brb, brb — Claude Code 세션 스케줄러

Usage:
  # 핵심 기능
  brb auto-resume enable           자동 재개 활성화
  brb auto-resume disable          비활성화
  brb auto-resume status           상태 + 최근 이력

  brb keep-alive enable [times]    5시간 리셋 활성화
  brb keep-alive disable           비활성화
  brb keep-alive status            상태

  # 일회성 예약
  brb at <time> "prompt"                    현재 디렉터리에서 새 세션
  brb at <time> -d <dir> "prompt"           지정 디렉터리
  brb at <time> -s <session-id> "prompt"    세션 재개
  brb at <time> -H "prompt"                 헤드리스 모드
  brb at <time> -H -q "prompt"              헤드리스 (출력 폐기)

  # 반복 예약
  brb every <schedule> <time> "prompt"
  brb every <schedule> <time> -d <dir> "prompt"
  brb every <schedule> <time> -H -q "prompt"

  # 관리
  brb list                         예약 목록 (인덱스 번호 포함)
  brb show <id|#index>             작업 상세
  brb cancel <id|#index|all>       취소
  brb edit <id|#index> ["prompt"]  프롬프트 수정
  brb reschedule <id|#index> <time>  시간 변경

  # 설정
  brb setup                        초기 설정 (인터랙티브)
  brb teardown                     전체 정리 (언인스톨 전)
  brb upgrade                      기존 작업 업그레이드
  brb                              상태 요약

Time:
  HH:MM       절대 시간 (다음 도래)
  +Nm         N분 후
  +Nh         N시간 후
  +Nd         N일 후
  HH:MM,HH:MM  복수 시간 (반복만)

Schedule:
  day / daily     매일
  weekday         평일 (월-금)
  weekend         주말 (토-일)
  mon,wed,fri     특정 요일

Flags:
  -d <dir>      작업 디렉터리 (절대 경로)
  -s <sid>      세션 재개 (일회성만)
  -H            헤드리스 모드 (터미널 없이 실행)
  -q            출력 폐기 (-H와 함께)

Environment:
  CLAUDE_BRB_TERMINAL           터미널 앱 (Terminal, iTerm2)   [기본: Terminal]
  CLAUDE_BRB_FLAGS              claude CLI 추가 플래그         [기본: 없음]
  CLAUDE_BRB_STORE              작업 저장 디렉터리             [기본: ~/.claude-brb]
  CLAUDE_BRB_LANG               표시 언어 (en, ko)             [기본: 자동 감지]
  CLAUDE_BRB_RESUME_PROMPT      자동 재개 프롬프트 커스터마이즈
  CLAUDE_BRB_RESUME_BUFFER_SECS 리셋 시간 버퍼 (초)           [기본: 300]

Examples:
  brb at 03:00 "Write unit tests"                   새 세션 예약
  brb at +30m -d /Users/dev/app "Refactor"          지정 디렉터리
  brb at +3h -s abc-123-def "Continue"              세션 재개
  brb every day 07:00 "Check status"                매일 7시
  brb every weekday 09:00 "Standup summary"         평일 9시
  brb at +30m -H "Review PR"                        헤드리스
  brb at +1h -H -q "Background task"                헤드리스 (출력 폐기)
  brb auto-resume enable                            자동 재개 활성화
  brb keep-alive enable                             5시간 리셋 활성화
HELP
    else
        cat <<'HELP'
claude-brb, brb — be right back with Claude Code

Usage:
  # Core features
  brb auto-resume enable           enable auto-resume
  brb auto-resume disable          disable
  brb auto-resume status           status + recent history

  brb keep-alive enable [times]    enable 5h timer reset
  brb keep-alive disable           disable
  brb keep-alive status            status

  # One-time scheduling
  brb at <time> "prompt"                    new session in current dir
  brb at <time> -d <dir> "prompt"           in specified dir
  brb at <time> -s <session-id> "prompt"    resume session
  brb at <time> -H "prompt"                 headless mode
  brb at <time> -H -q "prompt"             headless, discard output

  # Recurring scheduling
  brb every <schedule> <time> "prompt"
  brb every <schedule> <time> -d <dir> "prompt"
  brb every <schedule> <time> -H -q "prompt"

  # Management
  brb list                         list jobs (with index numbers)
  brb show <id|#index>             job details
  brb cancel <id|#index|all>       cancel
  brb edit <id|#index> ["prompt"]  modify prompt
  brb reschedule <id|#index> <time>  change time

  # Settings
  brb setup                        initial setup (interactive)
  brb teardown                     full cleanup (before uninstall)
  brb upgrade                      upgrade existing jobs
  brb                              status summary

Time:
  HH:MM       absolute time (next occurrence)
  +Nm         in N minutes
  +Nh         in N hours
  +Nd         in N days
  HH:MM,HH:MM  multiple times (recurring only)

Schedule:
  day / daily     every day
  weekday         Mon-Fri
  weekend         Sat-Sun
  mon,wed,fri     specific days

Flags:
  -d <dir>      working directory (absolute path)
  -s <sid>      resume session (one-time only)
  -H            headless mode (no terminal)
  -q            discard output (use with -H)

Environment:
  CLAUDE_BRB_TERMINAL           terminal app (Terminal, iTerm2)   [default: Terminal]
  CLAUDE_BRB_FLAGS              extra flags for claude CLI        [default: none]
  CLAUDE_BRB_STORE              job storage directory             [default: ~/.claude-brb]
  CLAUDE_BRB_LANG               display language (en, ko)         [default: auto-detect]
  CLAUDE_BRB_RESUME_PROMPT      customize auto-resume prompt
  CLAUDE_BRB_RESUME_BUFFER_SECS buffer after reset time (secs)   [default: 300]

Examples:
  brb at 03:00 "Write unit tests"                   schedule new session
  brb at +30m -d /Users/dev/app "Refactor"          in specified dir
  brb at +3h -s abc-123-def "Continue"              resume session
  brb every day 07:00 "Check status"                daily at 7am
  brb every weekday 09:00 "Standup summary"         weekdays at 9am
  brb at +30m -H "Review PR"                        headless one-time
  brb at +1h -H -q "Background task"                headless, discard output
  brb auto-resume enable                            enable auto-resume
  brb keep-alive enable                             enable 5h timer reset
HELP
    fi
    exit 0
}

# --- input validation ---
validate_job_id() {
    local jid="$1"
    if [[ ! "$jid" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        _err "$(_t "Error: ID must contain only alphanumeric, -, _, ." "Error: ID는 영문, 숫자, -, _, . 만 가능합니다"): ${jid}"
        exit 1
    fi
}

# Directory path validation — allowlist approach
validate_dir_path() {
    local dir="$1"
    if [[ ! "$dir" =~ $_SAFE_PATH_RE ]]; then
        _err "$(_t "Error: unsupported characters in directory path" "Error: 디렉터리 경로에 지원되지 않는 문자 포함"): $dir"
        exit 1
    fi
}

# Validate CLAUDE_BRB_FLAGS — reject shell metacharacters
validate_flags() {
    local flags="$1"
    [ -z "$flags" ] && return 0
    if [[ ! "$flags" =~ ^[a-zA-Z0-9\ _.=/-]+$ ]]; then
        _err "$(_t "Error: CLAUDE_BRB_FLAGS contains unsafe characters" "Error: CLAUDE_BRB_FLAGS에 안전하지 않은 문자 포함")"
        exit 1
    fi
}

# --- validate wake file content (strict date format) ---
_validate_wake_time() {
    local wt="$1"
    [[ "$wt" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

# --- safe meta file reader (parameter expansion based) ---
_read_meta() {
    local meta_file="$1"
    local key="$2"
    local line
    line=$(grep "^${key}=" "$meta_file" 2>/dev/null | head -1 || true)
    [ -z "$line" ] && return 0
    # Strip KEY= prefix, then surrounding single quotes
    line="${line#*=}"
    line="${line#\'}"
    echo "${line%\'}"
}

_load_meta() {
    local meta_file="$1"
    META_TYPE=$(_read_meta "$meta_file" META_TYPE)
    META_MODE=$(_read_meta "$meta_file" META_MODE)
    META_DIR=$(_read_meta "$meta_file" META_DIR)
    META_SID=$(_read_meta "$meta_file" META_SID)
    META_FLAGS=$(_read_meta "$meta_file" META_FLAGS)
    META_TARGET_FMT=$(_read_meta "$meta_file" META_TARGET_FMT)
    META_TARGET_YMD=$(_read_meta "$meta_file" META_TARGET_YMD)
    META_SCHEDULE=$(_read_meta "$meta_file" META_SCHEDULE)
    META_TIMES=$(_read_meta "$meta_file" META_TIMES)
    META_WEEKDAYS=$(_read_meta "$meta_file" META_WEEKDAYS)
    META_HEADLESS=$(_read_meta "$meta_file" META_HEADLESS)
    META_QUIET=$(_read_meta "$meta_file" META_QUIET)
    META_SUBTYPE=$(_read_meta "$meta_file" META_SUBTYPE)
}

# --- day name → launchd Weekday number ---
day_to_num() {
    local d
    d=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$d" in
        sun|sunday)    echo 0 ;;
        mon|monday)    echo 1 ;;
        tue|tuesday)   echo 2 ;;
        wed|wednesday) echo 3 ;;
        thu|thursday)  echo 4 ;;
        fri|friday)    echo 5 ;;
        sat|saturday)  echo 6 ;;
        *) _err "$(_t "Error: unknown day" "Error: 알 수 없는 요일"): $1"; return 1 ;;
    esac
}

# --- schedule string → weekday numbers (empty = daily) ---
expand_schedule() {
    local sched="$1"
    case "$sched" in
        daily)   echo "" ;;
        weekday) echo "1,2,3,4,5" ;;
        weekend) echo "0,6" ;;
        *)
            local result="" num
            IFS=',' read -ra days <<< "$sched"
            for d in "${days[@]}"; do
                num=$(day_to_num "$d") || exit 1
                [ -n "$result" ] && result+=","
                result+="$num"
            done
            echo "$result"
            ;;
    esac
}

# --- validate time strings (comma-separated HH:MM) ---
validate_times() {
    local times="$1"
    IFS=',' read -ra arr <<< "$times"
    [ ${#arr[@]} -eq 0 ] && { _err "$(_t "Error: time is empty" "Error: 시간이 비어있습니다")"; exit 1; }
    for t in "${arr[@]}"; do
        if [[ ! "$t" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
            _err "$(_t "Error: invalid time format" "Error: 잘못된 시간 형식"): $t (HH:MM)"; exit 1
        fi
        local h=$((10#${t%%:*})) m=$((10#${t##*:}))
        if [ "$h" -gt 23 ] || [ "$m" -gt 59 ]; then
            _err "$(_t "Error: invalid time" "Error: 유효하지 않은 시간"): $t"; exit 1
        fi
    done
}

# --- StartCalendarInterval XML generation ---
generate_calendar_intervals() {
    local weekdays="$1"  # empty = daily, or "1,2,3,4,5"
    local times="$2"     # "07:00,12:00,17:00"

    IFS=',' read -ra time_arr <<< "$times"

    if [ -z "$weekdays" ]; then
        for t in "${time_arr[@]}"; do
            local h=$((10#${t%%:*})) m=$((10#${t##*:}))
            printf '        <dict>\n'
            printf '            <key>Hour</key>\n'
            printf '            <integer>%d</integer>\n' "$h"
            printf '            <key>Minute</key>\n'
            printf '            <integer>%d</integer>\n' "$m"
            printf '        </dict>\n'
        done
    else
        IFS=',' read -ra day_arr <<< "$weekdays"
        for d in "${day_arr[@]}"; do
            for t in "${time_arr[@]}"; do
                local h=$((10#${t%%:*})) m=$((10#${t##*:}))
                printf '        <dict>\n'
                printf '            <key>Weekday</key>\n'
                printf '            <integer>%d</integer>\n' "$d"
                printf '            <key>Hour</key>\n'
                printf '            <integer>%d</integer>\n' "$h"
                printf '            <key>Minute</key>\n'
                printf '            <integer>%d</integer>\n' "$m"
                printf '        </dict>\n'
            done
        done
    fi
}

# --- resolve working directory from session ID ---
resolve_session_dir() {
    local sid="$1"
    local projects_dir="$HOME/.claude/projects"
    [ -d "$projects_dir" ] || return 1

    local session_file
    session_file=$(find "$projects_dir" -maxdepth 2 -name "${sid}.jsonl" -print -quit 2>/dev/null)
    [ -n "$session_file" ] || return 1

    local encoded_dir
    encoded_dir=$(basename "$(dirname "$session_file")")
    local path_encoded="${encoded_dir#-}"

    _match_path "/" "$path_encoded"
}

_match_path() {
    local base="$1"
    local remain="$2"

    [ -z "$remain" ] && { echo "$base"; return 0; }

    local entry entry_enc
    while IFS= read -r entry; do
        [ -d "${base%/}/${entry}" ] || continue

        entry_enc="$entry"
        entry_enc="${entry_enc//_/-}"
        entry_enc="${entry_enc// /-}"
        entry_enc="${entry_enc//\~/-}"
        entry_enc="${entry_enc//./-}"

        if [ "$remain" = "$entry_enc" ]; then
            echo "${base%/}/${entry}"
            return 0
        elif [[ "$remain" == "${entry_enc}-"* ]]; then
            local rest="${remain#"${entry_enc}"-}"
            _match_path "${base%/}/${entry}" "$rest" && return 0
        fi
    done < <(ls -1 "$base" 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

    return 1
}

# Unique JOB ID (timestamp + PID + random suffix)
_make_job_id() {
    local prefix="$1"
    echo "${prefix}.$(date +%y%m%d.%H%M%S).$$.${RANDOM}"
}

# Schedule pmset wake for next repeat job execution
_schedule_next_repeat_wake() {
    local jid="$1"
    local weekdays="$2"  # expanded weekday numbers (empty = daily)
    local times="$3"
    local wake_file="$STORE/.wake-${jid}"

    # Cancel previous wake
    if [ -f "$wake_file" ]; then
        local old_wake
        old_wake=$(cat "$wake_file")
        if _validate_wake_time "$old_wake"; then
            sudo -n pmset schedule cancel wake "$old_wake" 2>/dev/null || true
        fi
        rm -f "$wake_file"
    fi

    local now_s best=""
    now_s=$(date +%s)

    # Search next 8 days
    local off check_date check_wday
    for off in 0 1 2 3 4 5 6 7; do
        check_date=$(date -v+${off}d +%Y-%m-%d)
        check_wday=$(date -v+${off}d +%w)

        # Weekday filter
        if [ -n "$weekdays" ]; then
            echo ",$weekdays," | grep -qF ",$check_wday," || continue
        fi

        IFS=',' read -ra _tarr <<< "$times"
        local _t _ts
        for _t in "${_tarr[@]}"; do
            _ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "${check_date} ${_t}:00" +%s 2>/dev/null) || continue
            [ "$_ts" -le "$now_s" ] && continue
            if [ -z "$best" ] || [ "$_ts" -lt "$best" ]; then
                best="$_ts"
            fi
        done
        [ -n "$best" ] && break
    done

    if [ -n "$best" ]; then
        local wake_ts wake_fmt
        wake_ts=$((best - 120))
        wake_fmt=$(date -r "$wake_ts" '+%m/%d/%Y %H:%M:%S')
        _try_schedule_wake "$wake_fmt" "$wake_file"
    fi
}

# Create/update next-wake helper script for repeat runners
_ensure_wake_helper() {
    local helper="$STORE/_next_wake.sh"
    cat > "$helper" << 'WAKESCRIPT'
#!/bin/bash
# claude-brb repeat job next-wake scheduler
STORE="${2:-$HOME/.claude-brb}"
JOB_ID="$1"
[ -z "$JOB_ID" ] && exit 0
META_FILE="$STORE/${JOB_ID}.meta"
WAKE_FILE="$STORE/.wake-${JOB_ID}"
[ -f "$META_FILE" ] || exit 0

# safe meta reader (parameter expansion based)
_read_meta() { local l; l=$(grep "^${2}=" "$1" 2>/dev/null | head -1 || true); [ -z "$l" ] && return 0; l="${l#*=}"; l="${l#\'}"; echo "${l%\'}"; }
META_TYPE=$(_read_meta "$META_FILE" META_TYPE)
[ "${META_TYPE:-}" = "repeat" ] || exit 0
META_TIMES=$(_read_meta "$META_FILE" META_TIMES)
META_WEEKDAYS=$(_read_meta "$META_FILE" META_WEEKDAYS)

wdays="$META_WEEKDAYS"

now_s=$(date +%s)
best=""
for off in 0 1 2 3 4 5 6 7; do
    cd=$(date -v+${off}d +%Y-%m-%d)
    cw=$(date -v+${off}d +%w)
    if [ -n "$wdays" ]; then
        echo ",$wdays," | grep -qF ",$cw," || continue
    fi
    IFS=',' read -ra _ts <<< "$META_TIMES"
    for _t in "${_ts[@]}"; do
        s=$(date -j -f "%Y-%m-%d %H:%M:%S" "${cd} ${_t}:00" +%s 2>/dev/null) || continue
        [ "$s" -le "$now_s" ] && continue
        if [ -z "$best" ] || [ "$s" -lt "$best" ]; then best="$s"; fi
    done
    [ -n "$best" ] && break
done

if [ -n "$best" ]; then
    # Cancel previous wake
    if [ -f "$WAKE_FILE" ]; then
        ow=$(cat "$WAKE_FILE")
        if [[ "$ow" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
            sudo -n pmset schedule cancel wake "$ow" 2>/dev/null || true
        fi
        rm -f "$WAKE_FILE"
    fi
    wt=$((best - 120))
    wf=$(date -r "$wt" '+%m/%d/%Y %H:%M:%S')
    if sudo -n pmset schedule wake "$wf" 2>/dev/null; then
        echo "$wf" > "$WAKE_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') warn: pmset wake failed (run 'brb setup')" >> "$STORE/${JOB_ID}.runlog" 2>/dev/null
    fi
fi
WAKESCRIPT
    chmod +x "$helper"
}

# Atomic file write (tmp → mv)
_atomic_write() {
    local target="$1"
    local tmp
    tmp=$(mktemp "${target}.XXXXXX")
    cat > "$tmp"
    mv -f "$tmp" "$target"
}

# --- shared helpers for generated scripts ---

# Parse time string to epoch seconds (outputs to stdout, errors to stderr)
_parse_time_to_epoch() {
    local time_str="$1"
    local now
    now=$(date +%s)

    if [[ "$time_str" =~ ^\+([0-9]+)m$ ]]; then
        echo $((now + ${BASH_REMATCH[1]} * 60))
    elif [[ "$time_str" =~ ^\+([0-9]+)h$ ]]; then
        echo $((now + ${BASH_REMATCH[1]} * 3600))
    elif [[ "$time_str" =~ ^\+([0-9]+)d$ ]]; then
        date -v+${BASH_REMATCH[1]}d +%s
    elif [[ "$time_str" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        local target
        target=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) ${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:00" +%s 2>/dev/null) || {
            _err "$(_t "Error: invalid time" "Error: 유효하지 않은 시간"): $time_str"
            return 1
        }
        if [ "$target" -le "$now" ]; then
            target=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date -v+1d +%Y-%m-%d) ${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:00" +%s 2>/dev/null) || {
                _err "$(_t "Error: invalid time" "Error: 유효하지 않은 시간"): $time_str"
                return 1
            }
        fi
        echo "$target"
    else
        _err "$(_t "Error: use HH:MM, +30m, +2h, or +1d format" "Error: HH:MM, +30m, +2h, +1d 형식만 가능")"
        return 1
    fi
}

# Check if passwordless pmset access is available
_can_pmset_sudo() {
    sudo -n /usr/bin/pmset -g sched >/dev/null 2>&1
}

# Set up /etc/sudoers.d/claude-brb for passwordless pmset (interactive)
_setup_pmset_sudo() {
    _can_pmset_sudo && return 0
    [ -t 0 ] || return 1

    local sudoers_file="/etc/sudoers.d/claude-brb"
    local user
    user=$(whoami)

    _err ""
    _err "$(_t \
        "Wake scheduling requires passwordless pmset access." \
        "잠자기 해제 예약을 위해 pmset의 비밀번호 없는 실행 권한이 필요합니다.")"
    _err "$(_t \
        "Without this, scheduled jobs may be delayed when Mac is asleep." \
        "이 설정 없이는 Mac이 잠자기 상태일 때 예약이 지연될 수 있습니다.")"
    _err ""
    _err "$(_t "Will create:" "생성할 파일:") ${sudoers_file}"
    _err "  ${user} ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *, /usr/bin/pmset -g sched"
    _err ""
    _err "$(_t \
        "Note: Lid must be open or an external monitor connected." \
        "참고: 덮개가 열려있거나 외부 모니터가 연결되어 있어야 합니다.")"
    _err "$(_t \
        "With lid closed and no display, the job cannot open a terminal." \
        "덮개가 닫힌 채 모니터가 없으면 터미널 창을 열 수 없습니다.")"
    _err ""

    printf "$(_t "Set up now? [Y/n] " "지금 설정할까요? [Y/n] ")"
    local confirm
    read -r confirm
    case "$confirm" in
        n|N|no|NO)
            _err "$(_t "Skipped. Jobs may be delayed when Mac is asleep." \
                "건너뜀. Mac이 잠자기 상태일 때 예약이 지연될 수 있습니다.")"
            return 1
            ;;
    esac

    local rule="${user} ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *, /usr/bin/pmset -g sched"
    if printf '# claude-brb: allow passwordless pmset for wake scheduling\n%s\n' "$rule" \
        | sudo tee "$sudoers_file" >/dev/null \
        && sudo chmod 0440 "$sudoers_file" \
        && sudo chown root:wheel "$sudoers_file"; then
        echo "$(_t "pmset sudo configured." "pmset sudo 설정 완료.")"
        return 0
    else
        _err "$(_t "Error: failed to install sudoers rule" "Error: sudoers 규칙 설치 실패")"
        return 1
    fi
}

# ========== Settings.json hook manipulation utilities ==========

# Add a StopFailure hook entry for auto-resume to ~/.claude/settings.json (idempotent)
_settings_json_add_hook() {
    local hook_cmd="$1"
    local settings_path="${_SETTINGS_PATH:-$HOME/.claude/settings.json}"
    local settings_dir
    settings_dir=$(dirname "$settings_path")
    mkdir -p "$settings_dir"

    # Backup existing
    [ -f "$settings_path" ] && cp "$settings_path" "${settings_path}.bak"

    node -e "
const fs = require('fs');
const p = process.argv[1];
const cmd = process.argv[2];
let s = {};
try { s = JSON.parse(fs.readFileSync(p, 'utf8')); } catch(e) {}
if (!s.hooks) s.hooks = {};
if (!s.hooks.StopFailure) s.hooks.StopFailure = [];
const exists = s.hooks.StopFailure.some(e =>
    e.hooks && e.hooks.some(h => h.command && h.command.includes('_hook-auto-resume'))
);
if (!exists) {
    s.hooks.StopFailure.push({
        matcher: 'rate_limit',
        hooks: [{ type: 'command', command: cmd }]
    });
}
const tmp = p + '.tmp.' + process.pid;
fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
fs.renameSync(tmp, p);
" "$settings_path" "$hook_cmd"
}

# Remove the auto-resume hook entry from ~/.claude/settings.json
_settings_json_remove_hook() {
    local settings_path="${_SETTINGS_PATH:-$HOME/.claude/settings.json}"
    [ -f "$settings_path" ] || return 0

    cp "$settings_path" "${settings_path}.bak"

    node -e "
const fs = require('fs');
const p = process.argv[1];
let s = {};
try { s = JSON.parse(fs.readFileSync(p, 'utf8')); } catch(e) { process.exit(0); }
if (s.hooks && s.hooks.StopFailure) {
    s.hooks.StopFailure = s.hooks.StopFailure.filter(e =>
        !(e.hooks && e.hooks.some(h => h.command && h.command.includes('_hook-auto-resume')))
    );
    if (s.hooks.StopFailure.length === 0) delete s.hooks.StopFailure;
    if (Object.keys(s.hooks).length === 0) delete s.hooks;
}
const tmp = p + '.tmp.' + process.pid;
fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
fs.renameSync(tmp, p);
" "$settings_path"
}

# Check if the auto-resume hook is registered in ~/.claude/settings.json
_settings_json_has_hook() {
    local settings_path="${_SETTINGS_PATH:-$HOME/.claude/settings.json}"
    [ -f "$settings_path" ] || return 1
    node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const has = s.hooks && s.hooks.StopFailure &&
    s.hooks.StopFailure.some(e => e.hooks && e.hooks.some(h => h.command && h.command.includes('_hook-auto-resume')));
process.exit(has ? 0 : 1);
" "$settings_path" 2>/dev/null
}

# auto-resume enable/disable/status command handler
_auto_resume_cmd() {
    local action="${1:-status}"
    case "$action" in
        enable)
            local ca_path
            ca_path=$(command -v claude-brb 2>/dev/null || command -v brb 2>/dev/null)
            [ -z "$ca_path" ] && { _err "Error: cannot resolve claude-brb path"; return 1; }
            ca_path=$(cd "$(dirname "$ca_path")" && pwd)/$(basename "$ca_path")

            if _settings_json_has_hook 2>/dev/null; then
                echo "$(_t "auto-resume is already enabled." "auto-resume가 이미 활성화되어 있습니다.")"
                return 0
            fi

            _settings_json_add_hook "$ca_path _hook-auto-resume"
            mkdir -p "$STORE"
            echo "$(_t "✅ auto-resume enabled (StopFailure hook registered)" "✅ auto-resume 활성화됨 (StopFailure hook 등록 완료)")"
            ;;
        disable)
            _settings_json_remove_hook
            echo "$(_t "✅ auto-resume disabled (hook removed)" "✅ auto-resume 비활성화됨 (hook 제거 완료)")"
            ;;
        status)
            if _settings_json_has_hook 2>/dev/null; then
                if [ -f "$STORE/.auto-resume-bypass-permissions" ]; then
                    echo "$(_t "auto-resume: enabled (bypass-permissions: on)" "auto-resume: 활성 (bypass-permissions: on)")"
                else
                    echo "$(_t "auto-resume: enabled (bypass-permissions: off)" "auto-resume: 활성 (bypass-permissions: off)")"
                fi
            else
                echo "$(_t "auto-resume: disabled" "auto-resume: 비활성")"
            fi
            # Show recent history from log
            if [ -f "$STORE/auto-resume.log" ]; then
                echo "$(_t "  Recent:" "  최근:")"
                grep 'SCHEDULED\|FAILED\|BLOCKED' "$STORE/auto-resume.log" | tail -5 | while IFS= read -r line; do
                    echo "    $line"
                done
            fi
            ;;
        *) _err "Usage: brb auto-resume {enable|disable|status}"; return 1 ;;
    esac
}

_bypass_permissions_cmd() {
    local action="${1:-status}"
    case "$action" in
        enable)
            mkdir -p "$STORE"
            touch "$STORE/.bypass-permissions"
            echo "$(_t "✅ bypass-permissions enabled (at/every jobs)" "✅ bypass-permissions 활성화됨 (at/every 작업에 적용)")"
            ;;
        disable)
            rm -f "$STORE/.bypass-permissions"
            echo "$(_t "✅ bypass-permissions disabled" "✅ bypass-permissions 비활성화됨")"
            ;;
        status)
            if [ -f "$STORE/.bypass-permissions" ]; then
                echo "$(_t "bypass-permissions: enabled" "bypass-permissions: 활성")"
            else
                echo "$(_t "bypass-permissions: disabled" "bypass-permissions: 비활성")"
            fi
            ;;
        *) _err "Usage: brb bypass-permissions {enable|disable|status}"; return 1 ;;
    esac
}

_keep_alive_cmd() {
    local action="${1:-status}"
    case "$action" in
        enable)
            local times="${2:-00:01,05:02,10:03,15:04,20:05}"

            # Check if already active
            if [ -f "$STORE/rpt.keep-alive.meta" ] && [ -f "$STORE/rpt.keep-alive.sh" ]; then
                echo "$(_t "keep-alive is already enabled." "keep-alive가 이미 활성화되어 있습니다.")"
                return 0
            fi

            # Check pmset setup
            if ! _can_pmset_sudo; then
                echo "$(_t "wake-from-sleep requires pmset permissions." "wake-from-sleep에 pmset 권한이 필요합니다.")"
                if [ -t 0 ]; then
                    printf "$(_t "Set up now? [Y/n] " "지금 설정할까요? [Y/n] ")"
                    local confirm; read -r confirm
                    case "${confirm:-Y}" in
                        n|N|no|NO) echo "$(_t "⚠ keep-alive will not work while Mac is asleep." "⚠ Mac이 잠든 상태에서는 keep-alive가 실행되지 않습니다.")" ;;
                        *) _setup_pmset_sudo ;;
                    esac
                fi
            fi

            # Create keep-alive job using internal scheduling
            local JOB_ID="rpt.keep-alive"
            local RPT_DIR="/tmp"
            local RPT_PROMPT="Reply with OK"
            local RPT_WEEKDAYS="0,1,2,3,4,5,6"  # every day

            mkdir -p "$STORE"

            printf '%s' "$RPT_PROMPT" | _atomic_write "$STORE/${JOB_ID}.prompt"
            {
                printf "META_TYPE='repeat'\n"
                printf "META_MODE='new'\n"
                printf "META_DIR='%s'\n" "$RPT_DIR"
                printf "META_SID=''\n"
                printf "META_FLAGS=''\n"
                printf "META_SCHEDULE='day'\n"
                printf "META_TIMES='%s'\n" "$times"
                printf "META_WEEKDAYS='%s'\n" "$RPT_WEEKDAYS"
                printf "META_HEADLESS='yes'\n"
                printf "META_QUIET='yes'\n"
                printf "META_SUBTYPE='keep-alive'\n"
            } | _atomic_write "$STORE/${JOB_ID}.meta"

            _ensure_wake_helper
            _generate_exec "$JOB_ID"
            _generate_runner "$JOB_ID"

            local label="${LABEL_PREFIX}.${JOB_ID}"
            local runner="$STORE/${JOB_ID}.sh"
            mkdir -p "$PLIST_DIR"
            _write_plist_repeat "$label" "$runner" "$JOB_ID" "$RPT_WEEKDAYS" "$times"

            if ! launchctl bootstrap "gui/$(id -u)" "${PLIST_DIR}/${label}.plist" 2>/dev/null; then
                # May already be loaded — try bootout first then reload
                launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
                launchctl bootstrap "gui/$(id -u)" "${PLIST_DIR}/${label}.plist" || {
                    _err "Error: failed to register keep-alive job"
                    return 1
                }
            fi

            _schedule_next_repeat_wake "$JOB_ID" "$RPT_WEEKDAYS" "$times"
            echo "$(_t "✅ keep-alive enabled" "✅ keep-alive 활성화됨") ($times)"
            ;;
        disable)
            local JOB_ID="rpt.keep-alive"
            if [ -f "$STORE/${JOB_ID}.sh" ]; then
                cancel_job "$JOB_ID"
                echo "$(_t "✅ keep-alive disabled" "✅ keep-alive 비활성화됨")"
            else
                echo "$(_t "keep-alive is not active." "keep-alive가 활성화되어 있지 않습니다.")"
            fi
            ;;
        status)
            if [ -f "$STORE/rpt.keep-alive.meta" ] && [ -f "$STORE/rpt.keep-alive.sh" ]; then
                local times
                times=$(_read_meta "$STORE/rpt.keep-alive.meta" META_TIMES)
                echo "$(_t "keep-alive: enabled" "keep-alive: 활성") ($times)"

                # Last execution from runlog
                if [ -f "$STORE/rpt.keep-alive.runlog" ]; then
                    local last_line
                    last_line=$(tail -1 "$STORE/rpt.keep-alive.runlog")
                    echo "  $(_t "Last run:" "마지막 실행:") $last_line"
                fi
            else
                echo "$(_t "keep-alive: disabled" "keep-alive: 비활성")"
            fi
            ;;
        *) _err "Usage: brb keep-alive {enable|disable|status} [times]"; return 1 ;;
    esac
}

# Try to schedule pmset wake (auto-setup → sudo -n → interactive fallback)
_try_schedule_wake() {
    local wake_fmt="$1"
    local wake_file="$2"

    # Fast path: passwordless sudo works
    if sudo -n pmset schedule wake "$wake_fmt" 2>/dev/null; then
        echo "$wake_fmt" > "$wake_file"
        return 0
    fi

    # Offer to set up passwordless pmset access
    if _setup_pmset_sudo; then
        if sudo -n pmset schedule wake "$wake_fmt" 2>/dev/null; then
            echo "$wake_fmt" > "$wake_file"
            return 0
        fi
    fi

    # Final fallback: interactive sudo (one-time password)
    if [ -t 0 ]; then
        _err "$(_t "Admin password required for wake-from-sleep:" "잠자기 해제를 위해 관리자 비밀번호가 필요합니다:")"
        if sudo pmset schedule wake "$wake_fmt"; then
            echo "$wake_fmt" > "$wake_file"
        else
            _err "$(_t "Warning: pmset wake scheduling failed" "경고: pmset wake 예약 실패")"
        fi
    else
        _err "$(_t "Warning: pmset wake scheduling skipped (run 'brb setup')" "경고: pmset wake 예약 생략 ('brb setup' 실행 필요)")"
    fi
}

# Generate AppleScript notification line for runner scripts
_applescript_notify() {
    local mode="$1"
    local info="$2"

    if [ "$mode" = "new" ]; then
        printf '%s\n' "[[ \"\${LANG:-}\" == ko* ]] && _NOTIF=\"Claude 새 세션을 시작합니다 (${info})\" || _NOTIF=\"Starting new Claude session (${info})\""
    else
        printf '%s\n' "[[ \"\${LANG:-}\" == ko* ]] && _NOTIF=\"Claude 세션을 재개합니다 (${info})\" || _NOTIF=\"Resuming Claude session (${info})\""
    fi
    printf '%s\n' 'osascript -e "display notification \"$_NOTIF\" with title \"claude-brb\""'
}

# Generate notification lines for headless runner scripts
_applescript_notify_headless() {
    local action="$1"  # "start" or "done"
    local info="$2"
    local out_file="${3:-}"  # optional, for completion notification

    if [ "$action" = "start" ]; then
        printf '%s\n' "[[ \"\${LANG:-}\" == ko* ]] && _NOTIF=\"헤드리스 Claude 작업 시작 (${info})\" || _NOTIF=\"Headless Claude task started (${info})\""
    else
        if [ -n "$out_file" ]; then
            printf '%s\n' "[[ \"\${LANG:-}\" == ko* ]] && _NOTIF=\"헤드리스 Claude 작업 완료. 출력: ${out_file}\" || _NOTIF=\"Headless Claude task completed. Output: ${out_file}\""
        else
            printf '%s\n' "[[ \"\${LANG:-}\" == ko* ]] && _NOTIF=\"헤드리스 Claude 작업 완료 (${info})\" || _NOTIF=\"Headless Claude task completed (${info})\""
        fi
    fi
    printf '%s\n' 'osascript -e "display notification \"$_NOTIF\" with title \"claude-brb\""'
}

# Generate AppleScript block to open terminal with exec script (with retry)
_applescript_run_in_terminal() {
    local terminal="$1"
    local exec_script="$2"

    printf '%s\n' '_ca_ok=false'
    printf '%s\n' 'for _ca_i in 1 2 3; do'
    printf '%s\n' "    if osascript << 'SCPT'"
    case "$terminal" in
        Terminal)
            printf '%s\n' 'tell application "Terminal"'
            printf '%s\n' '    activate'
            printf '    do script "bash '\''%s'\''"\n' "$exec_script"
            printf '%s\n' 'end tell'
            ;;
        iTerm|iTerm2)
            printf '%s\n' 'tell application "iTerm"'
            printf '%s\n' '    activate'
            printf '    create window with default profile command "bash '\''%s'\''"\n' "$exec_script"
            printf '%s\n' 'end tell'
            ;;
    esac
    printf '%s\n' 'SCPT'
    printf '%s\n' '    then'
    printf '%s\n' '        _ca_ok=true'
    printf '%s\n' '        break'
    printf '%s\n' '    fi'
    printf '%s\n' '    echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') osascript attempt $_ca_i/3 failed" >&2'
    printf '%s\n' '    sleep 3'
    printf '%s\n' 'done'
    printf '%s\n' 'if ! $_ca_ok; then'
    printf '%s\n' '    echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') ERROR: osascript failed after 3 attempts" >&2'
    printf '%s\n' 'fi'
}

# Warn if claude CLI is not found
_check_claude() {
    if ! command -v claude >/dev/null 2>&1; then
        _err "$(_t "Warning: 'claude' not found in PATH. Job may fail at runtime." "경고: PATH에서 'claude'를 찾을 수 없습니다. 실행 시 실패할 수 있습니다.")"
        if [ -t 0 ]; then
            printf "$(_t "Continue anyway? [y/N] " "계속 진행할까요? [y/N] ")"
            local confirm
            read -r confirm
            case "$confirm" in
                y|Y|yes|YES) ;;
                *) echo "$(_t "Aborted." "중단됨.")"; exit 1 ;;
            esac
        fi
    fi
}

# Headless permission check: warn if --dangerously-skip-permissions not set
# Outputs the flag to stdout ONLY if user accepts; all prompts/warnings go to stderr.
_headless_perm_check() {
    local current_flags="$1"
    # Already has the flag — nothing to do
    [[ "$current_flags" == *"--dangerously-skip-permissions"* ]] && return 0

    _MSG_HEADLESS_PERM_WARN >&2
    echo "" >&2
    if [ -t 0 ]; then
        printf "$(_t "  Add --dangerously-skip-permissions to this job? [y/N] " "  이 작업에 --dangerously-skip-permissions를 추가할까요? [y/N] ")" >&2
        local confirm
        read -r confirm
        case "$confirm" in
            y|Y|yes|YES)
                echo "--dangerously-skip-permissions"
                return 0
                ;;
            *)
                _err "$(_t "  Proceeding without it. The job may stall on permission prompts." "  플래그 없이 진행합니다. 작업이 권한 프롬프트에서 멈출 수 있습니다.")"
                return 0
                ;;
        esac
    else
        _err "$(_t "  Warning: headless job may stall without --dangerously-skip-permissions" "  경고: --dangerously-skip-permissions 없이 헤드리스 작업이 멈출 수 있습니다")"
    fi
}

# Detect claude binary directory for generated scripts
_claude_bin_dir() {
    if command -v claude >/dev/null 2>&1; then
        dirname "$(command -v claude)"
    fi
}

# --- exec script: runs inside the terminal (no escaping issues) ---
_generate_exec() {
    local jid="$1"
    local meta_file="$STORE/${jid}.meta"
    local prompt_file="$STORE/${jid}.prompt"
    local exec_script="$STORE/${jid}.exec.sh"

    local META_TYPE="" META_MODE="" META_DIR="" META_SID="" META_FLAGS=""
    local META_TARGET_FMT="" META_TARGET_YMD=""
    local META_SCHEDULE="" META_TIMES="" META_WEEKDAYS=""
    local META_HEADLESS="" META_QUIET=""
    _load_meta "$meta_file"

    # Defense-in-depth: re-validate loaded meta values
    validate_dir_path "$META_DIR"
    validate_flags "${META_FLAGS:-}"
    [ -n "$META_SID" ] && validate_job_id "$META_SID"

    local flags_part="${META_FLAGS:+ ${META_FLAGS}}"
    local meta_type="${META_TYPE:-once}"
    local has_prompt=false
    [ -f "$prompt_file" ] && [ -s "$prompt_file" ] && has_prompt=true

    local cbd
    cbd=$(_claude_bin_dir)
    local path_prefix=""
    [ -n "$cbd" ] && path_prefix="${cbd}:"

    {
        printf '%s\n' '#!/bin/bash'
        printf 'export PATH="%s$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"\n' "$path_prefix"

        if [ "${META_HEADLESS:-}" = "yes" ]; then
            # --- headless exec: claude -p, no terminal decorations ---
            # No EXIT trap — runner handles all cleanup for headless jobs.
            if [ "$meta_type" = "once" ]; then
                $has_prompt && printf 'PROMPT=$(<"%s")\n' "${prompt_file}"
                printf 'cd "%s" || exit 1\n' "${META_DIR}"
            else
                printf 'cd "%s" || exit 1\n' "${META_DIR}"
                $has_prompt && printf 'PROMPT=$(<"%s")\n' "${prompt_file}"
            fi

            if [ "${META_MODE:-new}" = "resume" ] && [ -n "${META_SID}" ]; then
                if $has_prompt; then
                    printf 'caffeinate -i claude -p%s --resume '\''%s'\'' "$PROMPT"\n' "$flags_part" "${META_SID}"
                else
                    printf 'caffeinate -i claude -p%s --resume '\''%s'\''\n' "$flags_part" "${META_SID}"
                fi
            else
                if $has_prompt; then
                    printf 'caffeinate -i claude -p%s "$PROMPT"\n' "$flags_part"
                else
                    printf 'caffeinate -i claude -p%s\n' "$flags_part"
                fi
            fi
        else
            # --- standard interactive exec ---
            printf '%s\n' 'echo ""'
            printf '%s\n' 'printf "\033[2m  ─────────────────────────────────\033[0m\n"'
            printf '%s\n' 'printf "\033[1m  %s\033[0m  \033[2mclaude-brb\033[0m\n" "$(date '\''+%Y-%m-%d %H:%M:%S'\'')"'
            printf '%s\n' 'printf "\033[2m  ─────────────────────────────────\033[0m\n"'
            printf '%s\n' 'echo ""'

            if [ "$meta_type" = "once" ]; then
                # One-time: read prompt BEFORE setting cleanup trap
                $has_prompt && printf 'PROMPT=$(<"%s")\n' "${prompt_file}"
                printf '%s\n' "trap 'launchctl bootout gui/\$(id -u)/${LABEL_PREFIX}.${jid} 2>/dev/null; rm -f \"${PLIST_DIR}/${LABEL_PREFIX}.${jid}.plist\" \"${STORE}/${jid}.sh\" \"${exec_script}\" \"${STORE}/.wake-${jid}\" \"${STORE}/${jid}.log\" \"${STORE}/${jid}.runlog\" \"${STORE}/${jid}.prompt\" \"${STORE}/${jid}.meta\"' EXIT"
                printf 'cd "%s"\n' "${META_DIR}"
            else
                # Repeat: no cleanup, read prompt after cd
                printf 'cd "%s"\n' "${META_DIR}"
                $has_prompt && printf 'PROMPT=$(<"%s")\n' "${prompt_file}"
            fi

            if [ "${META_MODE:-new}" = "resume" ] && [ -n "${META_SID}" ]; then
                if $has_prompt; then
                    printf 'caffeinate -i claude%s --resume '\''%s'\'' "$PROMPT"\n' "$flags_part" "${META_SID}"
                else
                    printf 'caffeinate -i claude%s --resume '\''%s'\''\n' "$flags_part" "${META_SID}"
                fi
            else
                if $has_prompt; then
                    printf 'caffeinate -i claude%s "$PROMPT"\n' "$flags_part"
                else
                    printf 'caffeinate -i claude%s\n' "$flags_part"
                fi
            fi
        fi
    } | _atomic_write "$exec_script"
    chmod +x "$exec_script"
}

# --- runner script: triggered by launchd, opens terminal ---
_generate_runner() {
    local jid="$1"
    local meta_file="$STORE/${jid}.meta"
    local prompt_file="$STORE/${jid}.prompt"
    local runner="$STORE/${jid}.sh"
    local exec_script="$STORE/${jid}.exec.sh"

    local META_TYPE="" META_MODE="" META_DIR="" META_SID="" META_FLAGS=""
    local META_TARGET_FMT="" META_TARGET_YMD=""
    local META_SCHEDULE="" META_TIMES="" META_WEEKDAYS=""
    local META_HEADLESS="" META_QUIET=""
    _load_meta "$meta_file"

    # Defense-in-depth: re-validate loaded meta values
    validate_dir_path "$META_DIR"
    validate_flags "${META_FLAGS:-}"
    [ -n "$META_SID" ] && validate_job_id "$META_SID"

    # Log summary
    local PROMPT=""
    [ -f "$prompt_file" ] && PROMPT=$(<"$prompt_file")
    local log_prompt="${PROMPT//$'\n'/ }"
    log_prompt="${log_prompt:0:50}..."

    local info_label
    if [ "${META_MODE:-new}" = "new" ]; then
        info_label="${META_DIR}"
    else
        info_label="${META_SID}"
    fi

    local safe_terminal="${CLAUDE_BRB_TERMINAL}"
    local meta_type="${META_TYPE:-once}"

    local cbd
    cbd=$(_claude_bin_dir)
    local path_prefix=""
    [ -n "$cbd" ] && path_prefix="${cbd}:"

    {
        printf '%s\n' '#!/bin/bash'
        printf 'export PATH="%s$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"\n' "$path_prefix"

        if [ "$meta_type" = "repeat" ]; then
            printf '%s\n' "# repeat | ${META_SCHEDULE} ${META_TIMES} | ${jid} | ${info_label} | ${log_prompt:-resume}"
            # Schedule next wake before dedup guard (must run even if skipped)
            printf '%s\n' "bash \"${STORE}/_next_wake.sh\" \"${jid}\" \"${STORE}\" 2>/dev/null &"
            # Dedup guard: skip if last run was within MIN_INTERVAL seconds
            printf '%s\n' "_RUNLOG=\"${STORE}/${jid}.runlog\""
            printf '%s\n' "_MIN_INTERVAL=${CLAUDE_BRB_MIN_INTERVAL}"
            printf '%s\n' 'if [ -f "$_RUNLOG" ]; then'
            printf '%s\n' '    _LAST_LINE=$(tail -1 "$_RUNLOG")'
            printf '%s\n' '    case "$_LAST_LINE" in'
            printf '%s\n' '        *" run")'
            printf '%s\n' '            _LAST_TS="${_LAST_LINE% run}"'
            printf '%s\n' '            if [[ "$_LAST_TS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then'
            printf '%s\n' '                _LAST_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$_LAST_TS" +%s 2>/dev/null) || _LAST_EPOCH=0'
            printf '%s\n' '                _NOW_EPOCH=$(date +%s)'
            printf '%s\n' '                if [ $((_NOW_EPOCH - _LAST_EPOCH)) -lt $_MIN_INTERVAL ]; then'
            printf '%s\n' '                    echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') skip (dedup)" >> "$_RUNLOG"'
            printf '%s\n' '                    exit 0'
            printf '%s\n' '                fi'
            printf '%s\n' '            fi'
            printf '%s\n' '            ;;'
            printf '%s\n' '    esac'
            printf '%s\n' 'fi'
            printf '%s\n' "echo \"\$(date '+%Y-%m-%d %H:%M:%S') run\" >> \"${STORE}/${jid}.runlog\""
        else
            printf '%s\n' "# once | ${META_TARGET_FMT} | ${jid} | ${info_label} | ${log_prompt:-resume}"
            # Date guard: clean up and exit if launchd fires on wrong date
            printf '%s\n' "if [ \"\$(date +%Y%m%d)\" != \"${META_TARGET_YMD}\" ]; then"
            printf '%s\n' "    launchctl bootout gui/\$(id -u)/${LABEL_PREFIX}.${jid} 2>/dev/null"
            printf '%s\n' "    rm -f \"${PLIST_DIR}/${LABEL_PREFIX}.${jid}.plist\" \"${runner}\" \"${STORE}/${jid}.exec.sh\" \"${STORE}/.wake-${jid}\" \"${STORE}/${jid}.log\" \"${STORE}/${jid}.runlog\" \"${STORE}/${jid}.prompt\" \"${STORE}/${jid}.meta\""
            printf '%s\n' "    exit 0"
            printf '%s\n' "fi"
        fi

        if [ "${META_HEADLESS:-}" = "yes" ]; then
            # --- headless runner: no terminal, direct execution ---
            _applescript_notify_headless "start" "$info_label"

            if [ "${META_QUIET:-}" = "yes" ]; then
                printf '%s\n' "bash \"${exec_script}\" > /dev/null 2>&1"
            else
                if [ "$meta_type" = "repeat" ]; then
                    # Repeat: append with timestamp header so previous runs are preserved
                    printf '%s\n' "echo \"--- \$(date '+%Y-%m-%d %H:%M:%S') ---\" >> \"${STORE}/${jid}.out\""
                    printf '%s\n' "bash \"${exec_script}\" >> \"${STORE}/${jid}.out\" 2>&1"
                else
                    printf '%s\n' "bash \"${exec_script}\" > \"${STORE}/${jid}.out\" 2>&1"
                fi
            fi

            if [ "$meta_type" = "once" ]; then
                if [ "${META_QUIET:-}" = "yes" ]; then
                    _applescript_notify_headless "done" "$info_label"
                else
                    _applescript_notify_headless "done" "$info_label" "${STORE}/${jid}.out"
                fi
                # Runner handles ALL cleanup for headless one-time jobs
                # Note: .out file is intentionally preserved for user inspection
                printf '%s\n' "rm -f \"${PLIST_DIR}/${LABEL_PREFIX}.${jid}.plist\" \"${runner}\" \"${exec_script}\" \"${STORE}/.wake-${jid}\" \"${STORE}/${jid}.log\" \"${STORE}/${jid}.runlog\" \"${STORE}/${jid}.prompt\" \"${STORE}/${jid}.meta\""
                printf '%s\n' "launchctl bootout gui/\$(id -u)/${LABEL_PREFIX}.${jid} 2>/dev/null"
            fi
        else
            # --- standard runner: wake display, open terminal ---
            # Wake display and prevent idle sleep (needed when waking from pmset schedule)
            printf '%s\n' 'caffeinate -u -t 30 &'
            printf '%s\n' 'sleep 3'

            # Notification (shared between repeat and once)
            _applescript_notify "${META_MODE:-new}" "$info_label"

            # Open terminal (shared, with iTerm2 support)
            _applescript_run_in_terminal "$safe_terminal" "$exec_script"

            if [ "$meta_type" = "once" ]; then
                # One-time: clean up registration files immediately after launch
                # (exec.sh already read prompt and will self-delete on exit)
                printf '%s\n' "sleep 2"
                printf '%s\n' "rm -f \"${PLIST_DIR}/${LABEL_PREFIX}.${jid}.plist\" \"${runner}\" \"${STORE}/.wake-${jid}\" \"${STORE}/${jid}.log\" \"${STORE}/${jid}.prompt\" \"${STORE}/${jid}.meta\""
                printf '%s\n' "launchctl bootout gui/\$(id -u)/${LABEL_PREFIX}.${jid} 2>/dev/null"
            fi
        fi
    } | _atomic_write "$runner"

    chmod +x "$runner"
}

# --- plist generation helpers (atomic write) ---
_write_plist_once() {
    local label="$1" runner="$2" jid="$3"
    local target_month="$4" target_day="$5" target_hour="$6" target_min="$7"
    local plist="${PLIST_DIR}/${label}.plist"
    {
        cat << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${runner}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Month</key>
        <integer>${target_month}</integer>
        <key>Day</key>
        <integer>${target_day}</integer>
        <key>Hour</key>
        <integer>${target_hour}</integer>
        <key>Minute</key>
        <integer>${target_min}</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${STORE}/${jid}.log</string>
    <key>StandardErrorPath</key>
    <string>${STORE}/${jid}.log</string>
</dict>
</plist>
PLIST
    } | _atomic_write "$plist"
}

_write_plist_repeat() {
    local label="$1" runner="$2" jid="$3"
    local weekdays="$4" times="$5"
    local plist="${PLIST_DIR}/${label}.plist"
    {
        cat << PLIST_HEAD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${runner}</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
PLIST_HEAD
        generate_calendar_intervals "$weekdays" "$times"
        cat << PLIST_TAIL
    </array>
    <key>StandardOutPath</key>
    <string>${STORE}/${jid}.log</string>
    <key>StandardErrorPath</key>
    <string>${STORE}/${jid}.log</string>
</dict>
</plist>
PLIST_TAIL
    } | _atomic_write "$plist"
}

# --- atomic metadata update ---
_update_meta_field() {
    local meta_file="$1" key="$2" value="$3"
    local tmp_meta="${meta_file}.tmp.$$"
    grep -v "^${key}=" "$meta_file" > "$tmp_meta" || true
    printf "%s='%s'\n" "$key" "$value" >> "$tmp_meta"
    mv -f "$tmp_meta" "$meta_file"
}

# --- list jobs ---
list_jobs() {
    mkdir -p "$STORE"
    local found=false
    printf " #  %-10s | %-22s | %-34s | %-28s | %s\n" "TYPE" "SCHEDULE" "JOB ID" "TARGET" "PROMPT"
    printf '%0.s-' {1..124}; echo
    local lines=""
    for f in "$STORE"/*.meta; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f" .meta)
        # Skip non-job files
        [ -f "$STORE/${fname}.sh" ] || continue
        found=true

        local m_type m_schedule m_times m_target_fmt m_dir m_sid m_flags m_subtype
        m_type=$(_read_meta "$f" META_TYPE)
        m_schedule=$(_read_meta "$f" META_SCHEDULE)
        m_times=$(_read_meta "$f" META_TIMES)
        m_target_fmt=$(_read_meta "$f" META_TARGET_FMT)
        m_dir=$(_read_meta "$f" META_DIR)
        m_sid=$(_read_meta "$f" META_SID)
        m_flags=$(_read_meta "$f" META_FLAGS)
        m_subtype=$(_read_meta "$f" META_SUBTYPE)

        local type_display sched_display target_display prompt_display
        # Show subtype if present, otherwise type
        if [ -n "$m_subtype" ]; then
            type_display="$m_subtype"
        else
            type_display="${m_type:-once}"
        fi
        [ -n "$m_flags" ] && type_display="${type_display} [!]"

        if [ "${m_type:-once}" = "repeat" ]; then
            sched_display="${m_schedule} ${m_times}"
            target_display="${m_dir}"
        else
            sched_display="${m_target_fmt}"
            if [ -n "$m_sid" ]; then
                target_display="${m_sid}"
            else
                target_display="${m_dir}"
            fi
        fi

        # Headless marker
        local m_headless m_quiet
        m_headless=$(_read_meta "$f" META_HEADLESS)
        m_quiet=$(_read_meta "$f" META_QUIET)
        local markers=""
        if [ "${m_headless:-}" = "yes" ]; then
            markers="H"
            [ "${m_quiet:-}" = "yes" ] && markers="${markers}q"
        fi
        local m_flags
        m_flags=$(_read_meta "$f" META_FLAGS)
        if [[ "${m_flags:-}" == *"--dangerously-skip-permissions"* ]]; then
            markers="${markers}B"
        fi
        [ -n "$markers" ] && target_display="[${markers}] ${target_display}"

        prompt_display=""
        [ -f "$STORE/${fname}.prompt" ] && prompt_display=$(head -1 "$STORE/${fname}.prompt" | cut -c1-50)

        lines+="${type_display} | ${sched_display} | ${fname} | ${target_display} | ${prompt_display}..."$'\n'
    done
    if $found; then
        local idx=0
        printf '%s' "$lines" | sort | while IFS= read -r line; do
            idx=$((idx + 1))
            printf "%2d  " "$idx"
            echo "$line" | awk -F ' \\| ' '{printf "%-10s | %-22s | %-34s | %-28s | %s\n", $1, $2, $3, $4, $5}'
        done
    else
        echo "$(_t "(no jobs)" "(예약 없음)")"
    fi
    echo ""
    echo "$(_t "Modify prompt:" "프롬프트 수정:") brb edit <JOB ID>"
    echo "$(_t "Change time: " "시간 변경:   ") brb reschedule <JOB ID> <TIME>"
    echo "$(_t "Cancel job:  " "예약 취소:   ") brb cancel <JOB ID> | brb cancel all"
    return 0
}

# --- cancel all (one-time only, keeps repeat jobs) ---
cancel_all_jobs() {
    mkdir -p "$STORE"

    # Pre-count one-time jobs for confirmation
    local total_once=0 total_repeat=0
    for f in "$STORE"/*.sh; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f" .sh)
        [[ "$fname" == _* ]] && continue
        [[ "$fname" == *.exec ]] && continue
        local meta_file="$STORE/${fname}.meta"
        if [ -f "$meta_file" ]; then
            local m_type
            m_type=$(_read_meta "$meta_file" META_TYPE)
            if [ "${m_type:-once}" = "repeat" ]; then
                total_repeat=$((total_repeat + 1))
                continue
            fi
        fi
        total_once=$((total_once + 1))
    done

    if [ "$total_once" -eq 0 ]; then
        echo "$(_t "(no one-time jobs)" "(일회성 예약 없음)")"
        [ "$total_repeat" -gt 0 ] && echo "$(_t "${total_repeat} repeat job(s) kept (cancel individually: brb cancel <JOB ID>)" "반복 예약 ${total_repeat}개는 유지됨 (개별 취소: brb cancel <JOB ID>)")"
        return 0
    fi

    # Interactive confirmation
    if [ -t 0 ]; then
        printf "$(_t "Cancel %d one-time job(s)? [y/N] " "%d개 일회성 예약을 취소할까요? [y/N] ")" "$total_once"
        local confirm
        read -r confirm
        case "$confirm" in
            y|Y|yes|YES) ;;
            *) echo "$(_t "Cancelled." "취소됨.")"; return 0 ;;
        esac
    fi

    local count=0
    local wake_fail=false
    for f in "$STORE"/*.sh; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f" .sh)
        [[ "$fname" == _* ]] && continue
        [[ "$fname" == *.exec ]] && continue
        local meta_file="$STORE/${fname}.meta"
        if [ -f "$meta_file" ]; then
            local m_type
            m_type=$(_read_meta "$meta_file" META_TYPE)
            [ "${m_type:-once}" = "repeat" ] && continue
        fi
        local label="${LABEL_PREFIX}.${fname}"
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        rm -f "${PLIST_DIR}/${label}.plist"
        rm -f "$f"
        rm -f "$STORE/${fname}.exec.sh"
        rm -f "$STORE/${fname}.log"
        rm -f "$STORE/${fname}.runlog"
        rm -f "$STORE/${fname}.prompt"
        rm -f "$STORE/${fname}.meta"
        rm -f "$STORE/${fname}.out"
        if [ -f "$STORE/.wake-${fname}" ]; then
            local wake_time
            wake_time=$(cat "$STORE/.wake-${fname}")
            if _validate_wake_time "$wake_time"; then
                if ! sudo -n pmset schedule cancel wake "$wake_time" 2>/dev/null; then
                    wake_fail=true
                fi
            fi
            rm -f "$STORE/.wake-${fname}"
        fi
        echo "$(_t "Cancelled:" "취소됨:") ${fname}"
        count=$((count + 1))
    done
    # Clean up helper script only if no repeat jobs remain
    [ "$total_repeat" -eq 0 ] && rm -f "$STORE/_next_wake.sh"
    echo "$(_t "${count} job(s) cancelled" "총 ${count}개 예약 취소됨")"
    [ "$total_repeat" -gt 0 ] && echo "$(_t "${total_repeat} repeat job(s) kept (cancel individually: brb cancel <JOB ID>)" "반복 예약 ${total_repeat}개는 유지됨 (개별 취소: brb cancel <JOB ID>)")"
    $wake_fail && _err "$(_t "Warning: some pmset wake cancellations require admin privileges" "경고: 일부 pmset wake 취소에 관리자 권한이 필요합니다")"
    return 0
}

# --- cancel individual job ---
cancel_job() {
    local jid="$1"
    [ "$jid" = "all" ] && { cancel_all_jobs; return $?; }

    validate_job_id "$jid"
    local label="${LABEL_PREFIX}.${jid}"

    if [ ! -f "${PLIST_DIR}/${label}.plist" ] && [ ! -f "$STORE/${jid}.sh" ]; then
        _err "$(_t "Error: job not found (see 'brb list')" "Error: 해당 Job ID를 찾을 수 없습니다 ('brb list' 참조)"): ${jid}"
        return 1
    fi

    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    rm -f "${PLIST_DIR}/${label}.plist"
    rm -f "$STORE/${jid}.sh"
    rm -f "$STORE/${jid}.exec.sh"
    rm -f "$STORE/${jid}.log"
    rm -f "$STORE/${jid}.runlog"
    rm -f "$STORE/${jid}.prompt"
    rm -f "$STORE/${jid}.meta"
    rm -f "$STORE/${jid}.out"
    if [ -f "$STORE/.wake-${jid}" ]; then
        local wake_time
        wake_time=$(cat "$STORE/.wake-${jid}")
        if _validate_wake_time "$wake_time"; then
            if ! sudo -n pmset schedule cancel wake "$wake_time" 2>/dev/null; then
                _err "$(_t "Admin password required to cancel pmset wake:" "pmset wake 취소를 위해 관리자 비밀번호가 필요합니다:")"
                sudo pmset schedule cancel wake "$wake_time" || _err "$(_t "Warning: pmset wake cancellation failed" "경고: pmset wake 취소 실패")"
            fi
        fi
        rm -f "$STORE/.wake-${jid}"
    fi
    echo "$(_t "Cancelled:" "취소됨:") ${jid}"
    return 0
}

# --- modify prompt ---
modify_job() {
    local jid="$1"
    shift
    local new_prompt="${1:-}"

    validate_job_id "$jid"

    local meta_file="$STORE/${jid}.meta"
    local prompt_file="$STORE/${jid}.prompt"
    local runner="$STORE/${jid}.sh"

    if [ ! -f "$runner" ]; then
        _err "$(_t "Error: job not found (see 'brb list')" "Error: 해당 Job ID를 찾을 수 없습니다 ('brb list' 참조)"): ${jid}"
        return 1
    fi

    if [ ! -f "$meta_file" ] || [ ! -f "$prompt_file" ]; then
        _err "$(_t "Error: metadata missing. Run 'brb upgrade' first." "Error: 메타데이터 파일이 없습니다. 'brb upgrade'를 먼저 실행하세요.")"
        return 1
    fi

    local old_prompt
    old_prompt=$(<"$prompt_file")

    if [ -n "$new_prompt" ]; then
        printf '%s' "$new_prompt" | _atomic_write "$prompt_file"
    else
        local display_prompt edited
        local vared_prompt
        vared_prompt=$(_t "Prompt: " "프롬프트: ")
        display_prompt=$(<"$prompt_file")
        edited=$(CA_OLD="$display_prompt" CA_VP="$vared_prompt" zsh -c 'p="$CA_OLD"; vared -p "$CA_VP" p </dev/tty 2>/dev/tty; printf "%s" "$p"') || {
            _err "$(_t "Error: prompt editing failed" "Error: 프롬프트 편집 실패")"
            return 1
        }
        if [ -z "$edited" ]; then
            _err "$(_t "Error: empty prompt not allowed" "Error: 빈 프롬프트는 허용되지 않습니다")"
            return 1
        fi
        printf '%s' "$edited" | _atomic_write "$prompt_file"
    fi

    local PROMPT
    PROMPT=$(<"$prompt_file")

    if [ "$PROMPT" = "$old_prompt" ]; then
        echo "$(_t "No changes" "변경 사항 없음")"
        return 0
    fi

    _generate_exec "$jid"
    _generate_runner "$jid"

    echo "$(_t "Prompt modified:" "프롬프트 수정 완료:") ${jid}"
    echo "$(_t "Old:" "이전:") ${old_prompt:0:80}"
    echo "$(_t "New:" "변경:") ${PROMPT:0:80}"
    return 0
}

# --- reschedule job ---
retime_job() {
    local jid="$1"
    if [ -z "${2:-}" ]; then
        _err "$(_t "Error: time required (HH:MM, +30m, +2h, +1d)" "Error: 시간이 필요합니다 (HH:MM, +30m, +2h, +1d)")"
        return 1
    fi
    local time_str="$2"

    validate_job_id "$jid"

    local meta_file="$STORE/${jid}.meta"
    local runner="$STORE/${jid}.sh"
    local label="${LABEL_PREFIX}.${jid}"
    local plist="${PLIST_DIR}/${label}.plist"

    if [ ! -f "$runner" ]; then
        _err "$(_t "Error: job not found (see 'brb list')" "Error: 해당 Job ID를 찾을 수 없습니다 ('brb list' 참조)"): ${jid}"
        return 1
    fi

    if [ ! -f "$meta_file" ]; then
        _err "$(_t "Error: metadata missing. Run 'brb upgrade' first." "Error: 메타데이터 파일이 없습니다. 'brb upgrade'를 먼저 실행하세요.")"
        return 1
    fi

    local META_TYPE="" META_MODE="" META_DIR="" META_SID="" META_FLAGS=""
    local META_TARGET_FMT="" META_TARGET_YMD=""
    local META_SCHEDULE="" META_TIMES="" META_WEEKDAYS=""
    local META_HEADLESS="" META_QUIET=""
    _load_meta "$meta_file"
    local meta_type="${META_TYPE:-once}"

    # ========== repeat job reschedule ==========
    if [ "$meta_type" = "repeat" ]; then
        if [[ "$time_str" == +* ]]; then
            _err "$(_t "Error: repeat jobs cannot use relative time (+Nm, +Nh, +Nd). Use HH:MM format." "Error: 반복 작업은 상대 시간(+Nm, +Nh, +Nd) 사용 불가. HH:MM 형식을 사용하세요.")"
            _err "$(_t "Example:" "예:") brb reschedule ${jid} 08:00,13:00"
            return 1
        fi

        validate_times "$time_str"

        local old_times="${META_TIMES}"

        _update_meta_field "$meta_file" META_TIMES "$time_str"

        _generate_exec "$jid"
        _generate_runner "$jid"

        local weekdays="${META_WEEKDAYS}"

        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        _write_plist_repeat "$label" "$runner" "$jid" "$weekdays" "$time_str"
        if ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
            _err "$(_t "Error: launchctl bootstrap failed" "Error: launchctl bootstrap 실패")"
            return 1
        fi

        _schedule_next_repeat_wake "$jid" "$weekdays" "$time_str"

        echo "$(_t "Rescheduled:" "시간 변경 완료:") ${META_SCHEDULE} ${old_times} → ${META_SCHEDULE} ${time_str} (Job ID: ${jid})"
        return 0
    fi

    # ========== one-time job reschedule ==========
    local target
    target=$(_parse_time_to_epoch "$time_str") || return 1

    local target_fmt target_min target_hour target_day target_month target_ymd
    target_fmt=$(date -r "$target" '+%m/%d %H:%M')
    target_min=$((10#$(date -r "$target" +%M)))
    target_hour=$((10#$(date -r "$target" +%H)))
    target_day=$((10#$(date -r "$target" +%d)))
    target_month=$((10#$(date -r "$target" +%m)))
    target_ymd=$(date -r "$target" +%Y%m%d)

    local old_fmt="${META_TARGET_FMT}"

    _update_meta_field "$meta_file" META_TARGET_FMT "$target_fmt"
    _update_meta_field "$meta_file" META_TARGET_YMD "$target_ymd"

    _generate_exec "$jid"
    _generate_runner "$jid"

    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    _write_plist_once "$label" "$runner" "$jid" "$target_month" "$target_day" "$target_hour" "$target_min"
    if ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
        _err "$(_t "Error: launchctl bootstrap failed" "Error: launchctl bootstrap 실패")"
        return 1
    fi

    if [ -f "$STORE/.wake-${jid}" ]; then
        local old_wake
        old_wake=$(cat "$STORE/.wake-${jid}")
        if _validate_wake_time "$old_wake"; then
            sudo -n pmset schedule cancel wake "$old_wake" 2>/dev/null || true
        fi
        rm -f "$STORE/.wake-${jid}"
    fi

    local wake_ts wake_fmt
    wake_ts=$((target - 120))
    wake_fmt=$(date -r "$wake_ts" '+%m/%d/%Y %H:%M:%S')
    _try_schedule_wake "$wake_fmt" "$STORE/.wake-${jid}"

    echo "$(_t "Rescheduled:" "시간 변경 완료:") ${old_fmt} → ${target_fmt} (Job ID: ${jid})"
    return 0
}

# ===================================================================
# Main flow
# ===================================================================

# --- upgrade existing jobs ---
upgrade_all_jobs() {
    mkdir -p "$STORE"
    local count=0
    for f in "$STORE"/*.meta; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f" .meta)
        [ -f "$STORE/${fname}.sh" ] || continue

        # Add META_FLAGS if missing
        if ! grep -q '^META_FLAGS=' "$f" 2>/dev/null; then
            printf "META_FLAGS=''\n" >> "$f"
        fi
        # Add META_HEADLESS if missing (defaults to non-headless)
        if ! grep -q '^META_HEADLESS=' "$f" 2>/dev/null; then
            printf "META_HEADLESS=''\n" >> "$f"
        fi
        if ! grep -q '^META_QUIET=' "$f" 2>/dev/null; then
            printf "META_QUIET=''\n" >> "$f"
        fi

        _generate_exec "$fname"
        _generate_runner "$fname"
        # Fix permissions on existing files
        chmod 600 "$f" "$STORE/${fname}.prompt" 2>/dev/null || true
        echo "$(_t "Upgraded:" "업그레이드됨:") ${fname}"
        count=$((count + 1))
    done
    # Regenerate _next_wake.sh if any repeat jobs exist
    local has_repeat=false
    for f in "$STORE"/*.meta; do
        [ -f "$f" ] || continue
        grep -q "^META_TYPE='repeat'" "$f" 2>/dev/null && { has_repeat=true; break; }
    done
    $has_repeat && _ensure_wake_helper

    if [ "$count" -eq 0 ]; then
        echo "$(_t "(no jobs to upgrade)" "(업그레이드할 작업 없음)")"
    else
        echo "$(_t "${count} job(s) upgraded" "총 ${count}개 작업 업그레이드됨")"
    fi
    exit 0
}

# --- auto-resume hook ---

_ar_notify() {
    local msg="$1"
    local level="${2:-info}"  # info, warning, error, success
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"claude-brb\"" 2>/dev/null || true
}

_hook_auto_resume() {
    # Disable set -e — hook handles errors explicitly via ERR trap
    set +e
    trap '_ec=$?; _ar_notify "auto-resume hook error: $BASH_COMMAND (exit $_ec)" "error"
          echo "[$(date)] ERR: $BASH_COMMAND (exit $_ec)" >> "$STORE/auto-resume.log"' ERR

    # Ensure store exists
    mkdir -p "$STORE"

    local input
    input=$(cat)

    # Log raw input
    echo "[$(date)] INPUT: $input" >> "$STORE/auto-resume.log"

    # Check dependencies
    command -v node >/dev/null 2>&1 || { _ar_notify "auto-resume: node not found" "error"; return 1; }

    # Parse JSON with node
    local parsed
    parsed=$(node -e "
        try {
            const d = JSON.parse(process.argv[1]);
            console.log([
                d.session_id || '',
                d.error_details || d.last_assistant_message || '',
                d.cwd || ''
            ].join('\n'));
        } catch(e) { process.exit(1); }
    " "$input" 2>/dev/null) || { _ar_notify "auto-resume: JSON parse failed" "error"; return 1; }

    local session_id error_details cwd_path
    session_id=$(echo "$parsed" | sed -n '1p')
    error_details=$(echo "$parsed" | sed -n '2p')
    cwd_path=$(echo "$parsed" | sed -n '3p')

    # Validate session_id
    if [ -z "$session_id" ] || ! [[ "$session_id" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        _ar_notify "auto-resume: invalid session_id" "error"
        return 1
    fi

    # Recency guard
    local guard_file="$STORE/.last-stop-${session_id}"
    local now
    now=$(date +%s)
    if [ -f "$guard_file" ]; then
        local recent_count=0
        while IFS= read -r ts; do
            [ -z "$ts" ] && continue
            if [ $((now - ts)) -lt 1800 ]; then  # 30 minutes
                recent_count=$((recent_count + 1))
            fi
        done < "$guard_file"
        if [ "$recent_count" -ge 3 ]; then
            local _guard_msg
            _guard_msg="$(_t 'auto-resume: retry limit exceeded for session' 'auto-resume: 세션 재시도 한도 초과') ${session_id}"
            _ar_notify "$_guard_msg" "warning"
            echo "$_guard_msg" >&2
            echo "[$(date)] BLOCKED: recency guard (${recent_count} in 30min)" >> "$STORE/auto-resume.log"
            return 0
        fi
    fi
    # Record this stop, keep only last 3
    echo "$now" >> "$guard_file"
    tail -3 "$guard_file" > "${guard_file}.tmp" && mv "${guard_file}.tmp" "$guard_file"

    # Parse reset time from error_details or last_assistant_message
    local buffer_secs="${CLAUDE_BRB_RESUME_BUFFER_SECS:-300}"
    local schedule_time
    schedule_time=$(node -e "
        const details = process.argv[1];
        const bufferSecs = parseInt(process.argv[2]) || 300;

        // Normalize '10pm' -> '10:00 PM', '8:30am' -> '8:30 AM' for Date parsing
        function normalizeTime(s) {
            const m = s.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/i);
            if (!m) return s;
            return m[1] + ':' + (m[2] || '00') + ' ' + m[3].toUpperCase();
        }

        // Pattern 1: 'resets 10pm (America/New_York)'
        let m = details.match(/resets?\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm))\s*\(([^)]+)\)/i);
        if (m) {
            const timeStr = normalizeTime(m[1].trim());
            const tz = m[2];
            const now = new Date();
            const dateStr = now.toLocaleDateString('en-US', {timeZone: tz});
            const target = new Date(dateStr + ' ' + timeStr);
            if (!isNaN(target)) {
                if (target <= now) target.setDate(target.getDate() + 1);
                target.setSeconds(target.getSeconds() + bufferSecs);
                const hh = String(target.getHours()).padStart(2,'0');
                const mm = String(target.getMinutes()).padStart(2,'0');
                console.log(hh + ':' + mm);
                process.exit(0);
            }
        }

        // Pattern 2: 'resets Jan 29 at 8pm (America/New_York)'
        m = details.match(/resets?\s+(\w+\s+\d+)\s+at\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm))\s*\(([^)]+)\)/i);
        if (m) {
            const target = new Date(m[1] + ' ' + normalizeTime(m[2].trim()));
            if (!isNaN(target)) {
                target.setSeconds(target.getSeconds() + bufferSecs);
                const hh = String(target.getHours()).padStart(2,'0');
                const mm = String(target.getMinutes()).padStart(2,'0');
                console.log(hh + ':' + mm);
                process.exit(0);
            }
        }

        // Fallback: no parseable time
        process.exit(1);
    " "$error_details" "$buffer_secs" 2>/dev/null) || schedule_time="+5h"

    # Resolve ca path
    local ca_bin
    ca_bin=$(command -v claude-brb 2>/dev/null || command -v brb 2>/dev/null || echo "$0")

    # Build resume prompt
    local resume_prompt="${CLAUDE_BRB_RESUME_PROMPT:-$(_t \
        'You were interrupted by a rate limit. Review the conversation history and continue where you left off. Verify the current state before making changes. Do not repeat completed work.' \
        'Rate limit으로 작업이 중단되었습니다. 대화 기록을 검토하고 중단된 지점부터 이어서 진행하세요. 변경 전 현재 상태를 확인하고, 이미 완료된 작업은 반복하지 마세요.')}"

    # Bypass permissions flag (append to existing CLAUDE_BRB_FLAGS)
    local ar_flags="${CLAUDE_BRB_FLAGS:-}"
    if [ -f "$STORE/.auto-resume-bypass-permissions" ]; then
        ar_flags="${ar_flags:+${ar_flags} }--dangerously-skip-permissions"
    fi

    # Log before scheduling so silent failures are diagnosable
    echo "[$(date)] SCHEDULING: time=${schedule_time} session=${session_id}" >> "$STORE/auto-resume.log"

    # Schedule resume
    local ca_output
    if ca_output=$(_CLAUDE_BRB_SUBTYPE=auto-resume CLAUDE_BRB_FLAGS="${ar_flags}" "$ca_bin" at "$schedule_time" -s "$session_id" "$resume_prompt" 2>&1); then
        local job_info
        job_info=$(echo "$ca_output" | grep -o 'Job ID: [^ ]*' | head -1 || echo "")
        if echo "$ca_output" | grep -q 'Already scheduled'; then
            echo "[$(date)] DEDUP: idempotent skip session=${session_id} ${job_info}" >> "$STORE/auto-resume.log"
        else
            _ar_notify "$(_t "auto-resume: scheduled at ${schedule_time}" "auto-resume: ${schedule_time}에 재개 예약됨") | brb cancel ${job_info##*: }" "success"
            echo "[$(date)] SCHEDULED: ${schedule_time} session=${session_id} ${job_info}" >> "$STORE/auto-resume.log"
        fi
    else
        _ar_notify "$(_t 'auto-resume: scheduling failed' 'auto-resume: 예약 실패')" "error"
        echo "[$(date)] FAILED: brb exit=$? output=$ca_output" >> "$STORE/auto-resume.log"
    fi
}

# ===================================================================
# New functions for subcommand-based CLI
# ===================================================================

_parse_at_flags() {
    # Parses flags from argument list between time and prompt
    # Sets: _FLAG_DIR, _FLAG_SID, _HEADLESS, _QUIET
    _FLAG_DIR=""
    _FLAG_SID=""
    _BYPASS_PERMISSIONS=""
    _REMAINING_ARGS=()
    local i=0

    while [ $i -lt $# ]; do
        local idx=$((i + 1))
        local arg="${!idx}"
        case "$arg" in
            -d) i=$((i + 1)); idx=$((i + 1)); _FLAG_DIR="${!idx:-}"; [ -z "$_FLAG_DIR" ] && { _err "Error: -d requires directory path"; exit 1; } ;;
            -s) i=$((i + 1)); idx=$((i + 1)); _FLAG_SID="${!idx:-}"; [ -z "$_FLAG_SID" ] && { _err "Error: -s requires session ID"; exit 1; } ;;
            -H|--headless) _HEADLESS='yes' ;;
            -q|--quiet) _QUIET='yes' ;;
            -B|--bypass-permissions) _BYPASS_PERMISSIONS='yes' ;;
            *) _REMAINING_ARGS+=("$arg") ;;
        esac
        i=$((i + 1))
    done

    # Validate flag combinations
    if [ -n "$_FLAG_DIR" ] && [ -n "$_FLAG_SID" ]; then
        _err "$(_t "Error: -d and -s cannot be used together" "Error: -d와 -s는 함께 사용할 수 없습니다")"
        exit 1
    fi
    if [ "$_QUIET" = 'yes' ] && [ "$_HEADLESS" != 'yes' ]; then
        _err "$(_MSG_QUIET_REQUIRES_HEADLESS)"
        exit 1
    fi
}

_schedule_at() {
    [ $# -lt 2 ] && { _err "Usage: brb at <time> [flags] 'prompt'"; exit 1; }

    _FLAG_DIR=""
    _FLAG_SID=""
    local TIME_STR="$1"; shift
    local PROMPT="${!#}"  # last argument

    if [ $# -gt 1 ]; then
        local flag_count=$(($# - 1))
        local flag_args=()
        local j=0
        while [ $j -lt $flag_count ]; do
            local jdx=$((j + 1))
            flag_args+=("${!jdx}")
            j=$((j + 1))
        done
        _parse_at_flags "${flag_args[@]}"
    fi

    mkdir -p "$STORE"
    [ -d "$STORE" ] && chmod 700 "$STORE" 2>/dev/null || true
    if [ -n "${CLAUDE_BRB_STORE:-}" ] && [ "$(stat -f '%u' "$STORE")" != "$(id -u)" ]; then
        _err "$(_t "Error: store directory must be owned by current user" "Error: 저장 디렉터리는 현재 사용자 소유여야 합니다"): $STORE"
        exit 1
    fi
    validate_flags "$CLAUDE_BRB_FLAGS"
    _check_claude

    local DIR MODE SID=""
    if [ -n "${_FLAG_SID:-}" ]; then
        MODE="resume"
        SID="$_FLAG_SID"
        validate_job_id "$SID"
        DIR=$(resolve_session_dir "$SID") || {
            _err "$(_t "Error: cannot find project directory for session" "Error: 세션의 프로젝트 디렉터리를 찾을 수 없습니다") '${SID}'"
            exit 1
        }
    elif [ -n "${_FLAG_DIR:-}" ]; then
        MODE="new"
        DIR="$_FLAG_DIR"
    else
        MODE="new"
        DIR="$(pwd)"
    fi

    validate_dir_path "$DIR"
    [ ! -d "$DIR" ] && { _err "$(_t "Error: directory not found" "Error: 디렉터리를 찾을 수 없습니다"): $DIR"; exit 1; }
    DIR=$(cd "$DIR" && pwd)
    validate_dir_path "$DIR"

    local id_prefix="once"
    local meta_subtype=""
    [ "$MODE" = "resume" ] && id_prefix="res"
    [ "${_CLAUDE_BRB_SUBTYPE:-}" = "auto-resume" ] && meta_subtype="auto-resume"

    JOB_ID=$(_make_job_id "$id_prefix")

    local target
    target=$(_parse_time_to_epoch "$TIME_STR") || exit 1
    local target_fmt target_min target_hour target_day target_month target_ymd
    target_fmt=$(date -r "$target" '+%m/%d %H:%M')
    target_min=$((10#$(date -r "$target" +%M)))
    target_hour=$((10#$(date -r "$target" +%H)))
    target_day=$((10#$(date -r "$target" +%d)))
    target_month=$((10#$(date -r "$target" +%m)))
    target_ymd=$(date -r "$target" +%Y%m%d)

    # Idempotent scheduling: reject if identical pending job exists
    # auto-resume: match session_id + prompt (time may drift ±1min across hooks)
    # manual:      match dir + schedule_time + prompt
    for _dup_meta in "$STORE"/*.meta; do
        [ -f "$_dup_meta" ] || continue
        local _dup_jid
        _dup_jid=$(basename "$_dup_meta" .meta)
        [ -f "$STORE/${_dup_jid}.sh" ] || continue  # must be active job
        [ "$(_read_meta "$_dup_meta" META_TYPE)" = "once" ] || continue
        [ "$(_read_meta "$_dup_meta" META_SID)" = "${SID:-}" ] || continue
        [ "$(_read_meta "$_dup_meta" META_DIR)" = "$DIR" ] || continue
        # For non-auto-resume jobs, require exact time match
        if [ "${meta_subtype:-}" != "auto-resume" ] || [ "$(_read_meta "$_dup_meta" META_SUBTYPE)" != "auto-resume" ]; then
            [ "$(_read_meta "$_dup_meta" META_TARGET_FMT)" = "$target_fmt" ] || continue
        fi
        # Check prompt content
        local _dup_prompt=""
        [ -f "$STORE/${_dup_jid}.prompt" ] && _dup_prompt=$(<"$STORE/${_dup_jid}.prompt")
        if [ "$_dup_prompt" = "$PROMPT" ]; then
            echo "$(_t "Already scheduled:" "이미 예약됨:") ${target_fmt} (Job ID: ${_dup_jid})"
            exit 0
        fi
    done

    _HL_FLAGS="$CLAUDE_BRB_FLAGS"
    # Apply bypass-permissions: -B flag or global setting
    if [ "$_BYPASS_PERMISSIONS" = 'yes' ] || [ -f "$STORE/.bypass-permissions" ]; then
        if [[ "$_HL_FLAGS" != *"--dangerously-skip-permissions"* ]]; then
            _HL_FLAGS="${_HL_FLAGS:+${_HL_FLAGS} }--dangerously-skip-permissions"
        fi
    elif [ "$_HEADLESS" = 'yes' ]; then
        extra_flag=$(_headless_perm_check "$_HL_FLAGS")
        [ -n "$extra_flag" ] && _HL_FLAGS="${_HL_FLAGS:+${_HL_FLAGS} }${extra_flag}"
    fi

    printf '%s' "$PROMPT" | _atomic_write "$STORE/${JOB_ID}.prompt"
    {
        printf "META_TYPE='once'\n"
        printf "META_MODE='%s'\n" "$MODE"
        printf "META_DIR='%s'\n" "$DIR"
        printf "META_SID='%s'\n" "${SID:-}"
        printf "META_FLAGS='%s'\n" "$_HL_FLAGS"
        printf "META_TARGET_FMT='%s'\n" "$target_fmt"
        printf "META_TARGET_YMD='%s'\n" "$target_ymd"
        printf "META_SCHEDULE=''\n"
        printf "META_TIMES=''\n"
        printf "META_WEEKDAYS=''\n"
        [ "$_HEADLESS" = 'yes' ] && printf "META_HEADLESS='yes'\n"
        [ "$_QUIET" = 'yes' ] && printf "META_QUIET='yes'\n"
        [ -n "$meta_subtype" ] && printf "META_SUBTYPE='%s'\n" "$meta_subtype"
        true
    } | _atomic_write "$STORE/${JOB_ID}.meta"

    [ -n "$_HL_FLAGS" ] && _err "$(_t "WARNING: This job will run with:" "경고: 이 작업은 다음 플래그로 실행됩니다:") $_HL_FLAGS"

    _generate_exec "$JOB_ID"
    _generate_runner "$JOB_ID"

    local label="${LABEL_PREFIX}.${JOB_ID}"
    local runner="$STORE/${JOB_ID}.sh"
    mkdir -p "$PLIST_DIR"
    _write_plist_once "$label" "$runner" "$JOB_ID" "$target_month" "$target_day" "$target_hour" "$target_min"

    if ! launchctl bootstrap "gui/$(id -u)" "${PLIST_DIR}/${label}.plist"; then
        _err "$(_t "Error: launchctl bootstrap failed." "Error: launchctl bootstrap 실패.")"
        exit 1
    fi

    local wake_ts=$((target - 120))
    local wake_fmt=$(date -r "$wake_ts" '+%m/%d/%Y %H:%M:%S')
    _try_schedule_wake "$wake_fmt" "$STORE/.wake-${JOB_ID}"

    echo "$(_t "Scheduled:" "예약 완료:") ${target_fmt} (Job ID: ${JOB_ID})"
    exit 0
}

_schedule_every() {
    [ $# -lt 3 ] && { _err "Usage: brb every <schedule> <time> [flags] 'prompt'"; exit 1; }

    _FLAG_DIR=""
    _FLAG_SID=""
    local RPT_SCHEDULE="$1"; shift
    local RPT_TIMES="$1"; shift
    local PROMPT="${!#}"  # last argument

    if [ $# -gt 1 ]; then
        local flag_count=$(($# - 1))
        local flag_args=()
        local j=0
        while [ $j -lt $flag_count ]; do
            local jdx=$((j + 1))
            flag_args+=("${!jdx}")
            j=$((j + 1))
        done
        _parse_at_flags "${flag_args[@]}"
    fi

    # -s is not supported for repeat jobs
    [ -n "${_FLAG_SID:-}" ] && { _err "$(_t "Error: -s is not supported for 'every' (repeat jobs always start a new session)" "Error: -s는 'every'에서 지원되지 않습니다 (반복 작업은 항상 새 세션을 시작합니다)")"; exit 1; }

    mkdir -p "$STORE"
    [ -d "$STORE" ] && chmod 700 "$STORE" 2>/dev/null || true
    if [ -n "${CLAUDE_BRB_STORE:-}" ] && [ "$(stat -f '%u' "$STORE")" != "$(id -u)" ]; then
        _err "$(_t "Error: store directory must be owned by current user" "Error: 저장 디렉터리는 현재 사용자 소유여야 합니다"): $STORE"
        exit 1
    fi
    validate_flags "$CLAUDE_BRB_FLAGS"
    _check_claude

    local RPT_WEEKDAYS
    RPT_WEEKDAYS=$(expand_schedule "$RPT_SCHEDULE") || exit 1
    validate_times "$RPT_TIMES"

    local RPT_DIR
    if [ -n "${_FLAG_DIR:-}" ]; then
        RPT_DIR="$_FLAG_DIR"
    else
        RPT_DIR="$(pwd)"
    fi

    validate_dir_path "$RPT_DIR"
    [ ! -d "$RPT_DIR" ] && { _err "$(_t "Error: directory not found" "Error: 디렉터리를 찾을 수 없습니다"): $RPT_DIR"; exit 1; }
    RPT_DIR=$(cd "$RPT_DIR" && pwd)
    validate_dir_path "$RPT_DIR"

    local RPT_SCHED_ID="${RPT_SCHEDULE//,/-}"
    JOB_ID=$(_make_job_id "rpt.${RPT_SCHED_ID}")

    _HL_FLAGS="$CLAUDE_BRB_FLAGS"
    # Apply bypass-permissions: -B flag or global setting
    if [ "$_BYPASS_PERMISSIONS" = 'yes' ] || [ -f "$STORE/.bypass-permissions" ]; then
        if [[ "$_HL_FLAGS" != *"--dangerously-skip-permissions"* ]]; then
            _HL_FLAGS="${_HL_FLAGS:+${_HL_FLAGS} }--dangerously-skip-permissions"
        fi
    elif [ "$_HEADLESS" = 'yes' ]; then
        extra_flag=$(_headless_perm_check "$_HL_FLAGS")
        [ -n "$extra_flag" ] && _HL_FLAGS="${_HL_FLAGS:+${_HL_FLAGS} }${extra_flag}"
    fi

    printf '%s' "$PROMPT" | _atomic_write "$STORE/${JOB_ID}.prompt"
    {
        printf "META_TYPE='repeat'\n"
        printf "META_MODE='new'\n"
        printf "META_DIR='%s'\n" "$RPT_DIR"
        printf "META_SID=''\n"
        printf "META_FLAGS='%s'\n" "$_HL_FLAGS"
        printf "META_SCHEDULE='%s'\n" "$RPT_SCHEDULE"
        printf "META_TIMES='%s'\n" "$RPT_TIMES"
        printf "META_WEEKDAYS='%s'\n" "$RPT_WEEKDAYS"
        [ "$_HEADLESS" = 'yes' ] && printf "META_HEADLESS='yes'\n"
        [ "$_QUIET" = 'yes' ] && printf "META_QUIET='yes'\n"
        true
    } | _atomic_write "$STORE/${JOB_ID}.meta"

    [ -n "$_HL_FLAGS" ] && _err "$(_t "WARNING: This job will run with:" "경고: 이 작업은 다음 플래그로 실행됩니다:") $_HL_FLAGS"

    _ensure_wake_helper
    _generate_exec "$JOB_ID"
    _generate_runner "$JOB_ID"

    local label="${LABEL_PREFIX}.${JOB_ID}"
    local runner="$STORE/${JOB_ID}.sh"
    mkdir -p "$PLIST_DIR"
    _write_plist_repeat "$label" "$runner" "$JOB_ID" "$RPT_WEEKDAYS" "$RPT_TIMES"

    if ! launchctl bootstrap "gui/$(id -u)" "${PLIST_DIR}/${label}.plist"; then
        _err "$(_t "Error: launchctl bootstrap failed." "Error: launchctl bootstrap 실패.")"
        exit 1
    fi

    _schedule_next_repeat_wake "$JOB_ID" "$RPT_WEEKDAYS" "$RPT_TIMES"

    echo "$(_t "Scheduled:" "반복 예약 완료:") ${RPT_SCHEDULE} ${RPT_TIMES} (Job ID: ${JOB_ID})"
    exit 0
}

_status_summary() {
    echo "claude-brb $VERSION"
    echo ""

    if _settings_json_has_hook 2>/dev/null; then
        if [ -f "$STORE/.auto-resume-bypass-permissions" ]; then
            echo "$(_t "auto-resume: enabled (bypass-permissions: on)" "auto-resume: 활성 (bypass-permissions: on)")"
        else
            echo "$(_t "auto-resume: enabled (bypass-permissions: off)" "auto-resume: 활성 (bypass-permissions: off)")"
        fi
    else
        echo "$(_t "auto-resume: disabled" "auto-resume: 비활성")"
    fi

    if [ -f "$STORE/rpt.keep-alive.meta" ] && [ -f "$STORE/rpt.keep-alive.sh" ]; then
        local times
        times=$(_read_meta "$STORE/rpt.keep-alive.meta" META_TIMES)
        echo "$(_t "keep-alive:  enabled" "keep-alive:  활성") ($times)"
    else
        echo "$(_t "keep-alive:  disabled" "keep-alive:  비활성")"
    fi

    if [ -f "$STORE/.bypass-permissions" ]; then
        echo "$(_t "bypass-permissions: enabled" "bypass-permissions: 활성")"
    else
        echo "$(_t "bypass-permissions: disabled" "bypass-permissions: 비활성")"
    fi

    local count=0
    for f in "$STORE"/*.meta; do
        [ -f "$f" ] || continue
        local fname; fname=$(basename "$f" .meta)
        [ -f "$STORE/${fname}.sh" ] && count=$((count + 1))
    done
    echo ""
    echo "$(_t "Scheduled jobs:" "예약된 작업:") ${count}$(_t " jobs" "개")"
    echo "$(_t "'brb list' for details, 'brb help' for usage" "'brb list'로 목록 확인, 'brb help'로 사용법 확인")"
    return 0
}

_full_setup() {
    mkdir -p "$STORE"
    echo "claude-brb $(_t "initial setup" "초기 설정")"
    echo "━━━━━━━━━━━━━━━━━━"
    echo ""

    # Step 1: pmset
    echo "[1/4] $(_t "Wake-from-sleep permissions" "Wake-from-sleep 권한 설정")"
    if _can_pmset_sudo; then
        echo "      $(_t "Already configured. Skipping." "이미 설정되어 있습니다. 건너뜁니다.")"
    else
        echo "      $(_t "Required for scheduled jobs to run while Mac is asleep." "Mac이 잠든 상태에서도 예약 작업을 실행하려면 필요합니다.")"
        printf "      $(_t "Set up? [Y/n] " "설정할까요? [Y/n] ")"
        local c; read -r c
        case "${c:-Y}" in
            n|N) echo "      $(_t "Skipped." "건너뛰었습니다.")" ;;
            *) _setup_pmset_sudo && echo "      Done." || echo "      Failed." ;;
        esac
    fi
    echo ""

    # Step 2: auto-resume
    echo "[2/4] $(_t "Auto-resume" "Auto-resume 활성화")"
    if _settings_json_has_hook 2>/dev/null; then
        echo "      $(_t "Already enabled. Skipping." "이미 활성화되어 있습니다. 건너뜁니다.")"
    else
        echo "      $(_t "Automatically resumes sessions after rate limits." "Rate limit 시 자동으로 세션을 재개합니다.")"
        printf "      $(_t "Enable? [Y/n] " "활성화할까요? [Y/n] ")"
        local c; read -r c
        case "${c:-Y}" in
            n|N) echo "      $(_t "Skipped." "건너뛰었습니다.")" ;;
            *) _auto_resume_cmd enable ;;
        esac
    fi

    # Step 2-1: bypass permissions for auto-resume
    if _settings_json_has_hook 2>/dev/null; then
        echo ""
        echo "      $(_t "Bypass permissions: resume with --dangerously-skip-permissions" "권한 우회: --dangerously-skip-permissions로 재개")"
        echo "      $(_t "When enabled, the resumed session skips all permission prompts." "활성화하면 재개된 세션에서 모든 권한 프롬프트를 건너뜁니다.")"
        if [ -f "$STORE/.auto-resume-bypass-permissions" ]; then
            echo "      $(_t "Currently: on" "현재: on")"
            printf "      $(_t "Keep? [Y/n] " "유지할까요? [Y/n] ")"
            local c; read -r c
            case "${c:-Y}" in
                n|N) rm -f "$STORE/.auto-resume-bypass-permissions"
                     echo "      $(_t "Disabled." "비활성화됨.")" ;;
                *)   echo "      $(_t "Kept." "유지됨.")" ;;
            esac
        else
            printf "      $(_t "Enable? [Y/n] " "활성화할까요? [Y/n] ")"
            local c; read -r c
            case "${c:-Y}" in
                n|N) echo "      $(_t "Skipped." "건너뛰었습니다.")" ;;
                *)   touch "$STORE/.auto-resume-bypass-permissions"
                     echo "      $(_t "Enabled." "활성화됨.")" ;;
            esac
        fi
    fi
    echo ""

    # Step 3: global bypass-permissions
    echo "[3/4] $(_t "Bypass-permissions (global)" "Bypass-permissions (글로벌 설정)")"
    echo "      $(_t "Runs at/every jobs with --dangerously-skip-permissions." "예약 작업(at/every)을 --dangerously-skip-permissions로 실행합니다.")"
    echo "      $(_t "When enabled, scheduled sessions skip all permission prompts." "활성화하면 예약된 세션에서 모든 권한 프롬프트를 건너뜁니다.")"
    if [ -f "$STORE/.bypass-permissions" ]; then
        echo "      $(_t "Currently: on" "현재: on")"
        printf "      $(_t "Keep? [Y/n] " "유지할까요? [Y/n] ")"
        local c; read -r c
        case "${c:-Y}" in
            n|N) rm -f "$STORE/.bypass-permissions"
                 echo "      $(_t "Disabled." "비활성화됨.")" ;;
            *)   echo "      $(_t "Kept." "유지됨.")" ;;
        esac
    else
        printf "      $(_t "Enable? [y/N] " "활성화할까요? [y/N] ")"
        local c; read -r c
        case "${c:-N}" in
            y|Y) touch "$STORE/.bypass-permissions"
                 echo "      $(_t "Enabled." "활성화됨.")" ;;
            *)   echo "      $(_t "Skipped." "건너뛰었습니다.")" ;;
        esac
    fi
    echo ""

    # Step 4: keep-alive
    echo "[4/4] $(_t "Keep-alive" "Keep-alive 활성화")"
    if [ -f "$STORE/rpt.keep-alive.meta" ] && [ -f "$STORE/rpt.keep-alive.sh" ]; then
        echo "      $(_t "Already enabled. Skipping." "이미 활성화되어 있습니다. 건너뜁니다.")"
    else
        echo "      $(_t "Resets the 5-hour timer every 5 hours." "5시간마다 제한 타이머를 자동 리셋합니다.")"
        printf "      $(_t "Enable? [Y/n] " "활성화할까요? [Y/n] ")"
        local c; read -r c
        case "${c:-Y}" in
            n|N) echo "      $(_t "Skipped." "건너뛰었습니다.")" ;;
            *) _keep_alive_cmd enable ;;
        esac
    fi
    echo ""
    echo "$(_t "Setup complete!" "설정 완료!")"
    _status_summary
}

_teardown() {
    echo "[1/4] $(_t "Removing auto-resume hook..." "auto-resume hook 제거...")"
    _settings_json_remove_hook
    rm -f "$STORE/.auto-resume-bypass-permissions"
    rm -f "$STORE/.bypass-permissions"
    echo "      Done."

    echo "[2/4] $(_t "Cleaning up auto-resume jobs..." "auto-resume 예약 정리...")"
    local ar_count=0
    for f in "$STORE"/*.meta; do
        [ -f "$f" ] || continue
        local subtype; subtype=$(_read_meta "$f" META_SUBTYPE)
        if [ "$subtype" = "auto-resume" ]; then
            local fname; fname=$(basename "$f" .meta)
            cancel_job "$fname" 2>/dev/null && ar_count=$((ar_count + 1))
        fi
    done
    echo "      Done. ($ar_count $(_t "cancelled" "취소됨"))"

    echo "[3/4] $(_t "Disabling keep-alive..." "keep-alive 해제...")"
    if [ -f "$STORE/rpt.keep-alive.sh" ]; then
        cancel_job "rpt.keep-alive" 2>/dev/null
    fi
    echo "      Done."

    echo "[4/4] $(_t "Removing pmset permissions..." "pmset 권한 제거...")"
    if [ -f /etc/sudoers.d/claude-brb ]; then
        sudo rm -f /etc/sudoers.d/claude-brb && echo "      Done." || echo "      Failed. (sudo required)"
    else
        echo "      $(_t "Not configured. Skipping." "설정되어 있지 않습니다.")"
    fi

    local user_count=0
    for f in "$STORE"/*.meta; do
        [ -f "$f" ] || continue
        local fname; fname=$(basename "$f" .meta)
        [ -f "$STORE/${fname}.sh" ] && user_count=$((user_count + 1))
    done
    echo ""
    if [ "$user_count" -gt 0 ]; then
        echo "$(_t "User jobs remaining:" "사용자 예약 작업 유지:") ${user_count}$(_t " jobs" "개")"
        echo "$(_t "To remove all: brb cancel all" "전체 삭제: brb cancel all")"
    fi
}

_resolve_job_ref() {
    local ref="$1"
    ref="${ref#\#}"
    if [[ "$ref" =~ ^[0-9]+$ ]]; then
        # Build same sort key as list_jobs to ensure index consistency
        local sort_lines=""
        for f in "$STORE"/*.meta; do
            [ -f "$f" ] || continue
            local fname; fname=$(basename "$f" .meta)
            [ -f "$STORE/${fname}.sh" ] || continue
            local m_type m_subtype m_schedule m_times m_target_fmt
            m_type=$(_read_meta "$f" META_TYPE)
            m_subtype=$(_read_meta "$f" META_SUBTYPE)
            m_schedule=$(_read_meta "$f" META_SCHEDULE)
            m_times=$(_read_meta "$f" META_TIMES)
            m_target_fmt=$(_read_meta "$f" META_TARGET_FMT)
            local type_display="${m_subtype:-${m_type:-once}}"
            local m_flags; m_flags=$(_read_meta "$f" META_FLAGS)
            [ -n "$m_flags" ] && type_display="${type_display} [!]"
            local sched_display
            if [ "${m_type:-once}" = "repeat" ]; then
                sched_display="${m_schedule} ${m_times}"
            else
                sched_display="${m_target_fmt}"
            fi
            sort_lines+="${type_display} | ${sched_display} | ${fname}"$'\n'
        done
        local target_fname
        target_fname=$(printf '%s' "$sort_lines" | sort | sed -n "${ref}p" | awk -F ' \\| ' '{print $3}' | tr -d '[:space:]')
        if [ -n "$target_fname" ]; then
            echo "$target_fname"
            return 0
        fi
        _err "$(_t "Error: no job at index" "Error: 해당 인덱스에 작업 없음") #$ref"
        return 1
    fi
    echo "$ref"
}

show_job() {
    local jid
    jid=$(_resolve_job_ref "$1") || exit 1

    local meta_file="$STORE/${jid}.meta"
    local prompt_file="$STORE/${jid}.prompt"

    if [ ! -f "$meta_file" ]; then
        _err "$(_t "Error: job not found" "Error: 작업을 찾을 수 없습니다"): ${jid}"
        return 1
    fi

    local META_TYPE="" META_MODE="" META_DIR="" META_SID="" META_FLAGS=""
    local META_TARGET_FMT="" META_TARGET_YMD=""
    local META_SCHEDULE="" META_TIMES="" META_WEEKDAYS=""
    local META_HEADLESS="" META_QUIET="" META_SUBTYPE=""
    _load_meta "$meta_file"

    echo "Job ID:    ${jid}"
    echo "Type:      ${META_TYPE:-once}"
    [ -n "$META_SUBTYPE" ] && echo "Subtype:   ${META_SUBTYPE}"
    echo "Mode:      ${META_MODE:-new}"
    echo "Directory: ${META_DIR}"
    [ -n "$META_SID" ] && echo "Session:   ${META_SID}"
    [ "$META_TYPE" = "once" ] && echo "Scheduled: ${META_TARGET_FMT}"
    [ "$META_TYPE" = "repeat" ] && echo "Schedule:  ${META_SCHEDULE} ${META_TIMES}"
    [ "$META_HEADLESS" = "yes" ] && echo "Headless:  yes"
    [ "$META_QUIET" = "yes" ] && echo "Quiet:     yes"
    [[ "${META_FLAGS:-}" == *"--dangerously-skip-permissions"* ]] && echo "Bypass:    yes"
    [ -n "$META_FLAGS" ] && echo "Flags:     ${META_FLAGS}"
    if [ -f "$prompt_file" ]; then
        local prompt_content
        prompt_content=$(<"$prompt_file")
        echo "Prompt:    ${prompt_content:0:200}"
    fi
    return 0
}

# ===================================================================
# Subcommand dispatcher
# ===================================================================

# --- Pre-process headless/quiet flags ---
_HEADLESS=''
_QUIET=''
_new_args=()
for _arg in "$@"; do
    case "$_arg" in
        -H|--headless) _HEADLESS='yes' ;;
        -q|--quiet)    _QUIET='yes' ;;
        *)             _new_args+=("$_arg") ;;
    esac
done
set -- ${_new_args[@]+"${_new_args[@]}"}

if [ "$_QUIET" = 'yes' ] && [ "$_HEADLESS" != 'yes' ]; then
    _err "$(_MSG_QUIET_REQUIRES_HEADLESS)"
    exit 1
fi

case "${1:-}" in
    # Internal
    _hook-auto-resume) _hook_auto_resume; exit $? ;;
    _test-settings-add)    [ -n "${CLAUDE_BRB_STORE:-}" ] || { _err "test-only command"; exit 1; }; _settings_json_add_hook "$2"; exit 0 ;;
    _test-settings-remove) [ -n "${CLAUDE_BRB_STORE:-}" ] || { _err "test-only command"; exit 1; }; _settings_json_remove_hook; exit 0 ;;

    # Core features
    auto-resume) shift; _auto_resume_cmd "${1:-status}"; exit 0 ;;
    keep-alive)  shift; _keep_alive_cmd "$@"; exit 0 ;;
    bypass-permissions) shift; _bypass_permissions_cmd "${1:-status}"; exit 0 ;;

    # Management
    list)       list_jobs; exit $? ;;
    show)       [ -z "${2:-}" ] && { _err "Usage: brb show <job-id|#index>"; exit 1; }; show_job "$2"; exit $? ;;
    cancel)     [ -z "${2:-}" ] && { _err "Usage: brb cancel <job-id|#index|all>"; exit 1; }; cancel_job "$(_resolve_job_ref "$2")"; exit $? ;;
    edit)       [ -z "${2:-}" ] && { _err "Usage: brb edit <job-id|#index> [prompt]"; exit 1; }; modify_job "$(_resolve_job_ref "$2")" "${3:-}"; exit $? ;;
    reschedule) [ -z "${2:-}" ] && { _err "Usage: brb reschedule <job-id|#index> <time>"; exit 1; }; retime_job "$(_resolve_job_ref "$2")" "${3:-}"; exit $? ;;

    # Settings
    setup)      _full_setup; exit 0 ;;
    teardown)   _teardown; exit 0 ;;
    upgrade)    upgrade_all_jobs ;;
    version|--version|-V) echo "claude-brb $VERSION"; exit 0 ;;
    help|--help|-h) show_help ;;

    # Scheduling
    at)    shift; _schedule_at "$@" ;;
    every) shift; _schedule_every "$@" ;;

    # No args = status summary
    '') _status_summary ;;

    # Backward compat: old flags
    -l|--list)    list_jobs; exit $? ;;
    -c|--cancel)  [ -z "${2:-}" ] && { _err "$(_t "Error: job-id required" "Error: Job ID가 필요합니다"): brb cancel <job-id>"; exit 1; }; cancel_job "$2"; exit $? ;;
    -m|--modify)  [ -z "${2:-}" ] && { _err "$(_t "Error: job-id required" "Error: Job ID가 필요합니다"): brb edit <job-id>"; exit 1; }; modify_job "$2" "${3:-}"; exit $? ;;
    -t|--time)    [ -z "${2:-}" ] && { _err "$(_t "Error: job-id required" "Error: Job ID가 필요합니다"): brb reschedule <job-id> <time>"; exit 1; }; retime_job "$2" "${3:-}"; exit $? ;;
    -u|--upgrade) upgrade_all_jobs ;;
    -S|--setup)   _setup_pmset_sudo; exit $? ;;
    -r|--repeat)  shift; _schedule_every "$@" ;;

    # Unknown
    *) _err "$(_t "Error: unknown command" "Error: 알 수 없는 명령"): $1"
       _err "$(_t "Run 'brb help' for usage" "'brb help'로 사용법 확인")"
       exit 1 ;;
esac
