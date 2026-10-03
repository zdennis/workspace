# workspace config

Show, validate, set, get, or unset project or global workspace configuration.

## Usage

```sh
workspace config [show] [options] [project]
workspace config show [--name NAME] [--json]
workspace config validate [--name NAME] [--json]
workspace config set <key> <value> [--project NAME] [--json]
workspace config get <key> [--project NAME]
workspace config unset <key> [--project NAME]
```

## Options

| Option | Description |
|--------|-------------|
| `--global` | Show global configuration instead of project config |
| `--name NAME` | (`show`, `validate`) The workspace to report on instead of the one inferred from cwd; for `show` the same as the project argument |
| `--json` | (`show`, `validate`, `set`) Print one JSON document (below) instead of text |
| `--project NAME`, `--name NAME` | (`set`/`get`/`unset`) Configure this project instead of the one inferred from cwd; the two are the same option |

## Details

With no subcommand, displays the YAML configuration for a project or the global workspace config. Auto-detects the project from the current directory if not specified.

`set`, `get`, and `unset` manage a project's config by dotted key, without needing to open the YAML file by hand. `get` prints the value and exits 0; if the key has no value, it prints nothing on stdout, a short note on stderr, and exits 1. The project is inferred from cwd via the same resolver used by `workspace parent`, `workspace lock`, and `dev`: a worktree resolves to its parent project. Pass `--project NAME` to target a different project explicitly.

`show`, `validate`, `set`, `get`, and `unset` are reserved as the first argument to `workspace config`: they are always treated as subcommands, not as a project name. `workspace config show <name>` is the same as `workspace config <name>`. A project literally named one of them can be shown with `workspace config -- <name>` (everything after `--` is a name), or by reading its YAML file directly.

<!-- The tables between GENERATED markers are rendered from lib/workspace/config_schema.rb; edit the schema and run script/generate-config-docs. -->

Only an allowlisted set of keys can be written this way, so a typo doesn't silently create unused config:

