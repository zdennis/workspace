# workspace config

Show, set, get, or unset project or global workspace configuration.

## Usage

```sh
workspace config [options] [project]
workspace config set <key> <value> [--project NAME]
workspace config get <key> [--project NAME]
workspace config unset <key> [--project NAME]
```

## Options

| Option | Description |
|--------|-------------|
| `--global` | Show global configuration instead of project config |
| `--project NAME` | (`set`/`get`/`unset`) Configure this project instead of the one inferred from cwd |

## Details

With no subcommand, displays the YAML configuration for a project or the global workspace config. Auto-detects the project from the current directory if not specified.

`set`, `get`, and `unset` manage a project's config by dotted key, without needing to open the YAML file by hand. `get` prints the value and exits 0; if the key has no value, it prints nothing on stdout, a short note on stderr, and exits 1. The project is inferred from cwd via the same resolver used by `workspace parent`, `workspace lock`, and `dev`: a worktree resolves to its parent project. Pass `--project NAME` to target a different project explicitly.

`set`, `get`, and `unset` are reserved as the first argument to `workspace config`: they are always treated as subcommands, not as a project name. A project literally named `set`, `get`, or `unset` can't be shown via `workspace config <name>`; it would need a different name, or reading its YAML file directly.

Only an allowlisted set of keys can be written this way, so a typo doesn't silently create unused config:

