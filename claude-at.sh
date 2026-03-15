#!/bin/bash
# claude-at — schedule Claude Code CLI sessions via macOS launchd
set -euo pipefail
umask 077

VERSION="0.1.4"

# --- i18n: detect locale once, cache result ---
_lang_code="${CLAUDE_AT_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
[[ "$_lang_code" == ko* ]] && _LANG_KO=1 || _LANG_KO=0
_t() { if [ "$_LANG_KO" -eq 1 ]; then echo "$2"; else echo "$1"; fi; }
_err() { echo "$@" >&2; }

# --- macOS only ---
[[ "$(uname)" == "Darwin" ]] || { _err "$(_t "Error: macOS only" "Error: macOS 전용입니다")"; exit 1; }

# --- configuration ---
# Regex for safe path characters (used in validation functions)
_SAFE_PATH_RE='^[a-zA-Z0-9/_. -]+$'
STORE="${CLAUDE_AT_STORE:-$HOME/.claude-at}"
# Validate store path characters (prevent injection into generated scripts/plist)
if [[ ! "$STORE" =~ $_SAFE_PATH_RE ]]; then
    _err "$(_t "Error: CLAUDE_AT_STORE contains unsupported characters" "Error: CLAUDE_AT_STORE에 지원되지 않는 문자 포함"): $STORE"
    exit 1
fi
PLIST_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.claude-at"
CLAUDE_AT_TERMINAL="${CLAUDE_AT_TERMINAL:-Terminal}"
CLAUDE_AT_FLAGS="${CLAUDE_AT_FLAGS:-}"
CLAUDE_AT_MIN_INTERVAL="${CLAUDE_AT_MIN_INTERVAL:-120}"
if ! [[ "$CLAUDE_AT_MIN_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    CLAUDE_AT_MIN_INTERVAL=120
fi

# --- validate terminal (prevent AppleScript injection) ---
case "$CLAUDE_AT_TERMINAL" in
    Terminal|iTerm|iTerm2) ;;
    *) _err "$(_t "Error: unsupported terminal" "Error: 지원하지 않는 터미널"): $CLAUDE_AT_TERMINAL (Terminal, iTerm, iTerm2)"; exit 1 ;;
esac