<!-- BEGIN GENERATED: keys -->
| Key | Description |
|-----|-------------|
| `dev.up` | Command that starts the project's dev environment |
| `dev.ready` | Readiness probe for the dev environment |
| `dev.stop_timeout` | Grace period before force-stopping the dev environment, e.g. `20s` or `20` |
| `dev.startup_timeout` | How long `dev up` waits for the wrapper to take a free lock, e.g. `30s` (default `30s`) |
| `dev.ready_timeout` | How long `dev up` waits for the `dev.ready` check to pass, e.g. `2m` (default `120s`) |
| `dev.kill_grace` | How long `lock clear devenv`, `dev down` and `dev up --force` wait for a SIGKILLed dev environment's process group to disappear before keeping its lock (default `2s`, capped at `60s`) |
| `locks.idle_grace` | How long an idle agent keeps a lock before the first waiter may take it over (default `5m`; see [`workspace lock`](README.lock.md)) |
| `locks.ps_timeout` | How long to wait for `ps` when reading the process table for lock/session checks, before giving up (default `5s`, must be between `1s` and `60s`) |
| `locks.reap_interval` | How often the session-monitor daemon sweeps for stale lock holders and waiters (default `30s`) |
| `alerts.notify` | Command the session-monitor daemon runs when an agent pane starts waiting on a person or stays idle past `alerts.idle_after` (unset: no alerts; see [`workspace sessions`](README.sessions.md#alerts)) |
| `alerts.idle_after` | How long an agent pane may sit idle before `alerts.notify` runs (default `10m`) |
| `handoff.threshold` | Context-usage percent, 1 to 100, that triggers a handoff in [`workspace handoff check`](README.handoff.md) (default `11`) |
| `handoff.check_prompt` | Overrides the built-in save-state prompt `handoff check --handoff-doc` sends; must not be blank (see [`workspace handoff`](README.handoff.md)) |
| `handoff.resume_prompt` | Overrides the built-in resume prompt `handoff new` sends; must not be blank (see [`workspace handoff`](README.handoff.md)) |
| `statusline.command` | Global. Delegates [`workspace statusline`](README.statusline.md) rendering to another command instead of the built-in renderer |
| `context.source` | Global. `statusline` (default) or `scrape` — where `workspace sessions` reads a pane's context usage; see [`workspace statusline`](README.statusline.md) |
| `context.pattern` | Global. Regex with exactly one capture group, used when `context.source` is `scrape` |
| `launch.headless` | Global. `true` or `false`: whether `launch`, `start` and `doctor` run [headless](README.launch.md#headless) on this machine when no `--headless`/`--no-headless` flag is given. Unset, they pick headless off macOS, without `osascript`, or when `CI` is set |
<!-- END GENERATED: keys -->

`statusline.command`, `context.source`, `context.pattern`, and `launch.headless` are always written to the global config, never a project's — there's one status line, one context source and one launch mode per machine. `context.source` must be `statusline` or `scrape`; `context.pattern` must be a valid regex with exactly one capture group. `launch.headless` must be `true` or `false`.

`dev.stop_timeout`, `dev.startup_timeout`, `dev.ready_timeout`, `dev.kill_grace`, `locks.idle_grace`, `locks.ps_timeout`, `locks.reap_interval`, and `alerts.idle_after` must parse as a duration: a plain number of seconds, or a number with an `s`, `m` or `h` suffix (`20`, `20s`, `5m`, `1h`). `dev.startup_timeout`, `dev.ready_timeout`, `dev.kill_grace`, `locks.idle_grace`, `locks.ps_timeout`, `locks.reap_interval`, and `alerts.idle_after` must also be greater than 0. `alerts.notify` must not be blank. `dev.kill_grace` is also capped at 60s. `locks.ps_timeout` must be between 1s and 60s: too small and `ps` times out on nearly every call, which makes liveness checks come back unknown (treated as alive) and can stall a lock queue behind a clearing marker that never gets to show dead. Anything else is rejected before it's written.

<!-- BEGIN GENERATED: restart -->
`locks.ps_timeout`, `locks.reap_interval`, `alerts.notify` and `alerts.idle_after` only take effect the next time the session-monitor daemon starts (`workspace launch`/`workspace agentd --force`); a daemon already running keeps the values it started with. `workspace config set` prints a reminder of this after setting any of these four keys.
<!-- END GENERATED: restart -->

`dev.up` runs via `/bin/sh -c`, so it can carry inline environment variables and quoting, e.g.:

```sh
workspace config set dev.up 'FOO="bar baz" ./start-dev'
```

Before writing, `set` and `unset` back up the project's config file (via the same backup mechanism used elsewhere in workspace) and then rewrite it through a temp file and rename. **`YAML.dump` drops comments** — if you've hand-edited the file with comments, they will be lost the first time `set` or `unset` touches it.

If the file isn't valid YAML (or isn't a mapping at the top level), `set` and `unset` stop with `Cannot parse <path>: ...` and leave it as written; fix or remove it and retry. Readers that run in the background (lock, alert, and handoff settings) warn and use their defaults instead of failing.

### `config show --json`

```sh
workspace config show --name api.worktree-fix --json
```

Prints one document with every key in the table above, the value each reader would use, and the file it comes from. It reads the layers the workspace reads, which is not always the file `workspace config` prints: `dev`, `locks`, `alerts` and `handoff` come from the **parent project's** file even in a worktree (the same file `config set` writes), `hooks` and `pipeline` from the workspace's own file, and `statusline`, `context`, `launch` and `event_log_compact_threshold` from the global file.

```json
{"schema_version":1,"ok":true,"workspace":"api.worktree-fix","parent":"api",
 "files":[
  {"layer":"worktree","path":"/Users/me/.config/workspace/projects/api.worktree-fix.yml","exists":true,"etag":"sha256:9be0...","parse_error":null},
  {"layer":"project","path":"/Users/me/.config/workspace/projects/api.yml","exists":true,"etag":"sha256:3f9a...","parse_error":null},
  {"layer":"global","path":"/Users/me/.config/workspace/config.yml","exists":false,"etag":null,"parse_error":null}],
 "keys":[
  {"key":"dev.ready_timeout","scope":"project","type":"duration","value":"90s","masked":false,"default":120,"effective":90,
   "source":"project","source_file":"/Users/me/.config/workspace/projects/api.yml","line":10,"column":3,
   "resolve":"parent","target_layer":"project","affects":["api","api.worktree-fix","api.worktree-search"],
   "applies":"next_call","settable":true,"sensitive":false,"problems":[]},
  {"key":"dev.up","scope":"project","type":"command","value":null,"masked":true,"default":null,"effective":null,
   "source":"project","source_file":"/Users/me/.config/workspace/projects/api.yml","line":9,"column":3,
   "resolve":"parent","target_layer":"project","affects":["api","api.worktree-fix","api.worktree-search"],
   "applies":"next_call","settable":true,"sensitive":true,"problems":[]}],
 "unknown_keys":[{"key":"deploy_url","layer":"project","line":14,"column":1}]}
```

- `files` lists the worktree's own file (only for a worktree), the project's, and the global one, in that order. `etag` is `sha256:` and the hash of the file's bytes, or null when the file is missing. `parse_error` is null, or `{"message", "line", "column"}` for a file that can't be parsed (`line` and `column` are omitted for an error without a position, such as a disallowed alias).
- `keys` has one row per schema key, in schema order. `hooks` and `layouts` appear twice, once per `scope`.
- `value` is what the file holds, as written. `effective` is what a reader uses: the stored value as parsed (durations are in seconds), or `default` when the key is unset or its stored value is invalid (see `problems`). It is null for a `sensitive` key and when the key's file is `unreadable`. `default` is null when the reader has none. A value in a layer the key's readers don't consult (a `dev` key in a worktree's file) isn't checked and doesn't change `effective`; `config validate` notes it as `not_read`.
- `source` is `project`, `worktree` or `global` (the layer the value is in), `default`, or `unreadable` when the file that would hold it can't be parsed; the other layers stay readable. `source_file`, `line` and `column` are null unless the value is in a file.
- `resolve` says whose file the readers consult: `parent`, `own`, `merge` (global, then the workspace's own; the row reports one scope's file), `global`, or `none` (nothing reads it; today that is global `hooks`). `target_layer` is where `config set` writes the key, and null for a key edited by hand. `affects` lists the workspaces that read the file a change lands in. `applies` is `next_call`, `next_event` or `daemon_restart`; treat an unknown value as plain text.
- `sensitive` keys are commands and hooks. Their `value` and `effective` are always null; `masked` is true when the key has a value. Neither `problems` nor `unknown_keys` ever quote a value.
- `problems` holds the problems `config validate` reports for that key, with `severity`, `code`, `message`, `line` and `column`.
- `type` is `command`, `duration`, `percent`, `text`, `enum`, `regex`, `boolean` or `mapping`.

A file that can't be parsed doesn't fail `config show --json`: it is reported in `files` and its keys are `unreadable`. (Plain `workspace config` still refuses and prints the error.) `--json` can't be combined with `--global`; the global file is one of the layers. An unknown workspace is an error document with code `unknown_workspace`.

### `config validate`

```sh
workspace config validate [--name NAME] [--json]
```

Checks the files `config show --json` lists, without writing anything: YAML syntax, the type and value of each key (the same checks `config set` makes), keys nothing reads, and keys set in a layer where they have no effect. Exits 0 when no problem is an error, 1 when one is. Warnings and notes don't change the exit status. A file that can't be parsed is a problem with a position, not a crash.

```json
{"schema_version":1,"ok":true,"valid":false,"workspace":"api",
 "problems":[
  {"severity":"error","code":"invalid_value","layer":"project","file":"/Users/me/.config/workspace/projects/api.yml",
   "line":3,"column":3,"key":"dev.ready_timeout","message":"dev.ready_timeout: expected a duration like \"20\", \"20s\", \"5m\" or \"1h\", got \"soon\""},
  {"severity":"warning","code":"unknown_key","layer":"project","file":"...","line":14,"column":1,"key":"deploy_url",
   "message":"deploy_url isn't a known project config key. Nothing reads it here."}]}
```

`ok` means the command ran; `valid` means there are no errors. Problems are ordered worktree file, project file, global file, then by line. `line` and `column` are 1-based and point at the key, and are null when the problem has no position. Without `--json`, each problem prints as `severity: file:line:column: message`.

| `code` | `severity` | Meaning |
|---|---|---|
| `yaml_syntax` | error | The file isn't valid YAML, isn't a mapping at the top level, or uses an alias or tag a config file may not use |
| `invalid_value` | error | A key's value fails the check `config set` would make, or a section isn't a mapping |
| `unknown_key` | warning | Nothing reads the key in this file; the message says when it is a setting of the other scope |
| `not_read` | info | The key is set where no reader looks: a parent-scoped key in a worktree's file, or global `hooks` |

New codes may be added; treat an unknown one by its `severity`.

### Config file locations

- **Global:** `~/.config/workspace/config.yml`
- **Project:** `~/.config/workspace/projects/<name>.yml`

### Global settings

<!-- BEGIN GENERATED: global-settings -->
| Setting | Description |
|---------|-------------|
| `hooks` | Global hooks applied to all projects |
| `layouts` | Default tmux pane layouts |
| `event_log_compact_threshold` | Size warning threshold (e.g., "10kb", "1mb"). Default: 1mb |
<!-- END GENERATED: global-settings -->

### Project settings

<!-- BEGIN GENERATED: project-settings -->
| Setting | Description |
|---------|-------------|
| `hooks` | Project-specific hooks (e.g., `post_launch`) |
| `layouts` | Project-specific tmux pane layouts |
| `worktree_hooks` | Hooks seeded into new worktrees created from this project |
| `pipeline` | Pipeline stages (`pipeline.panes`: role, timeout) the agent daemon dispatches work through |
<!-- END GENERATED: project-settings -->

Keys you can set with `workspace config set` are listed in the table above; the settings here are edited by hand.

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

## JSON output

`config set --json` prints an action document (see [README.json.md](README.json.md#actions); the action is `config set`) with one `set` row carrying `key`, `value` and `global`; `workspace` is the project, or null for a global key.