| Key | Description |
|-----|-------------|
| `dev.up` | Command that starts the project's dev environment |
| `dev.ready` | Readiness probe for the dev environment |
| `dev.stop_timeout` | Grace period before force-stopping the dev environment, e.g. `20s` or `20` |
| `dev.startup_timeout` | How long `dev up` waits for the wrapper to take a free lock, e.g. `30s` (default `30s`) |
| `dev.ready_timeout` | How long `dev up` waits for the `dev.ready` check to pass, e.g. `2m` (default `120s`) |
| `dev.kill_grace` | How long `lock clear devenv`, `dev down` and `dev up --takeover` wait for a SIGKILLed dev environment's process group to disappear before keeping its lock (default `2s`, capped at `60s`) |
| `locks.idle_grace` | How long an idle agent keeps a lock before the first waiter may take it over (default `5m`; see [`workspace lock`](README.lock.md)) |
| `locks.ps_timeout` | How long to wait for `ps` when reading the process table for lock/session checks, before giving up (default `5s`, must be between `1s` and `60s`) |
| `locks.reap_interval` | How often the session-monitor daemon sweeps for stale lock holders and waiters (default `30s`) |
| `alerts.notify` | Command the session-monitor daemon runs when an agent pane starts waiting on a person or stays idle past `alerts.idle_after` (unset: no alerts; see [`workspace sessions`](README.sessions.md#alerts)) |
| `alerts.idle_after` | How long an agent pane may sit idle before `alerts.notify` runs (default `10m`) |
| `statusline.command` | Global. Delegates [`workspace statusline`](README.statusline.md) rendering to another command instead of the built-in renderer |
| `context.source` | Global. `statusline` (default) or `scrape` — where `workspace sessions` reads a pane's context usage; see [`workspace statusline`](README.statusline.md) |
| `context.pattern` | Global. Regex with exactly one capture group, used when `context.source` is `scrape` |
| `launch.headless` | Global. `true` or `false`: whether `launch`, `start` and `doctor` run [headless](README.launch.md#headless) on this machine when no `--headless`/`--no-headless` flag is given. Unset, they pick headless off macOS, without `osascript`, or when `CI` is set |

`statusline.command`, `context.source`, `context.pattern`, and `launch.headless` are always written to the global config, never a project's — there's one status line, one context source and one launch mode per machine. `context.source` must be `statusline` or `scrape`; `context.pattern` must be a valid regex with exactly one capture group. `launch.headless` must be `true` or `false`.

`dev.stop_timeout`, `dev.startup_timeout`, `dev.ready_timeout`, `dev.kill_grace`, `locks.idle_grace`, `locks.ps_timeout`, `locks.reap_interval`, and `alerts.idle_after` must parse as a duration: a plain number of seconds, or a number with an `s`, `m` or `h` suffix (`20`, `20s`, `5m`, `1h`). `dev.startup_timeout`, `dev.ready_timeout`, `dev.kill_grace`, `locks.idle_grace`, `locks.ps_timeout`, `locks.reap_interval`, and `alerts.idle_after` must also be greater than 0. `alerts.notify` must not be blank. `dev.kill_grace` is also capped at 60s. `locks.ps_timeout` must be between 1s and 60s: too small and `ps` times out on nearly every call, which makes liveness checks come back unknown (treated as alive) and can stall a lock queue behind a clearing marker that never gets to show dead. Anything else is rejected before it's written.

`locks.ps_timeout`, `locks.reap_interval`, `alerts.notify` and `alerts.idle_after` only take effect the next time the session-monitor daemon starts (`workspace launch`/`workspace agent --force`); a daemon already running keeps the values it started with. `workspace config set` prints a reminder of this after setting any of these four keys.

`dev.up` runs via `/bin/sh -c`, so it can carry inline environment variables and quoting, e.g.:

```sh
workspace config set dev.up 'FOO="bar baz" ./start-dev'
```

Before writing, `set` and `unset` back up the project's config file (via the same backup mechanism used elsewhere in workspace) and then rewrite it through a temp file and rename. **`YAML.dump` drops comments** — if you've hand-edited the file with comments, they will be lost the first time `set` or `unset` touches it.

### Config file locations

- **Global:** `~/.config/workspace/config.yml`
- **Project:** `~/.config/workspace/projects/<name>.yml`

### Global settings

| Setting | Description |
|---------|-------------|
| `hooks` | Global hooks applied to all projects |
| `layouts` | Default tmux pane layouts |
| `event_log_compact_threshold` | Size warning threshold (e.g., "10kb", "1mb"). Default: 1mb |

### Project settings

| Setting | Description |
|---------|-------------|
| `hooks` | Project-specific hooks (e.g., `post_launch`) |
| `layouts` | Project-specific tmux pane layouts |
| `worktree_hooks` | Hooks seeded into new worktrees created from this project |
| `dev.up`, `dev.ready`, `dev.stop_timeout`, `dev.startup_timeout`, `dev.ready_timeout`, `dev.kill_grace` | Dev environment config; set via `workspace config set` (see above) |
| `locks.idle_grace` | Idle takeover grace period for this project's locks; set via `workspace config set` (see above) |
| `locks.ps_timeout` | How long to wait for `ps` before giving up, for this project's lock and session checks; must be between `1s` and `60s`; set via `workspace config set` (see above) |
| `locks.reap_interval` | How often the session-monitor daemon sweeps for stale locks; set via `workspace config set` (see above) |
| `alerts.notify`, `alerts.idle_after` | Notify command for waiting and long-idle agent panes; set via `workspace config set` (see above) |

## Examples

```sh
# Show config for a specific project
workspace config myproject

# Show config for the current directory's project
workspace config

# Show global configuration
workspace config --global

# Configure how a project's dev environment starts
workspace config set dev.up "./start-dev"
workspace config set dev.ready "port:3000"
workspace config set dev.stop_timeout 20s

# Get a macOS notification when an agent waits on you or sits idle for 15 minutes
workspace config set alerts.notify 'osascript -e "display notification (system attribute \"WORKSPACE_ALERT_TEXT\") with title \"workspace\""'
workspace config set alerts.idle_after 15m

# Let a waiter take over a lock after its holder has been idle for 10 minutes
workspace config set locks.idle_grace 10m

# Give a slow-to-die dev server 10s after SIGKILL before its lock is kept
workspace config set dev.kill_grace 10s

# Read a key back
workspace config get dev.up

# Remove a key
workspace config unset dev.ready

# Target a project other than the one inferred from cwd
workspace config set --project myapp dev.up "bin/dev"

# Edit config files directly (global config has no set/get/unset)
$EDITOR ~/.config/workspace/config.yml
$EDITOR ~/.config/workspace/projects/myproject.yml
```
