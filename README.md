# claude-brb

Be right back with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Claude Code는 훌륭하지만, 혼자 두면 멈춥니다.
Rate limit이 걸리면 세션이 끊기고, 5시간이 지나면 타이머가 리셋되고,
Mac이 잠들면 예약해둔 작업이 실행되지 않습니다.

**claude-brb**는 이 세 가지 문제를 해결합니다:

```bash
brb setup  # 한 번만 실행하면 끝
```

- **Rate limit** → 자동으로 재개 시간을 계산해서 재예약
- **5시간 타이머** → 주기적으로 리셋해서 끊김 방지
- **Mac 잠자기** → pmset으로 깨워서 예약 작업 실행

자기 전에 작업을 예약하면, 아침에 결과를 확인할 수 있습니다:

```bash
brb at 03:00 "Write unit tests for the auth module"
```

## Install

```bash
brew install PresenceWith/tap/claude-brb
brb setup
```

<details>
<summary>Other methods</summary>

### User-local

```bash
git clone https://github.com/PresenceWith/claude-brb.git
cd claude-brb
make install-user    # ~/.local/bin/claude-brb + brb symlink
brb setup
```

### System-wide

```bash
sudo make install    # /usr/local/bin/claude-brb + brb symlink
brb setup
```

</details>

## Quick Start

```bash
# 30분 후에 세션 시작
brb at +30m "Refactor the database layer"

# 특정 시간에, 특정 디렉터리에서
brb at 03:00 -d /path/to/project "Write integration tests"

# 이전 세션 이어서
brb at +30m -s <session-id> "Continue where you left off"

# 터미널 없이 백그라운드로 (headless)
brb at +30m -H "Review PR"

# 매일 반복
brb every daily 09:00 "Check overnight changes"

# 평일만, 여러 시간에
brb every weekday 07:00,12:00,17:00 "Status check"

# 상태 확인
brb
```

## Core Features

### Auto-resume

Rate limit으로 세션이 끊기면, 재개 가능 시간을 파싱해서 자동으로 재예약합니다.
30분 내 3회 이상 반복 중단되면 자동으로 멈춰서 무한 루프를 방지합니다.

```bash
brb auto-resume enable    # 활성화
brb auto-resume status    # 상태 + 최근 이력
brb auto-resume disable   # 비활성화
```

### Keep-alive

Claude Code의 5시간 사용 타이머가 리셋되지 않도록 주기적으로 경량 세션을 실행합니다.

```bash
brb keep-alive enable              # 기본 간격으로 활성화
brb keep-alive enable 01:00,06:00,11:00,16:00,21:00   # 커스텀 시간
brb keep-alive disable
```

### Headless Mode

터미널 창 없이 백그라운드에서 실행합니다. CI 스타일 작업에 적합합니다.

```bash
brb at +30m -H "Analyze codebase and write report"
brb at +30m -H -q "Background task"    # 출력도 폐기
```

### Wake from Sleep

Mac이 잠들어 있어도 예약 시간 2분 전에 깨워서 작업을 실행합니다.
`brb setup`으로 한 번 설정하면 이후 자동으로 동작합니다.

| 상태 | 깨움 | 작업 실행 |
|------|------|-----------|
| 덮개 열림, 잠자기 | O | O |
| 덮개 닫힘 + 외부 모니터 | O | O |
| 덮개 닫힘, 모니터 없음 | O | **X** — 터미널을 열 수 없음 |

## Usage Reference

```
claude-brb, brb — be right back with Claude Code

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
brb at <time> -H -q "prompt"              headless, discard output

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
```

### Time Formats

| Format | Example | Description |
|--------|---------|-------------|
| `HH:MM` | `03:00` | Absolute time (next occurrence) |
| `+Nm` | `+30m` | N minutes from now |
| `+Nh` | `+2h` | N hours from now |
| `+Nd` | `+1d` | N days from now |
| `HH:MM,HH:MM` | `07:00,12:00,17:00` | Multiple times (recurring only) |

### Schedule Types

| Schedule | Description |
|----------|-------------|
| `daily` | Every day |
| `weekday` | Monday through Friday |
| `weekend` | Saturday and Sunday |
| `mon,wed,fri` | Specific days |

### Flags

| Flag | Description |
|------|-------------|
| `-d <dir>` | Working directory (absolute path) |
| `-s <sid>` | Resume session (one-time only) |
| `-H` | Headless mode (no terminal window) |
| `-q` | Discard output (use with `-H`) |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_BRB_TERMINAL` | `Terminal` | Terminal app (`Terminal` or `iTerm2`) |
| `CLAUDE_BRB_FLAGS` | *(empty)* | Extra flags passed to `claude` CLI |
| `CLAUDE_BRB_STORE` | `~/.claude-brb` | Job storage directory |
| `CLAUDE_BRB_LANG` | *(auto-detect)* | Display language (`en` or `ko`) |
| `CLAUDE_BRB_MIN_INTERVAL` | `120` | Minimum interval (seconds) between repeat job runs |
| `CLAUDE_BRB_RESUME_PROMPT` | *(built-in)* | Custom auto-resume prompt |
| `CLAUDE_BRB_RESUME_BUFFER_SECS` | `300` | Buffer after reset time (seconds) |

### `--dangerously-skip-permissions`

```bash
export CLAUDE_BRB_FLAGS="--dangerously-skip-permissions"
brb at +30m "task that needs full permissions"
```

> **Warning**: This flag disables all permission checks in Claude Code. Scheduled sessions run unattended — use with caution.

## Requirements

- **macOS** (uses launchd, AppleScript, BSD date)
- **Claude Code CLI** (`claude` command in PATH)
- **bash 3.2+** (ships with macOS)
- **Terminal.app** or **iTerm2**

## How It Works

1. Creates a **launchd** user agent (plist in `~/Library/LaunchAgents/`) with `StartCalendarInterval`
2. At the scheduled time, launchd runs a **runner script** that:
   - Schedules the next `pmset wake` (recurring jobs)
   - Guards against duplicate runs within the minimum interval
   - Wakes the display with `caffeinate -u`
   - Displays a macOS notification
   - Opens Terminal.app (or iTerm2) via AppleScript
   - Runs an **exec script** inside the terminal that starts Claude Code with `caffeinate -i`
3. For one-time jobs, the exec script cleans up all files after execution
4. For recurring jobs, a `_next_wake.sh` helper calculates and registers the next wake time

## Uninstall

```bash
brb teardown                     # remove hooks, keep-alive, sudoers
brb cancel all                   # cancel one-time jobs
brb list                         # check for remaining recurring jobs
brb cancel <job-id>              # cancel individually

sudo make uninstall              # or: make uninstall-user
rm -rf ~/.claude-brb             # remove job data
```

## Troubleshooting

**"operation not permitted" or automation error on first run**
macOS requires Automation permission. Go to System Settings > Privacy & Security > Automation and allow your terminal to control Terminal.app (or iTerm2).

**Job didn't run (machine was asleep)**
Run `brb setup` to configure passwordless `pmset` access. Check `~/.claude-brb/<job-id>.runlog` for `warn: pmset wake failed` entries.

**Job ran late**
Check if `pmset wake` was scheduled: `pmset -g sched`. If no wake entry exists, run `brb setup` and then `brb upgrade` to regenerate scripts.

**"bootstrap failed" when creating a job**
The launchd agent may already be loaded. Run `brb cancel <job-id>` to clean up, then recreate.

## License

MIT
