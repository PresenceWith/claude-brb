# claude-brb

Be right back with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

A tool that automatically resumes Claude Code sessions interrupted by rate limits.
Set it up once and never worry about it again.

[한국어](README.ko.md)

## Why

When Claude Code hits a rate limit, the session stops.
You have to wait for the reset time, then manually restart — and if your Mac is asleep, you miss it entirely.

claude-brb automates this:

- **Auto-resume** — When a session is interrupted by a rate limit, Claude Code's [StopFailure hook](https://docs.anthropic.com/en/docs/claude-code/hooks) calls brb. It parses the reset time from the error message and schedules a resume via launchd. If the Mac is sleeping, `pmset` wakes it up.

- **Keep-alive** — Runs lightweight headless sessions roughly every 5 hours to keep your rate limit usage window favorable.

## Install & Setup

```bash
brew install PresenceWith/tap/claude-brb
brb setup

# Update to latest version
brew upgrade claude-brb
```

`brb setup` configures four things:
1. Sets up passwordless `pmset` (so it can wake from sleep)
2. Registers a StopFailure hook in Claude Code's `settings.json` (auto-resume)
3. Configures bypass-permissions for scheduled jobs
4. Registers the keep-alive recurring job

Each step asks Y/n, and you only need to do it once.

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

No background daemons — just native macOS launchd and Claude Code hooks.

When auto-resume restarts a session, Claude receives this prompt:

> *"You were interrupted by a rate limit. Review the conversation history and continue where you left off. Verify the current state before making changes. Do not repeat completed work."*

If the same session is interrupted 3+ times within 30 minutes, it automatically stops to prevent infinite loops.

## Session Scheduling

Beyond auto-resume and keep-alive, you can schedule Claude Code sessions for any time.

```bash
# Start in 30 minutes
brb at +30m "Refactor the database layer"

# At 3 AM, in a specific project
brb at 03:00 -d /path/to/project "Write integration tests"

# Resume a previous session
brb at +30m -s <session-id> "Continue where you left off"

# Headless (no terminal window)
brb at +30m -H "Review PR"

# Every day at 9 AM
brb every daily 09:00 "Check overnight changes"

# Weekdays only, three times a day
brb every weekday 07:00,12:00,17:00 "Status check"
```

### Wake from Sleep

`pmset` wakes the Mac 2 minutes before the scheduled time. Set up via `brb setup`.

| State | Wakes | Job runs |
|-------|-------|----------|
| Lid open, sleeping | Yes | Yes |
| Lid closed + external monitor | Yes | Yes |
| Lid closed, no monitor | Yes | **No** — can't open a terminal (use `-H` to work around) |

## Reference

```
brb auto-resume enable           enable auto-resume
brb auto-resume disable          disable
brb auto-resume status           status + recent history

brb keep-alive enable [times]    enable rate limit prevention
brb keep-alive disable           disable
brb keep-alive status            status

brb bypass-permissions enable    enable global bypass-permissions
brb bypass-permissions disable   disable
brb bypass-permissions status    status

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

**Global setting** — applies to all `at`/`every` jobs:

```bash
brb bypass-permissions enable
```

**Per-job flag:**

```bash
brb at +30m -B "task that needs full permissions"
brb every daily 09:00 -B "daily task"
```

**Environment variable** (legacy):

```bash
export CLAUDE_BRB_FLAGS="--dangerously-skip-permissions"
brb at +30m "task"
```

Auto-resume bypass-permissions is configured separately during `brb setup`.

> **Warning**: This disables all Claude Code permission checks. Scheduled jobs run unattended, so use with caution.

## Troubleshooting

**"operation not permitted" or Automation errors**
Go to System Settings > Privacy & Security > Automation and allow your terminal app to control Terminal.app (or iTerm2).

**Job didn't run because Mac was sleeping**
Run `brb setup` to configure passwordless `pmset`. Check `~/.claude-brb/<job-id>.runlog` for `warn: pmset wake failed`.

**Job ran later than scheduled**
Check `pmset -g sched` for a wake schedule. If missing, run `brb setup` then `brb upgrade` to regenerate scripts.

**"bootstrap failed" error**
A launchd agent may already be loaded. Clean up with `brb cancel <job-id>` and recreate.

## Uninstall

```bash
brb teardown                     # remove hook, keep-alive, sudoers
brb cancel all                   # cancel all one-time jobs
brb list                         # check for remaining recurring jobs
brb cancel <job-id>              # cancel individually

sudo make uninstall              # or: make uninstall-user
rm -rf ~/.claude-brb             # remove job data
```

## Requirements

- **macOS** (launchd, AppleScript, BSD date)
- **Claude Code CLI** (`claude` in PATH)
- **bash 3.2+** (included with macOS)
- **Terminal.app** or **iTerm2**

## License

MIT
