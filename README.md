# claude-brb

Be right back with Claude Code — schedule CLI sessions on macOS using launchd.

- One-time or recurring schedules (daily, weekday, weekend, specific days)
- Auto-resume on rate limits, keep-alive for 5-hour timer resets
- Headless mode for background tasks (no terminal window)
- Wake-from-sleep support via `pmset`
- Session resumption by session ID
- Bilingual output (English / Korean, auto-detected)

## Requirements

- **macOS** (uses launchd, AppleScript, BSD date)
- **Claude Code CLI** (`claude` command in PATH)
- **bash 3.2+** (ships with macOS)
- **Terminal.app** or **iTerm2**

## Installation

### Homebrew (Recommended)

```bash
brew install PresenceWith/tap/claude-brb
```

This installs `claude-brb` and `brb` (symlink) to your Homebrew prefix.

### User-local

```bash
git clone https://github.com/PresenceWith/claude-brb.git
cd claude-brb
make install-user
```

This installs to `~/.local/bin/claude-brb` with a `brb` symlink. Make sure `~/.local/bin` is in your `PATH`.

### System-wide

```bash
sudo make install
```

Installs to `/usr/local/bin/claude-brb` with a `brb` symlink.

## Setup

```bash
brb setup
```

Interactive setup that configures:
1. **Wake-from-sleep** — passwordless `pmset` access (`/etc/sudoers.d/claude-brb`)
2. **Auto-resume** — automatically reschedules sessions after rate limits
3. **Keep-alive** — resets the 5-hour usage timer periodically

## Quick Start

```bash
# One-time session in 30 minutes
brb at +30m "Write unit tests for the auth module"

# At a specific time, in a specific directory
brb at 03:00 -d /path/to/project "Refactor the database layer"

# Resume an existing session
brb at +30m -s <session-id> "Continue where you left off"

# Headless (no terminal window, runs in background)
brb at +30m -H "Review PR"

# Recurring: every weekday at 9am
brb every weekday 09:00 "Review overnight changes"

# Recurring: daily at multiple times
brb every daily 07:00,12:00,17:00 "Check status"

# List all jobs
brb list

# Status summary
brb
```

## Usage

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
| `+Nm` | `+30m` | Relative: N minutes from now |
| `+Nh` | `+2h` | Relative: N hours from now |
| `+Nd` | `+1d` | Relative: N days from now |
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

### Running with `--dangerously-skip-permissions`

```bash
export CLAUDE_BRB_FLAGS="--dangerously-skip-permissions"
brb at +30m "task that needs full permissions"
```

> **Warning**: This flag disables all permission checks in Claude Code. Scheduled sessions run unattended — use with caution.

### Wake from Sleep

`brb setup` configures passwordless `pmset` access. When a job is created, `claude-brb` schedules a `pmset wake` 2 minutes before the target time. For recurring jobs, each run automatically schedules the next wake.

| State | Wake | Job runs |
|-------|------|----------|
| Lid open, asleep | Yes | Yes |
| Lid closed + external monitor + power | Yes | Yes |
| Lid closed, no external monitor | Yes | **No** — terminal cannot open |

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

## Upgrading

After updating `claude-brb`, run `brb upgrade` to regenerate runner scripts for existing jobs.

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
Run `brb setup` to configure passwordless `pmset` access. Check `~/.claude-brb/<job-id>.runlog` for `warn: pmset wake failed` entries. The lid must be open or an external monitor connected.

**Job ran late**
Check if `pmset wake` was scheduled: `pmset -g sched`. If no wake entry exists, run `brb setup` and then `brb upgrade` to regenerate scripts.

**"bootstrap failed" when creating a job**
The launchd agent may already be loaded. Run `brb cancel <job-id>` to clean up, then recreate.

**Jobs from older versions can't be modified**
Run `brb upgrade` to add missing metadata fields and regenerate scripts.

## License

MIT
