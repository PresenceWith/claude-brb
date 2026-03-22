# claude-brb

Be right back with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Claude Code를 오래 쓰다 보면 세 가지 벽에 부딪힙니다:

1. **Rate limit** — 세션이 끊기고, 재개 가능 시간까지 기다려야 합니다
2. **5시간 타이머** — 사용 제한이 리셋되어 흐름이 끊깁니다
3. **Mac 잠자기** — 예약해둔 작업이 실행되지 않습니다

claude-brb는 Claude Code의 **hook 시스템에 직접 연결**됩니다.
세션이 끊기면 Claude Code가 직접 brb를 호출하고,
brb가 재개 시간을 계산해서 launchd로 예약합니다.
폴링도, 감시 프로세스도 없습니다. **이벤트 드리븐**입니다.

```bash
brew install PresenceWith/tap/claude-brb
brb setup   # hook 등록 + wake 설정 + keep-alive — 한 번이면 끝
```

이제 자기 전에 이렇게 하면:

```bash
brb at 03:00 "Write unit tests for the auth module"
```

아침에 결과를 확인할 수 있습니다.
Rate limit이 걸려도, Mac이 잠들어도, brb가 알아서 처리합니다.

## How It Works

```
Claude Code session
        │
        ├── rate limit hit
        │       │
        │       ▼
        │   StopFailure hook ──▶ brb _hook-auto-resume
        │                              │
        │                              ├── parse reset time
        │                              ├── schedule resume via launchd
        │                              └── pmset wake (if sleeping)
        │
        ├── 5h timer approaching
        │       │
        │       ▼
        │   keep-alive job ──▶ lightweight session reset
        │
        └── scheduled task
                │
                ▼
            launchd fires ──▶ pmset wake ──▶ open Terminal ──▶ claude --resume
```

`brb setup`이 하는 일:
- Claude Code `settings.json`에 **StopFailure hook** 등록
- passwordless **pmset** 설정 (Mac 잠자기 해제)
- **keep-alive** 반복 작업 등록 (5시간 타이머 리셋)

외부 데몬이 아닙니다. macOS 네이티브 launchd + Claude Code 네이티브 hook입니다.

## Install

```bash
brew install PresenceWith/tap/claude-brb
brb setup
```

<details>
<summary>Other methods</summary>

```bash
# User-local
git clone https://github.com/PresenceWith/claude-brb.git
cd claude-brb
make install-user && brb setup

# System-wide
sudo make install && brb setup
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

# 터미널 없이 백그라운드로
brb at +30m -H "Review PR"

# 매일 반복
brb every daily 09:00 "Check overnight changes"

# 평일만, 여러 시간에
brb every weekday 07:00,12:00,17:00 "Status check"

# 상태 확인
brb
```

## Core Features

### Auto-resume — Claude Code hook으로 동작

Claude Code의 StopFailure hook에 등록되어, rate limit으로 세션이 끊기는 순간 자동으로 트리거됩니다.
에러 메시지에서 재개 가능 시간을 파싱하고, 해당 시간에 세션을 재예약합니다.
30분 내 3회 이상 반복 중단되면 자동으로 멈춰서 무한 루프를 방지합니다.

```bash
brb auto-resume enable    # StopFailure hook 등록
brb auto-resume status    # 상태 + 최근 이력
brb auto-resume disable   # hook 제거
```

### Keep-alive — 5시간 타이머 리셋

Claude Code의 5시간 사용 제한 타이머가 리셋되지 않도록 주기적으로 경량 headless 세션을 실행합니다.

```bash
brb keep-alive enable                                  # 기본 간격
brb keep-alive enable 01:00,06:00,11:00,16:00,21:00    # 커스텀 시간
brb keep-alive disable
```

### Headless Mode — 터미널 없이 실행

터미널 창 없이 `claude -p`로 실행합니다. CI 스타일 배치 작업에 적합합니다.

```bash
brb at +30m -H "Analyze codebase and write report"
brb at +30m -H -q "Background task"    # 출력도 폐기
```

### Wake from Sleep — Mac을 깨워서 실행

예약 시간 2분 전에 `pmset`으로 Mac을 깨웁니다.
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
