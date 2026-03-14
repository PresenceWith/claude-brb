# claude-at

Schedule [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI sessions on macOS using launchd.

- One-time or recurring schedules (daily, weekday, weekend, specific days)
- Opens a Terminal window (or iTerm2) and runs Claude Code at the scheduled time
- Wake-from-sleep support via `pmset`
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

### Running with `--dangerously-skip-permissions`

By default, scheduled sessions run **without** `--dangerously-skip-permissions`. To enable it:

```bash
export CLAUDE_AT_FLAGS="--dangerously-skip-permissions"
ca +30m "task that needs full permissions"
```

> **Warning**: This flag disables all permission checks in Claude Code. Scheduled sessions run unattended — use with caution. The flag is captured at job creation time and shown as `[!]` in `ca -l` output.

### Wake from Sleep

The tool uses `pmset schedule wake` to wake the Mac before scheduled jobs. This requires `sudo` access. If passwordless sudo is not configured, you will be prompted for your password. Wake scheduling is optional — jobs still run if the machine is already awake.

## Permissions

On first use, macOS may prompt for:

- **Automation permission**: Allows the script to open Terminal windows via AppleScript
- **sudo** (optional): For `pmset schedule wake` to wake from sleep

## How It Works

1. Creates a **launchd** user agent (plist in `~/Library/LaunchAgents/`) with `StartCalendarInterval`
2. At the scheduled time, launchd runs a **runner script** that:
   - Displays a macOS notification
   - Opens Terminal.app (or iTerm2) via AppleScript
   - Runs an **exec script** inside the terminal that starts Claude Code with `caffeinate`
3. For one-time jobs, the runner includes a **date guard** and the exec script cleans up all files after execution
4. For recurring jobs, the runner schedules the next `pmset wake`

## Upgrading

After updating `claude-at`, run `ca --upgrade` to regenerate runner scripts for existing jobs. This applies security improvements and removes any hardcoded flags from older versions.

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
```

## Troubleshooting

**"operation not permitted" or automation error on first run**
macOS requires Automation permission. Go to System Settings > Privacy & Security > Automation and allow your terminal to control Terminal.app (or iTerm2).

**Job didn't run (machine was asleep)**
Wake-from-sleep requires `sudo` for `pmset schedule wake`. If passwordless sudo is not configured, you'll be prompted during job creation. Without it, jobs only run when the machine is already awake.

**"bootstrap failed" when creating a job**
The launchd agent may already be loaded. Run `ca -c <job-id>` to clean up, then recreate.

**Repeat jobs stop waking the machine after `ca -c all`**
This is fixed in v0.1.0+. Run `ca --upgrade` to regenerate runner scripts.

**Jobs from older versions can't be modified**
Run `ca --upgrade` to add missing metadata fields and regenerate scripts.

## License

MIT