show_help() {
    if [ "$_LANG_KO" -eq 1 ]; then
        cat <<'HELP'
claude-at, ca — 지정 시간에 claude 세션을 예약 (launchd 기반)

Usage:
  # 일회성 예약
  ca <time> 'prompt'                      # 현재 디렉터리에서 새 세션
  ca <time> <directory> 'prompt'          # 지정 디렉터리에서 새 세션
  ca <time> <session-id> 'prompt'         # 기존 세션 재개

  # 반복 예약
  ca -r <schedule> <time> 'prompt'              # 현재 디렉터리에서 반복
  ca -r <schedule> <time> <directory> 'prompt'  # 지정 디렉터리에서 반복

  # 관리
  ca --list                              # 예약 목록
  ca --cancel <job-id>                   # 예약 취소
  ca --cancel all                        # 일회성 예약 모두 취소
  ca --modify <job-id>                   # 프롬프트 수정 (에디터)
  ca --modify <job-id> 'new-prompt'      # 프롬프트 직접 변경
  ca --time <job-id> <time>              # 실행 시각 변경
  ca --upgrade                           # 기존 작업 업그레이드

Arguments:
  time            실행 시각 ( HH:MM | +Nm | +Nh | +Nd )
                  반복 시 쉼표로 여러 시각: 07:00,12:00,17:00
  schedule        반복 주기: daily, weekday, weekend, 또는 요일 (mon,wed,fri)
  session-id      claude 세션 ID (재개 시, 일회성만)
  directory       새 세션을 실행할 디렉터리 (절대경로, /로 시작)
  prompt          작업 지시

Schedule:
  daily           매일
  weekday         평일 (월-금)
  weekend         주말 (토-일)
  mon,tue,...     특정 요일 (sun,mon,tue,wed,thu,fri,sat)

Options:
  -r, --repeat    반복 예약
  -l, --list      예약 목록
  -c, --cancel    예약 취소
  -m, --modify    프롬프트 수정
  -t, --time      실행 시각 변경
  -u, --upgrade   기존 작업 업그레이드
  -S, --setup     pmset 잠자기 해제 권한 설정
  -V, --version   버전 표시
  -h, --help      도움말

Environment:
  CLAUDE_AT_TERMINAL   터미널 앱 (Terminal, iTerm2)     [기본: Terminal]
  CLAUDE_AT_FLAGS      claude CLI 추가 플래그           [기본: 없음]
  CLAUDE_AT_STORE      작업 저장 디렉터리               [기본: ~/.claude-at]
  CLAUDE_AT_LANG       표시 언어 (en, ko)               [기본: 자동 감지]

Note:
  잠자기 해제(pmset wake)는 덮개가 열려있거나 외부 모니터가 연결된
  상태에서만 정상 작동합니다. 덮개가 닫힌 채 외부 모니터 없이는
  하드웨어는 깨어나지만 터미널 창을 열 수 없어 실행이 실패합니다.

Examples:
  ca 03:00 "Write unit tests"                           # 현재 폴더에서 새 세션
  ca +30m /Users/dev/myapp "Refactor code"              # 지정 폴더에서 새 세션
  ca +3h abc-123-def "Continue analysis"                # 세션 재개
  ca +1d "Run weekly cleanup"                           # 1일 후 실행
  ca -r daily 07:00 "Check status"                      # 매일 7시
  ca -r weekday 09:00 "Standup summary"                 # 평일 9시
  ca -r mon,wed,fri 14:00 /Users/dev/app "Code review"  # 월수금 14시

Requires: bash 3.2+, zsh (interactive prompt editing)
HELP
    else
        cat <<'HELP'
claude-at, ca — schedule Claude Code sessions via macOS launchd

Usage:
  # One-time
  ca <time> 'prompt'                      # new session in current dir
  ca <time> <directory> 'prompt'          # new session in specified dir
  ca <time> <session-id> 'prompt'         # resume existing session

  # Recurring
  ca -r <schedule> <time> 'prompt'              # repeat in current dir
  ca -r <schedule> <time> <directory> 'prompt'  # repeat in specified dir

  # Management
  ca --list                              # list all jobs
  ca --cancel <job-id>                   # cancel a job
  ca --cancel all                        # cancel all one-time jobs
  ca --modify <job-id>                   # edit prompt (editor)
  ca --modify <job-id> 'new-prompt'      # change prompt directly
  ca --time <job-id> <time>              # reschedule
  ca --upgrade                           # upgrade existing jobs

Arguments:
  time            execution time ( HH:MM | +Nm | +Nh | +Nd )
                  multiple times for recurring: 07:00,12:00,17:00
  schedule        recurrence: daily, weekday, weekend, or days (mon,wed,fri)
  session-id      Claude session ID (resume only, one-time only)
  directory       working directory (absolute path, starts with /)
  prompt          task instruction

Schedule:
  daily           every day
  weekday         Mon-Fri
  weekend         Sat-Sun
  mon,tue,...     specific days (sun,mon,tue,wed,thu,fri,sat)

Options:
  -r, --repeat    recurring schedule
  -l, --list      list jobs
  -c, --cancel    cancel job
  -m, --modify    modify prompt
  -t, --time      change schedule time
  -u, --upgrade   upgrade existing jobs
  -S, --setup     configure pmset wake permissions
  -V, --version   show version
  -h, --help      show this help

Environment:
  CLAUDE_AT_TERMINAL   terminal app (Terminal, iTerm2)   [default: Terminal]
  CLAUDE_AT_FLAGS      extra flags for claude CLI        [default: none]
  CLAUDE_AT_STORE      job storage directory             [default: ~/.claude-at]
  CLAUDE_AT_LANG       display language (en, ko)         [default: auto-detect]

Note:
  Wake-from-sleep (pmset wake) requires the lid to be open or an external
  monitor connected. With the lid closed and no display, the hardware wakes
  but the terminal window cannot open, so the job will fail.

Examples:
  ca 03:00 "Write unit tests"                           # new session at 3am
  ca +30m /Users/dev/myapp "Refactor code"              # in 30 minutes
  ca +3h abc-123-def "Continue analysis"                # resume session
  ca +1d "Run weekly cleanup"                           # in 1 day
  ca -r daily 07:00 "Check status"                      # daily at 7am
  ca -r weekday 09:00 "Standup summary"                 # weekdays at 9am
  ca -r mon,wed,fri 14:00 /Users/dev/app "Code review"  # MWF at 2pm

Requires: bash 3.2+, zsh (interactive prompt editing)
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

# Validate CLAUDE_AT_FLAGS — reject shell metacharacters
validate_flags() {
    local flags="$1"
    [ -z "$flags" ] && return 0
    if [[ ! "$flags" =~ ^[a-zA-Z0-9\ _.=/-]+$ ]]; then
        _err "$(_t "Error: CLAUDE_AT_FLAGS contains unsafe characters" "Error: CLAUDE_AT_FLAGS에 안전하지 않은 문자 포함")"
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
# claude-at repeat job next-wake scheduler
STORE="${2:-$HOME/.claude-at}"
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
        echo "$(date '+%Y-%m-%d %H:%M:%S') warn: pmset wake failed (run 'ca --setup')" >> "$STORE/${JOB_ID}.runlog" 2>/dev/null
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

# Set up /etc/sudoers.d/claude-at for passwordless pmset (interactive)
_setup_pmset_sudo() {
    _can_pmset_sudo && return 0
    [ -t 0 ] || return 1

    local sudoers_file="/etc/sudoers.d/claude-at"
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
    _err "  ${user} ALL=(root) NOPASSWD: /usr/bin/pmset"
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

    local rule="${user} ALL=(root) NOPASSWD: /usr/bin/pmset"
    if printf '# claude-at: allow passwordless pmset for wake scheduling\n%s\n' "$rule" \
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
        _err "$(_t "Warning: pmset wake scheduling skipped (run 'ca --setup')" "경고: pmset wake 예약 생략 ('ca --setup' 실행 필요)")"
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
    printf '%s\n' 'osascript -e "display notification \"$_NOTIF\" with title \"claude-at\""'
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
        printf '%s\n' 'echo ""; date "+  %Y-%m-%d %H:%M:%S  claude-at"; echo ""'

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

    local safe_terminal="${CLAUDE_AT_TERMINAL}"
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
            printf '%s\n' "_MIN_INTERVAL=${CLAUDE_AT_MIN_INTERVAL}"
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
    printf "%-10s | %-22s | %-34s | %-24s | %s\n" "TYPE" "SCHEDULE" "JOB ID" "TARGET" "PROMPT"
    printf '%0.s-' {1..120}; echo
    local lines=""
    for f in "$STORE"/*.meta; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f" .meta)
        # Skip non-job files
        [ -f "$STORE/${fname}.sh" ] || continue
        found=true

        local m_type m_schedule m_times m_target_fmt m_dir m_sid m_flags
        m_type=$(_read_meta "$f" META_TYPE)
        m_schedule=$(_read_meta "$f" META_SCHEDULE)
        m_times=$(_read_meta "$f" META_TIMES)
        m_target_fmt=$(_read_meta "$f" META_TARGET_FMT)
        m_dir=$(_read_meta "$f" META_DIR)
        m_sid=$(_read_meta "$f" META_SID)
        m_flags=$(_read_meta "$f" META_FLAGS)

        local type_display sched_display target_display prompt_display
        type_display="${m_type:-once}"
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

        prompt_display=""
        [ -f "$STORE/${fname}.prompt" ] && prompt_display=$(head -1 "$STORE/${fname}.prompt" | cut -c1-50)

        lines+="${type_display} | ${sched_display} | ${fname} | ${target_display} | ${prompt_display}..."$'\n'
    done
    if $found; then
        echo "$lines" | sort | while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "$line" | awk -F ' \\| ' '{printf "%-10s | %-22s | %-34s | %-24s | %s\n", $1, $2, $3, $4, $5}'
        done
    else
        echo "$(_t "(no jobs)" "(예약 없음)")"
    fi
    echo ""
    echo "$(_t "Modify prompt:" "프롬프트 수정:") ca -m <JOB ID>"
    echo "$(_t "Change time: " "시간 변경:   ") ca -t <JOB ID> <TIME>"
    echo "$(_t "Cancel job:  " "예약 취소:   ") ca -c <JOB ID> | ca -c all"
    exit 0
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
        [ "$total_repeat" -gt 0 ] && echo "$(_t "${total_repeat} repeat job(s) kept (cancel individually: ca -c <JOB ID>)" "반복 예약 ${total_repeat}개는 유지됨 (개별 취소: ca -c <JOB ID>)")"
        exit 0
    fi

    # Interactive confirmation
    if [ -t 0 ]; then
        printf "$(_t "Cancel %d one-time job(s)? [y/N] " "%d개 일회성 예약을 취소할까요? [y/N] ")" "$total_once"
        local confirm
        read -r confirm
        case "$confirm" in
            y|Y|yes|YES) ;;
            *) echo "$(_t "Cancelled." "취소됨.")"; exit 0 ;;
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
    [ "$total_repeat" -gt 0 ] && echo "$(_t "${total_repeat} repeat job(s) kept (cancel individually: ca -c <JOB ID>)" "반복 예약 ${total_repeat}개는 유지됨 (개별 취소: ca -c <JOB ID>)")"
    $wake_fail && _err "$(_t "Warning: some pmset wake cancellations require admin privileges" "경고: 일부 pmset wake 취소에 관리자 권한이 필요합니다")"
    exit 0
}

# --- cancel individual job ---
cancel_job() {
    local jid="$1"
    [ "$jid" = "all" ] && cancel_all_jobs

    validate_job_id "$jid"
    local label="${LABEL_PREFIX}.${jid}"

    if [ ! -f "${PLIST_DIR}/${label}.plist" ] && [ ! -f "$STORE/${jid}.sh" ]; then
        _err "$(_t "Error: job not found (see 'ca -l')" "Error: 해당 Job ID를 찾을 수 없습니다 ('ca -l' 참조)"): ${jid}"
        exit 1
    fi

    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    rm -f "${PLIST_DIR}/${label}.plist"
    rm -f "$STORE/${jid}.sh"
    rm -f "$STORE/${jid}.exec.sh"
    rm -f "$STORE/${jid}.log"
    rm -f "$STORE/${jid}.runlog"
    rm -f "$STORE/${jid}.prompt"
    rm -f "$STORE/${jid}.meta"
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
    exit 0
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
        _err "$(_t "Error: job not found (see 'ca -l')" "Error: 해당 Job ID를 찾을 수 없습니다 ('ca -l' 참조)"): ${jid}"
        exit 1
    fi

    if [ ! -f "$meta_file" ] || [ ! -f "$prompt_file" ]; then
        _err "$(_t "Error: metadata missing. Run 'ca --upgrade' first." "Error: 메타데이터 파일이 없습니다. 'ca --upgrade'를 먼저 실행하세요.")"
        exit 1
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
            exit 1
        }
        if [ -z "$edited" ]; then
            _err "$(_t "Error: empty prompt not allowed" "Error: 빈 프롬프트는 허용되지 않습니다")"
            exit 1
        fi
        printf '%s' "$edited" | _atomic_write "$prompt_file"
    fi

    local PROMPT
    PROMPT=$(<"$prompt_file")

    if [ "$PROMPT" = "$old_prompt" ]; then
        echo "$(_t "No changes" "변경 사항 없음")"
        exit 0
    fi

    _generate_exec "$jid"
    _generate_runner "$jid"

    echo "$(_t "Prompt modified:" "프롬프트 수정 완료:") ${jid}"
    echo "$(_t "Old:" "이전:") ${old_prompt:0:80}"
    echo "$(_t "New:" "변경:") ${PROMPT:0:80}"
    exit 0
}

# --- reschedule job ---
retime_job() {
    local jid="$1"
    if [ -z "${2:-}" ]; then
        _err "$(_t "Error: time required (HH:MM, +30m, +2h, +1d)" "Error: 시간이 필요합니다 (HH:MM, +30m, +2h, +1d)")"
        exit 1
    fi
    local time_str="$2"

    validate_job_id "$jid"

    local meta_file="$STORE/${jid}.meta"
    local runner="$STORE/${jid}.sh"
    local label="${LABEL_PREFIX}.${jid}"
    local plist="${PLIST_DIR}/${label}.plist"

    if [ ! -f "$runner" ]; then
        _err "$(_t "Error: job not found (see 'ca -l')" "Error: 해당 Job ID를 찾을 수 없습니다 ('ca -l' 참조)"): ${jid}"
        exit 1
    fi

    if [ ! -f "$meta_file" ]; then
        _err "$(_t "Error: metadata missing. Run 'ca --upgrade' first." "Error: 메타데이터 파일이 없습니다. 'ca --upgrade'를 먼저 실행하세요.")"
        exit 1
    fi

    local META_TYPE="" META_MODE="" META_DIR="" META_SID="" META_FLAGS=""
    local META_TARGET_FMT="" META_TARGET_YMD=""
    local META_SCHEDULE="" META_TIMES="" META_WEEKDAYS=""
    _load_meta "$meta_file"
    local meta_type="${META_TYPE:-once}"

    # ========== repeat job reschedule ==========
    if [ "$meta_type" = "repeat" ]; then
        if [[ "$time_str" == +* ]]; then
            _err "$(_t "Error: repeat jobs cannot use relative time (+Nm, +Nh, +Nd). Use HH:MM format." "Error: 반복 작업은 상대 시간(+Nm, +Nh, +Nd) 사용 불가. HH:MM 형식을 사용하세요.")"
            _err "$(_t "Example:" "예:") ca -t ${jid} 08:00,13:00"
            exit 1
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
            exit 1
        fi

        _schedule_next_repeat_wake "$jid" "$weekdays" "$time_str"

        echo "$(_t "Rescheduled:" "시간 변경 완료:") ${META_SCHEDULE} ${old_times} → ${META_SCHEDULE} ${time_str} (Job ID: ${jid})"
        exit 0
    fi

    # ========== one-time job reschedule ==========
    local target
    target=$(_parse_time_to_epoch "$time_str") || exit 1

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
        exit 1
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
    exit 0
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

case "${1:-}" in
    -h|--help)    show_help ;;
    -V|--version) echo "claude-at $VERSION"; exit 0 ;;
    -l|--list)    list_jobs ;;
    -c|--cancel)  [ -z "${2:-}" ] && { _err "$(_t "Error: job-id required" "Error: Job ID가 필요합니다"): ca -c <job-id>"; exit 1; }; cancel_job "$2" ;;
    -m|--modify)  [ -z "${2:-}" ] && { _err "$(_t "Error: job-id required" "Error: Job ID가 필요합니다"): ca -m <job-id>"; exit 1; }; modify_job "$2" "${3:-}" ;;
    -t|--time)    [ -z "${2:-}" ] && { _err "$(_t "Error: job-id required" "Error: Job ID가 필요합니다"): ca -t <job-id> <time>"; exit 1; }; retime_job "$2" "${3:-}" ;;
    -u|--upgrade) upgrade_all_jobs ;;
    -S|--setup)   _setup_pmset_sudo; exit $? ;;
    -r|--repeat)  ;;  # handled below in repeat mode
    -*)
        _err "$(_t "Error: unknown option" "Error: 알 수 없는 옵션"): $1"
        _err "$(_t "Help:" "도움말:") ca --help"
        exit 1
        ;;
esac

mkdir -p "$STORE"
# Ensure store directory has correct permissions
[ -d "$STORE" ] && chmod 700 "$STORE" 2>/dev/null || true

# Verify store directory ownership when using a custom path
if [ -n "${CLAUDE_AT_STORE:-}" ] && [ "$(stat -f '%u' "$STORE")" != "$(id -u)" ]; then
    _err "$(_t "Error: store directory must be owned by current user" "Error: 저장 디렉터리는 현재 사용자 소유여야 합니다"): $STORE"
    exit 1
fi

# Validate CLAUDE_AT_FLAGS
validate_flags "$CLAUDE_AT_FLAGS"

# Check claude CLI availability
_check_claude

# ========== Repeat scheduling mode (-r / --repeat) ==========
if [ "${1:-}" = "-r" ] || [ "${1:-}" = "--repeat" ]; then
    shift
    [ $# -lt 3 ] && { _err "$(_t "Error: usage: ca -r <schedule> <time> [directory] 'prompt'" "Error: 사용법: ca -r <schedule> <time> [directory] 'prompt'")"; exit 1; }

    RPT_SCHEDULE="$1"; shift
    RPT_TIMES="$1"; shift

    RPT_WEEKDAYS=$(expand_schedule "$RPT_SCHEDULE") || exit 1
    validate_times "$RPT_TIMES"

    if [ $# -ge 2 ] && [[ "$1" == /* ]]; then
        RPT_DIR="$1"; shift
        RPT_PROMPT="$1"
    else
        RPT_DIR="$(pwd)"
        [ -z "${1:-}" ] && { _err "$(_t "Error: prompt required" "Error: 프롬프트가 필요합니다")"; exit 1; }
        RPT_PROMPT="$1"
    fi

    validate_dir_path "$RPT_DIR"

    [ ! -d "$RPT_DIR" ] && { _err "$(_t "Error: directory not found" "Error: 디렉터리를 찾을 수 없습니다"): $RPT_DIR"; exit 1; }
    RPT_DIR=$(cd "$RPT_DIR" && pwd)
    validate_dir_path "$RPT_DIR"

    RPT_SCHED_ID="${RPT_SCHEDULE//,/-}"
    JOB_ID=$(_make_job_id "rpt.${RPT_SCHED_ID}")

    # Save prompt & metadata
    printf '%s' "$RPT_PROMPT" | _atomic_write "$STORE/${JOB_ID}.prompt"
    {
        printf "META_TYPE='repeat'\n"
        printf "META_MODE='new'\n"
        printf "META_DIR='%s'\n" "$RPT_DIR"
        printf "META_SID=''\n"
        printf "META_FLAGS='%s'\n" "$CLAUDE_AT_FLAGS"
        printf "META_SCHEDULE='%s'\n" "$RPT_SCHEDULE"
        printf "META_TIMES='%s'\n" "$RPT_TIMES"
        printf "META_WEEKDAYS='%s'\n" "$RPT_WEEKDAYS"
    } | _atomic_write "$STORE/${JOB_ID}.meta"

    # Show warning if flags are set
    [ -n "$CLAUDE_AT_FLAGS" ] && _err "$(_t "WARNING: This job will run with:" "경고: 이 작업은 다음 플래그로 실행됩니다:") $CLAUDE_AT_FLAGS"

    _ensure_wake_helper

    _generate_exec "$JOB_ID"
    _generate_runner "$JOB_ID"

    label="${LABEL_PREFIX}.${JOB_ID}"
    runner="$STORE/${JOB_ID}.sh"
    mkdir -p "$PLIST_DIR"
    _write_plist_repeat "$label" "$runner" "$JOB_ID" "$RPT_WEEKDAYS" "$RPT_TIMES"

    if ! launchctl bootstrap "gui/$(id -u)" "${PLIST_DIR}/${label}.plist"; then
        _err "$(_t "Error: launchctl bootstrap failed. Try: ca -c ${JOB_ID}" "Error: launchctl bootstrap 실패. 시도: ca -c ${JOB_ID}")"
        exit 1
    fi

    _schedule_next_repeat_wake "$JOB_ID" "$RPT_WEEKDAYS" "$RPT_TIMES"

    echo "$(_t "Mode: repeat" "모드: 반복") (${RPT_DIR})"
    echo "$(_t "Scheduled:" "반복 예약 완료:") ${RPT_SCHEDULE} ${RPT_TIMES} (Job ID: ${JOB_ID})"
    echo "$(_t "Check:" "확인:") ca -l"
    exit 0
fi

# ========== One-time scheduling mode ==========
[ $# -lt 2 ] && show_help

TIME_STR="$1"
SID=""
_AMBIGUOUS_RESUME=false

# --- Mode detection ---
if [ $# -ge 3 ]; then
    if [[ "$2" == /* ]]; then
        MODE="new"
        DIR="$2"
        PROMPT="$3"
    else
        MODE="resume"
        SID="$2"
        PROMPT="$3"
    fi
else
    arg2="$2"
    if [[ "$arg2" == /* ]]; then
        MODE="new"
        DIR="$(pwd)"
        PROMPT="$arg2"
    elif [[ "$arg2" =~ ^[a-zA-Z0-9_.-]+$ ]] && resolve_session_dir "$arg2" >/dev/null 2>&1; then
        _AMBIGUOUS_RESUME=true
        if [ -t 0 ]; then
            printf "$(_t "Session '%s' found. Resume it? [y/N] (N = use as prompt) " "세션 '%s'을 찾았습니다. 재개할까요? [y/N] (N = 프롬프트로 사용) ")" "$arg2"
            _confirm=""
            read -r _confirm
            case "$_confirm" in
                y|Y|yes|YES)
                    MODE="resume"
                    SID="$arg2"
                    PROMPT=""
                    ;;
                *)
                    MODE="new"
                    DIR="$(pwd)"
                    PROMPT="$arg2"
                    _AMBIGUOUS_RESUME=false
                    ;;
            esac
        else
            MODE="new"
            DIR="$(pwd)"
            PROMPT="$arg2"
            _AMBIGUOUS_RESUME=false
        fi
    else
        MODE="new"
        DIR="$(pwd)"
        PROMPT="$arg2"
    fi
fi

# --- Mode-specific validation ---
if [ "$MODE" = "new" ]; then
    validate_dir_path "$DIR"
    [ ! -d "$DIR" ] && { _err "$(_t "Error: directory not found" "Error: 디렉터리를 찾을 수 없습니다"): $DIR"; exit 1; }
    DIR=$(cd "$DIR" && pwd)
    validate_dir_path "$DIR"
    echo "$(_t "Mode: new session" "모드: 새 세션") (${DIR})"
    id_prefix="new"
else
    validate_job_id "$SID"
    DIR=$(resolve_session_dir "$SID") || {
        _err "$(_t "Error: cannot find project directory for session" "Error: 세션의 프로젝트 디렉터리를 찾을 수 없습니다") '${SID}'"
        exit 1
    }
    validate_dir_path "$DIR"
    echo "$(_t "Mode: resume session" "모드: 세션 재개") (${SID})"
    id_prefix="res"
fi

JOB_ID=$(_make_job_id "$id_prefix")

# --- Calculate target time ---
target=$(_parse_time_to_epoch "$TIME_STR") || exit 1

target_fmt=$(date -r "$target" '+%m/%d %H:%M')
target_min=$((10#$(date -r "$target" +%M)))
target_hour=$((10#$(date -r "$target" +%H)))
target_day=$((10#$(date -r "$target" +%d)))
target_month=$((10#$(date -r "$target" +%m)))
target_ymd=$(date -r "$target" +%Y%m%d)

# --- Save prompt & metadata ---
printf '%s' "$PROMPT" | _atomic_write "$STORE/${JOB_ID}.prompt"
{
    printf "META_TYPE='once'\n"
    printf "META_MODE='%s'\n" "$MODE"
    printf "META_DIR='%s'\n" "$DIR"
    printf "META_SID='%s'\n" "${SID:-}"
    printf "META_FLAGS='%s'\n" "$CLAUDE_AT_FLAGS"
    printf "META_TARGET_FMT='%s'\n" "$target_fmt"
    printf "META_TARGET_YMD='%s'\n" "$target_ymd"
    printf "META_SCHEDULE=''\n"
    printf "META_TIMES=''\n"
    printf "META_WEEKDAYS=''\n"
} | _atomic_write "$STORE/${JOB_ID}.meta"

# Show warning if flags are set
[ -n "$CLAUDE_AT_FLAGS" ] && _err "$(_t "WARNING: This job will run with:" "경고: 이 작업은 다음 플래그로 실행됩니다:") $CLAUDE_AT_FLAGS"

# --- Generate scripts ---
_generate_exec "$JOB_ID"
_generate_runner "$JOB_ID"

# --- Register LaunchAgent ---
label="${LABEL_PREFIX}.${JOB_ID}"
runner="$STORE/${JOB_ID}.sh"
mkdir -p "$PLIST_DIR"
_write_plist_once "$label" "$runner" "$JOB_ID" "$target_month" "$target_day" "$target_hour" "$target_min"

if ! launchctl bootstrap "gui/$(id -u)" "${PLIST_DIR}/${label}.plist"; then
    _err "$(_t "Error: launchctl bootstrap failed. Try: ca -c ${JOB_ID}" "Error: launchctl bootstrap 실패. 시도: ca -c ${JOB_ID}")"
    exit 1
fi

# --- Schedule pmset wake ---
wake_ts=$((target - 120))
wake_fmt=$(date -r "$wake_ts" '+%m/%d/%Y %H:%M:%S')
_try_schedule_wake "$wake_fmt" "$STORE/.wake-${JOB_ID}"

echo "$(_t "Scheduled:" "예약 완료:") ${target_fmt} (Job ID: ${JOB_ID})"
echo "$(_t "Check:" "확인:") ca -l"
