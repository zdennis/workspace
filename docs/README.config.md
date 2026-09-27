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
| `locks.idle_grace` | How long an idle agent keeps a lock before the first waiter may take it over (default `5m`; see [`workspace lock`](README.lock.md)) |

`dev.stop_timeout`, `dev.startup_timeout`, `dev.ready_timeout`, and `locks.idle_grace` must parse as a duration: a plain number of seconds, or a number with an `s`, `m` or `h` suffix (`20`, `20s`, `5m`, `1h`). `dev.startup_timeout`, `dev.ready_timeout`, and `locks.idle_grace` must also be greater than 0. Anything else is rejected before it's written.

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
| `event_log_compact_threshold` | Size warning threshold (e.g., "10kb", "1mb"). Default: 10kb |

### Project settings

| Setting | Description |
|---------|-------------|
| `hooks` | Project-specific hooks (e.g., `post_launch`) |
| `layouts` | Project-specific tmux pane layouts |
| `worktree_hooks` | Hooks seeded into new worktrees created from this project |
| `dev.up`, `dev.ready`, `dev.stop_timeout`, `dev.startup_timeout`, `dev.ready_timeout` | Dev environment config; set via `workspace config set` (see above) |
| `locks.idle_grace` | Idle takeover grace period for this project's locks; set via `workspace config set` (see above) |

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

# Let a waiter take over a lock after its holder has been idle for 10 minutes
workspace config set locks.idle_grace 10m

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
