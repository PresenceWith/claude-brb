# claude-brb

Be right back with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Rate limit 때문에 끊긴 Claude Code 세션을 자동으로 다시 이어주는 도구입니다.
한 번 설정하면 이후로는 신경 쓸 필요 없습니다.

## 왜 필요한가

Claude Code는 rate limit에 걸리면 세션이 멈춥니다.
재개 가능 시간까지 기다렸다가 수동으로 다시 시작해야 하고,
Mac이 잠들어 있으면 그마저도 놓칩니다.

claude-brb는 이 과정을 자동화합니다:

- **Auto-resume** — rate limit으로 세션이 끊기면 Claude Code의 [StopFailure hook](https://docs.anthropic.com/en/docs/claude-code/hooks)이 brb를 호출합니다. 에러 메시지에서 재개 시간을 파싱하고, 그 시간에 launchd로 세션을 다시 예약합니다. Mac이 자고 있으면 `pmset`으로 깨워서 실행합니다.

- **Keep-alive** — 약 5시간 간격으로 가벼운 headless 세션을 돌려서 rate limit 사용량 윈도를 유리하게 유지합니다.

## Install & Setup

```bash
brew install PresenceWith/tap/claude-brb
brb setup

# 최신 버전으로 업데이트
brew upgrade claude-brb
```

`brb setup`은 네 가지를 설정합니다:
1. passwordless `pmset` 설정 (잠자기 상태에서도 깨울 수 있게)
2. Claude Code `settings.json`에 StopFailure hook 등록 (auto-resume)
3. 예약 작업 bypass-permissions 설정
4. keep-alive 반복 작업 등록

각 단계마다 Y/n으로 물어보고, 한 번이면 끝입니다.

```
$ brb
claude-brb 0.3.4

auto-resume: enabled (bypass-permissions: on)
bypass-permissions: disabled
keep-alive:  enabled (00:01,05:02,10:03,15:04,20:05)

Scheduled jobs: 0 jobs
```

<details>
<summary>Other install methods</summary>

```bash
# User-local
git clone https://github.com/PresenceWith/claude-brb.git
cd claude-brb
make install-user && brb setup

# System-wide
sudo make install && brb setup
```

</details>

## How It Works

```
Claude Code session
        │
        ├── rate limit hit
        │       │
        │       ▼
        │   StopFailure hook ──▶ brb _hook-auto-resume
        │                              │
        │                              ├── parse reset time from error
        │                              ├── schedule resume via launchd
        │                              └── pmset wake (if sleeping)
        │
        ├── rate limit prevention
        │       │
        │       ▼
        │   keep-alive job ──▶ periodic lightweight session
        │
        └── scheduled task
                │
                ▼
            launchd fires ──▶ pmset wake ──▶ claude --resume
```

별도 데몬 없이 macOS 네이티브 launchd와 Claude Code hook만 씁니다.

Auto-resume으로 세션이 재개되면 Claude에게 이런 프롬프트가 전달됩니다:

> *"You were interrupted by a rate limit. Review the conversation history and continue where you left off. Verify the current state before making changes. Do not repeat completed work."*

같은 세션이 30분 안에 3번 이상 끊기면 무한 루프 방지를 위해 자동으로 멈춥니다.

## Session Scheduling

auto-resume과 keep-alive 외에, 원하는 시간에 Claude Code 세션을 예약할 수도 있습니다.

```bash
# 30분 뒤에 시작
brb at +30m "Refactor the database layer"

# 새벽 3시에, 특정 프로젝트에서
brb at 03:00 -d /path/to/project "Write integration tests"

# 이전 세션 이어서 하기
brb at +30m -s <session-id> "Continue where you left off"

# 터미널 없이 백그라운드 실행 (headless)
brb at +30m -H "Review PR"

# 매일 아침 9시에
brb every daily 09:00 "Check overnight changes"

# 평일만, 하루 세 번
brb every weekday 07:00,12:00,17:00 "Status check"
```

### Wake from Sleep

예약 시간 2분 전에 `pmset`으로 Mac을 깨웁니다. `brb setup`에서 설정합니다.

| 상태 | 깨움 | 작업 실행 |
|------|------|-----------|
| 덮개 열림, 잠자기 | O | O |
| 덮개 닫힘 + 외부 모니터 | O | O |
| 덮개 닫힘, 모니터 없음 | O | **X** — 터미널을 열 수 없음 (`-H`로 우회 가능) |

## Reference

```
brb auto-resume enable           enable auto-resume
brb auto-resume disable          disable
brb auto-resume status           status + recent history

brb keep-alive enable [times]    enable rate limit prevention
brb keep-alive disable           disable
brb keep-alive status            status

brb bypass-permissions enable    글로벌 bypass-permissions 활성화
brb bypass-permissions disable   비활성화
brb bypass-permissions status    상태

brb at <time> "prompt"                    new session in current dir
brb at <time> -d <dir> "prompt"           in specified dir
brb at <time> -s <session-id> "prompt"    resume session
brb at <time> -H "prompt"                 headless mode
brb at <time> -H -q "prompt"              headless, discard output

brb every <schedule> <time> "prompt"
brb every <schedule> <time> -d <dir> "prompt"
brb every <schedule> <time> -H -q "prompt"

brb list                         list jobs (with index numbers)
brb show <id|#index>             job details
brb cancel <id|#index|all>       cancel
brb edit <id|#index> ["prompt"]  modify prompt
brb reschedule <id|#index> <time>  change time

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
| `-B` | Bypass permissions (`--dangerously-skip-permissions`) |

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

**글로벌 설정** — 모든 `at`/`every` 작업에 적용:

```bash
brb bypass-permissions enable
```

**개별 작업 플래그:**

```bash
brb at +30m -B "권한이 필요한 작업"
brb every daily 09:00 -B "매일 작업"
```

**환경변수** (레거시):

```bash
export CLAUDE_BRB_FLAGS="--dangerously-skip-permissions"
brb at +30m "작업"
```

Auto-resume bypass-permissions는 `brb setup`에서 별도로 설정합니다.

> **Warning**: Claude Code의 모든 권한 검사를 끕니다. 예약 작업은 사람 없이 돌아가므로 주의해서 쓰세요.

## Troubleshooting

**"operation not permitted" 또는 Automation 오류**
System Settings > Privacy & Security > Automation에서 터미널 앱이 Terminal.app(또는 iTerm2)을 제어할 수 있도록 허용해 주세요.

**Mac이 자고 있어서 작업이 안 돌았을 때**
`brb setup`으로 passwordless `pmset`을 설정하세요. `~/.claude-brb/<job-id>.runlog`에서 `warn: pmset wake failed`를 확인해 보세요.

**작업이 예정보다 늦게 돌았을 때**
`pmset -g sched`로 wake 스케줄이 잡혀 있는지 확인하세요. 없으면 `brb setup` 후 `brb upgrade`로 스크립트를 재생성하세요.

**"bootstrap failed" 에러**
이미 로드된 launchd agent가 있을 수 있습니다. `brb cancel <job-id>`로 정리한 뒤 다시 만드세요.

## Uninstall

```bash
brb teardown                     # hook, keep-alive, sudoers 제거
brb cancel all                   # 일회성 작업 전부 취소
brb list                         # 반복 작업이 남아있는지 확인
brb cancel <job-id>              # 남은 것 개별 취소

sudo make uninstall              # 또는 make uninstall-user
rm -rf ~/.claude-brb             # 작업 데이터 삭제
```

## Requirements

- **macOS** (launchd, AppleScript, BSD date)
- **Claude Code CLI** (`claude` in PATH)
- **bash 3.2+** (macOS 기본 포함)
- **Terminal.app** 또는 **iTerm2**

## License

MIT
