# claude-at

Schedule [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI sessions on macOS using launchd.

- One-time or recurring schedules (daily, weekday, weekend, specific days)
- Opens a Terminal window (or iTerm2) and runs Claude Code at the scheduled time
- Wake-from-sleep support via `pmset` with automatic sudoers setup
- Session resumption by session ID
- Bilingual output (English / Korean, auto-detected)

## Requirements

- **macOS** (uses launchd, AppleScript, BSD date)
- **Claude Code CLI** (`claude` command in PATH)
- **bash 3.2+** (ships with macOS)
- **zsh** (ships with macOS; used for interactive prompt editing via `ca -m`)
- **Terminal.app** or **iTerm2**

## Installation

### Recommended (user-local)

```bash
git clone https://github.com/presence-me/claude-at.git
cd claude-at
make install-user
```

This installs to `~/.local/bin/claude-at` with a `ca` symlink. Make sure `~/.local/bin` is in your `PATH`.

### System-wide

```bash
sudo make install
```

Installs to `/usr/local/bin/claude-at` with a `ca` symlink.

### Manual

```bash
alias ca="/path/to/claude-at.sh"
```

### Post-install: Wake-from-sleep setup

To ensure scheduled jobs run even when the Mac is asleep, configure passwordless `pmset` access:

```bash
ca --setup
```

This creates `/etc/sudoers.d/claude-at` granting your user passwordless access to `/usr/bin/pmset` only. Without this, jobs that fire while the Mac is asleep will be delayed until the next wake.

> **Note**: Wake-from-sleep requires the **lid to be open** or an **external monitor connected**. With the lid closed and no display attached, the hardware wakes but the terminal window cannot open, so the job will fail.

## Quick Start

```bash
# Schedule a session in 30 minutes
ca +30m "Write unit tests for the auth module"

# Schedule at a specific time
ca 03:00 /path/to/project "Refactor the database layer"

# Schedule in 1 day
ca +1d "Run weekly cleanup"

# Recurring: every weekday at 9am
ca -r weekday 09:00 "Review overnight changes"

# Recurring: daily at multiple times
ca -r daily 07:00,12:00,17:00,22:00 "Check status"

# List all jobs
ca -l
```

## Usage

```
claude-at, ca — schedule Claude Code sessions via macOS launchd

# One-time
ca <time> 'prompt'                      # new session in current dir
ca <time> <directory> 'prompt'          # new session in specified dir
ca <time> <session-id> 'prompt'         # resume existing session

# Recurring
ca -r <schedule> <time> 'prompt'
ca -r <schedule> <time> <directory> 'prompt'

# Management
ca --list                               # list all jobs
ca --cancel <job-id>                    # cancel a job
ca --cancel all                         # cancel all one-time jobs (keeps recurring)
ca --modify <job-id>                    # edit prompt interactively
ca --modify <job-id> 'new-prompt'       # change prompt directly
ca --time <job-id> <time>               # reschedule
ca --upgrade                            # upgrade jobs from older versions
ca --setup                              # configure pmset wake permissions
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

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_AT_TERMINAL` | `Terminal` | Terminal app (`Terminal` or `iTerm2`) |
| `CLAUDE_AT_FLAGS` | *(empty)* | Extra flags passed to `claude` CLI |
| `CLAUDE_AT_STORE` | `~/.claude-at` | Job storage directory |
| `CLAUDE_AT_LANG` | *(auto-detect)* | Display language (`en` or `ko`) |
| `CLAUDE_AT_MIN_INTERVAL` | `120` | Minimum interval (seconds) between repeat job runs (dedup guard) |

### Running with `--dangerously-skip-permissions`

By default, scheduled sessions run **without** `--dangerously-skip-permissions`. To enable it:

```bash
export CLAUDE_AT_FLAGS="--dangerously-skip-permissions"
ca +30m "task that needs full permissions"
```

> **Warning**: This flag disables all permission checks in Claude Code. Scheduled sessions run unattended — use with caution. The flag is captured at job creation time and shown as `[!]` in `ca -l` output.

### Wake from Sleep

The tool uses `pmset schedule wake` to wake the Mac before scheduled jobs. Run `ca --setup` to configure passwordless `pmset` access — this is required for recurring jobs to reliably wake the machine.

**How it works:**

1. When a job is created, `claude-at` schedules a `pmset wake` 2 minutes before the target time
2. For recurring jobs, each run automatically schedules the wake for the next execution
3. `ca --setup` creates `/etc/sudoers.d/claude-at` so that background wake scheduling works without a password

**If `ca --setup` is not run:**

- Job creation will prompt for your password (interactive fallback)
- Background wake scheduling (between recurring runs) will silently fail
- Jobs will still run if the machine happens to be awake, but will be delayed if asleep

**Lid and display requirements:**

| State | Wake | Job runs |
|-------|------|----------|
| Lid open, asleep | Yes | Yes |
| Lid closed + external monitor + power | Yes | Yes |
| Lid closed, no external monitor | Yes | **No** — terminal cannot open |

## Permissions

On first use, macOS may prompt for:

- **Automation permission**: Allows the script to open Terminal windows via AppleScript. Go to System Settings > Privacy & Security > Automation
- **sudo** (one-time): `ca --setup` requires admin password to create the sudoers rule

## How It Works

1. Creates a **launchd** user agent (plist in `~/Library/LaunchAgents/`) with `StartCalendarInterval`
2. At the scheduled time, launchd runs a **runner script** that:
   - Schedules the next `pmset wake` (recurring jobs)
   - Guards against duplicate runs within the minimum interval
   - Wakes the display with `caffeinate -u`
   - Displays a macOS notification
   - Opens Terminal.app (or iTerm2) via AppleScript (with 3 retries)
   - Runs an **exec script** inside the terminal that starts Claude Code with `caffeinate -i`
3. For one-time jobs, the runner includes a **date guard** and the exec script cleans up all files after execution
4. For recurring jobs, a `_next_wake.sh` helper calculates and registers the next wake time

## Upgrading

After updating `claude-at`, run `ca --upgrade` to regenerate runner scripts for existing jobs. This applies security improvements and updates the wake helper script.

## Uninstall

```bash
# Cancel all jobs first (one-time jobs)
ca -c all
# Check for remaining recurring jobs
ca -l
# Cancel any remaining recurring jobs individually
ca -c <job-id>

# Remove the binary (system-wide)
sudo make uninstall
# or (user-local)
make uninstall-user

# Optionally remove the sudoers rule
sudo rm -f /etc/sudoers.d/claude-at

# Optionally remove job data
rm -rf ~/.claude-at
```

## Troubleshooting

**"operation not permitted" or automation error on first run**
macOS requires Automation permission. Go to System Settings > Privacy & Security > Automation and allow your terminal to control Terminal.app (or iTerm2).

**Job didn't run (machine was asleep)**
Run `ca --setup` to configure passwordless `pmset` access. Check `~/.claude-at/<job-id>.runlog` for `warn: pmset wake failed` entries. The lid must be open or an external monitor connected.

**Job ran late**
Check if `pmset wake` was scheduled: `pmset -g sched`. If no `claude-at` wake entry exists, run `ca --setup` and then `ca --upgrade` to regenerate scripts.

**"bootstrap failed" when creating a job**
The launchd agent may already be loaded. Run `ca -c <job-id>` to clean up, then recreate.

**Jobs from older versions can't be modified**
Run `ca --upgrade` to add missing metadata fields and regenerate scripts.

## License

MIT
