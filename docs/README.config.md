# workspace config

Show, validate, set, get, unset, edit or describe (`keys`) project or global workspace configuration.

## Usage

```sh
workspace config [show] [options] [key]
workspace config show [--name NAME] [--json]
workspace config [show] <key> [--name NAME] [--json]
workspace config validate [--name NAME] [--json]
workspace config set [--scope SCOPE] [--name NAME] [--json] <key> [--] <value>
workspace config get [--scope SCOPE] [--name NAME] <key>
workspace config unset [--scope SCOPE] [--name NAME] [--json] <key>
workspace config show --scope SCOPE [--name NAME] [--json] [key]
workspace config edit [--scope SCOPE] [--name NAME] [--json]
workspace config keys [QUERY] [--settable] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--global` | Show global configuration instead of project config; the same as `--scope global` |
| `--scope SCOPE` | `global`, `project` or `workspace` (`worktree` is the same). `set`/`get`/`unset`: the layer whose file is written or read. `show`: see [Scopes](#scopes) |
| `--name NAME` | (`show`, `validate`, `edit`) The workspace to report on instead of the one inferred from cwd |
| `--settable` | (`keys`) Only the keys `set` accepts |
| `--json` | (`show`, `validate`, `set`, `unset`, `edit`, `keys`) Print one JSON document (below) instead of text |
| `--project NAME`, `--name NAME` | (`set`/`get`/`unset`/`edit`) Configure this project instead of the one inferred from cwd; the two are the same option |

## Details

With no subcommand, displays the YAML configuration for the current directory's workspace (auto-detected), another workspace via `--name`, or the global workspace config via `--global`.

With no subcommand and a key, `workspace config <key>` prints that key's effective value for the current directory's workspace (or `--name`'s): the value the readers actually use, across the worktree/parent-project layers and the schema's default when unset. Unlike `config get`, which reads one file and prints only a stored value, this prints the effective one; `--json` prints the same show document as below with `keys` filtered to that one key's row. Like `config get`, a key with no effective value prints nothing on stdout, a short note on stderr, and exits 1. Sensitive keys (`dev.up`, `dev.ready`, `alerts.notify`, `statusline.command`, `context.pattern`) never print their value, only whether they are set.

`set`, `get`, and `unset` manage a project's config by dotted key, without needing to open the YAML file by hand. `get` prints the value and exits 0; if the key has no value, it prints nothing on stdout, a short note on stderr, and exits 1. The project is inferred from cwd via the same resolver used by `workspace parent`, `workspace lock`, and `dev`: a worktree resolves to its parent project. Pass `--project NAME` (or `--name NAME`) to target a different workspace explicitly.

`notes.dir` is the key where a worktree reads only its own file. Inside a worktree, `set`, `get` and `unset` use the worktree's own file (`~/.config/workspace/projects/<project>.worktree-<name>.yml`), and a worktree never inherits the project's value: with none of its own, its `notes.dir` is unset. The main checkout reads and writes the project's file. `--name` picks the file from anywhere, so `workspace config set notes.dir /notes/api-fix --name api.worktree-fix` sets one worktree's directory and `--name api` sets the main checkout's. A value already in the project's file stays there and still applies to the main checkout only.

`show`, `validate`, `set`, `get`, `unset`, `edit` and `keys` are reserved as the first argument to `workspace config`: they are always treated as subcommands, not as a key. A workspace literally named one of them is shown with `--name`, or by reading its YAML file directly.

<!-- The tables between GENERATED markers are rendered from lib/workspace/config_schema.rb; edit the schema and run script/generate-config-docs. -->

Only an allowlisted set of keys can be written this way, so a typo doesn't silently create unused config:

<!-- BEGIN GENERATED: keys -->
| Key | Layers | Description | Examples |
|-----|--------|-------------|----------|
| `dev.up` | project, worktree | Command that starts the project's dev environment | `./bin/dev` |
| `dev.ready` | project, worktree | Readiness probe for the dev environment | `curl -sf http://localhost:3000/up` |
| `dev.stop_timeout` | project | Grace period before force-stopping the dev environment, e.g. `20s` or `20` | `20s`, `1m` |
| `dev.startup_timeout` | project, worktree | How long `dev up` waits for the wrapper to take a free lock, e.g. `30s` (default `30s`) | `30s`, `1m` |
| `dev.ready_timeout` | project, worktree | How long `dev up` waits for the `dev.ready` check to pass, e.g. `2m` (default `120s`) | `2m`, `90s` |
| `dev.kill_grace` | project | How long `lock clear devenv`, `dev down` and `dev up --force` wait for a SIGKILLed dev environment's process group to disappear before keeping its lock (default `2s`, capped at `60s`) | `2s`, `10s` |
| `dev.release_on_session_end` | global, project, worktree | `true` or `false`: whether the dev environment a coding agent started with `dev up` is stopped when that agent's session ends (default `true`). A `/clear` never stops it. `false` leaves it running until `dev down` | `true`, `false` |
| `dev.instructions` | global, project, worktree | `true` or `false`: whether `start` and `launch` send the agent the built-in `dev` pack (queue for the shared dev environment before testing, release it when done) when the project sets `dev.up` (default `true`); `--no-packs` skips it for one run. A workflow step that declares `uses: [devenv]` never gets it | `true`, `false` |
| `locks.idle_grace` | project | How long an idle agent keeps a lock before the first waiter may take it over (default `5m`; see [`workspace lock`](README.lock.md)) | `5m`, `10m` |
| `locks.ps_timeout` | project | How long to wait for `ps` when reading the process table for lock/session checks, before giving up (default `5s`, must be between `1s` and `60s`) | `5s`, `10s` |
| `locks.reap_interval` | project | How often the session-monitor daemon sweeps for stale lock holders and waiters (default `30s`) | `30s`, `1m` |
| `alerts.notify` | global, project, worktree | Command the session-monitor daemon runs when an agent pane starts waiting on a person or stays idle past `alerts.idle_after` (unset: no alerts; see [`workspace sessions`](README.sessions.md#alerts)) | `say 'agent needs you'` |
| `alerts.idle_after` | global, project, worktree | How long an agent pane may sit idle before `alerts.notify` runs (default `10m`) | `10m`, `30m` |
| `agentd.poll_interval` | global, project, worktree | How often the session-monitor daemon scans panes for agent state, alerts and stale locks (default `10s`) | `10s`, `30s` |
| `handoff.threshold` | global, project, worktree | Context-usage percent, 1 to 100, that triggers a handoff in [`workspace handoff check`](README.handoff.md) (default `11`) | `11`, `20` |
| `handoff.check_prompt` | global, project, worktree | Overrides the built-in save-state prompt `handoff check` sends when it names a doc (the default is that text); must not be blank (see [`workspace handoff`](README.handoff.md)) |  |
| `handoff.resume_prompt` | global, project, worktree | Overrides the built-in resume prompt `handoff new` sends (the default is that text); must not be blank (see [`workspace handoff`](README.handoff.md)) |  |
| `handoff.auto` | global, project, worktree | `true` or `false`: whether `start` and `launch` send a Claude Code agent the built-in `handoff` pack, which makes it run [`workspace handoff check`](README.handoff.md) after every task and hand off to a fresh conversation itself (default `false`); `--handoff` and `--no-handoff` override it for one run | `true`, `false` |
| `commands.test` | project, worktree | Command that runs the project's tests, e.g. `bundle exec rspec`; [`workspace instructions compose`](README.instructions.md) names it in the `commits` pack | `bundle exec rspec` |
| `commands.lint` | project, worktree | Command that lints the project, e.g. `bundle exec standardrb lib/ spec/`; named in the `commits` pack beside `commands.test` | `bundle exec standardrb lib/ spec/` |
| `notes.dir` | project, worktree | Directory where one workspace's notes are kept, as an absolute path; other tools read it to know where to store notes. A worktree reads only its own value (set it with `--name`), never the project's; the main checkout reads the project's (unset: the directory `notes.default_dir` gives it). A new worktree is given the main checkout's notes directory plus its branch (unless `notes.default_dir` is set) and keeps that value | `/Users/me/notes/api-fix` |
| `notes.default_dir` | global, project | The rule that gives each workspace its notes directory when it has no `notes.dir`: an absolute path, `~/…`, or a path relative to the worktree with no `..`; `{workspace}` and `{branch}` are filled in per workspace, so give an outside-the-repo path one or the other (unset: a worktree gets the main checkout's notes directory plus its branch; the main checkout gets its `notes.dir`, else `tmp/workspace-notes`) | `~/notes/{workspace}`, `tmp/workspace-notes` |
| `library.install.skills_dir` | global, project | Directory, relative to the checkout, where `library install` and `start --skill` copy a library skill (default `.claude/skills`); no `..` and not inside `.git`. Changing it does not move copies already installed (see [`library`](README.library.md#install-directories)) | `.claude/skills`, `.agents/skills` |
| `library.install.agents_dir` | global, project | Directory, relative to the checkout, where `library install` and `start --agent` copy a library agent (default `.claude/agents`); same rules as `library.install.skills_dir` | `.claude/agents`, `.agents/agents` |
| `library.install.user_skills_dir` | global | Global. Directory, absolute or under `~/`, where `library install --user` copies a library skill (default `~/.claude/skills`) | `~/.claude/skills`, `~/.agents/skills` |
| `library.install.user_agents_dir` | global | Global. Directory, absolute or under `~/`, where `library install --user` copies a library agent (default `~/.claude/agents`) | `~/.claude/agents` |
| `notes.instructions` | global, project, worktree | `true` or `false`: whether `start` and `launch` send the agent the built-in `notes` pack (where working notes go) with its first prompt (default `true`); `--no-packs` skips it for one run | `true`, `false` |
| `spine.template` | global, project, worktree | The name of the `spine` library template that `spine init` and `start --spine` use when no `--template` is given (lowercase letters, digits and hyphens; default `default`, the built-in one). A worktree can set its own with `--name`; an unknown name is a `config validate` warning and `spine init` answers `unknown_template` | `default`, `team` |
| `spine.auto` | global, project, worktree | `true` or `false`: whether `start` runs [`spine init`](README.spine.md#spine-init) with the resolved `spine.template` once the worktree exists, so the new agent is sent the `spine` pack. `start --spine[=NAME]` and `--no-spine` override it for one start | `true`, `false` |
| `plan.stall_seconds` | global, project, worktree | How long the agent pane that owns a workspace's plan may sit idle before [`workspace plan status`](README.plan.md) reads the plan as `stalled` (default `5m`) | `300`, `10m` |
| `agent.kind` | global, project, worktree | Which coding agent a new workspace's main agent pane runs: `claude`, `codex`, `opencode`, `pi` (default `claude`) | `claude`, `codex`, `opencode`, `pi` |
| `agent.commands.claude` | global, project, worktree | Command to run for Claude Code; a wrapper must pass its arguments through (e.g. `claude-dev`, default `claude`). See [Agent commands](README.config.md#agent-commands) | `claude-dev` |
| `agent.commands.codex` | global, project, worktree | Command to run for Codex; a wrapper must pass its arguments through (e.g. `codex-dev`, default `codex`). See [Agent commands](README.config.md#agent-commands) | `codex-dev` |
| `agent.commands.opencode` | global, project, worktree | Command to run for OpenCode; a wrapper must pass its arguments through (e.g. `opencode-dev`, default `opencode`). See [Agent commands](README.config.md#agent-commands) | `opencode-dev` |
| `agent.commands.pi` | global, project, worktree | Command to run for Pi; a wrapper must pass its arguments through (e.g. `pi-dev`, default `pi`). See [Agent commands](README.config.md#agent-commands) | `pi-dev` |
| `statusline.command` | global | Global. Delegates [`workspace statusline`](README.statusline.md) rendering to another command instead of the built-in renderer | `~/bin/my-statusline` |
| `context.source` | global | Global. `statusline` (default) or `scrape` — where `workspace sessions` reads a pane's context usage; see [`workspace statusline`](README.statusline.md) | `statusline`, `scrape` |
| `context.pattern` | global | Global. Regex with exactly one capture group, used when `context.source` is `scrape` | `(\d+)% used` |
| `launch.headless` | global | Global. `true` or `false`: whether `launch`, `start` and `doctor` run [headless](README.launch.md#headless) on this machine when no `--headless`/`--no-headless` flag is given. Unset, they pick headless off macOS, without `osascript`, or when `CI` is set | `true`, `false` |
| `launch.restore_window_position` | global | Global. `true` or `false`: whether `launch` puts a window back where it was when the workspace was stopped, if that spot is still on a connected screen (default `true`). `false` tiles every new window, as `launch --arrange` does; `stop` saves the position either way. See [`launch`](README.launch.md#window-position) | `true`, `false` |
| `workflows.defaults.include` | global, project, worktree | Instruction packs every workflow step and [`workspace instructions compose`](README.instructions.md) start with, as names separated by commas (default `binding, orchestrator, commits`) | `binding, commits` |
| `events.rotate_size` | global | Global. Size at which a daemon's hook-event file rotates to `<workspace>.jsonl.1` (default `5MB`, at least `64KB`). A byte count or a number with a `KB`, `MB` or `GB` suffix, where `1KB` is 1024 bytes; see [`workspace events`](README.events.md) | `512KB`, `5MB` |
| `codex.hooks.install` | global | Global. `true` or `false`: whether `start` installs workspace's hooks into Codex's user-level `$CODEX_HOME/hooks.json` (default `true`). `false` leaves that file alone, `doctor` reports the hooks as turned off by config, and Codex panes read as `hook_mode: "scrape"`; `init`, `doctor --fix` and `hooks uninstall` are unaffected. See [`start`](README.start.md) | `true`, `false` |
<!-- END GENERATED: keys -->

`statusline.command`, `context.source`, `context.pattern`, and `launch.headless` are always written to the global config, never a project's — there's one status line, one context source and one launch mode per machine. `context.source` must be `statusline` or `scrape`; `context.pattern` must be a valid regex with exactly one capture group. `launch.headless` must be `true` or `false`.

`dev.stop_timeout`, `dev.startup_timeout`, `dev.ready_timeout`, `dev.kill_grace`, `locks.idle_grace`, `locks.ps_timeout`, `locks.reap_interval`, `alerts.idle_after`, and `agentd.poll_interval` must parse as a duration: a plain number of seconds, or a number with an `s`, `m` or `h` suffix (`20`, `20s`, `5m`, `1h`). `dev.startup_timeout`, `dev.ready_timeout`, `dev.kill_grace`, `locks.idle_grace`, `locks.ps_timeout`, `locks.reap_interval`, `alerts.idle_after`, and `agentd.poll_interval` must also be greater than 0. `alerts.notify` must not be blank. `dev.kill_grace` is also capped at 60s. `locks.ps_timeout` must be between 1s and 60s: too small and `ps` times out on nearly every call, which makes liveness checks come back unknown (treated as alive) and can stall a lock queue behind a clearing marker that never gets to show dead. Anything else is rejected before it's written. `notes.dir` must be an absolute path with no leading or trailing whitespace, and no newline or other control character. A relative path is rejected, and so is a literal `~`, which is not expanded. The value is otherwise stored as given: a trailing slash or `..` segments are not normalized. `config get` prints the stored string, so a client can use it as a path with no further processing. The directory doesn't have to exist. `notes.default_dir` is stored as typed too, and must not be blank, padded, contain a control character, use a placeholder other than `{workspace}` or `{branch}`, start with `~` unless it starts with `~/`, or be a relative path with a `..` segment.

<!-- BEGIN GENERATED: restart -->
`locks.ps_timeout`, `locks.reap_interval`, `alerts.notify`, `alerts.idle_after`, `agentd.poll_interval`, `agent.commands.claude`, `agent.commands.codex`, `agent.commands.opencode`, `agent.commands.pi` and `events.rotate_size` only take effect the next time the session-monitor daemon starts (`workspace launch`/`workspace agentd --force`); a daemon already running keeps the values it started with. `workspace config set` prints a reminder of this after setting any of these 10 keys.
<!-- END GENERATED: restart -->

`dev.up` runs via `/bin/sh -c`, so it can carry inline environment variables and quoting, e.g.:

```sh
workspace config set dev.up 'FOO="bar baz" ./start-dev'
```

A client that wants to know where to keep notes for a workspace reads `notes.dir`; a worktree reads only its own value, and the main checkout reads the project's:

```sh
workspace config set notes.dir /Users/me/notes/api
workspace config get notes.dir          # /Users/me/notes/api
workspace config show --json --name api  # the `notes.dir` row has the value in `value` and `effective`
```

`notes.default_dir` is the project's rule for giving each workspace a directory, used when the workspace has no `notes.dir` of its own. Unset, the rule is `tmp/workspace-notes` inside the checkout. It takes an absolute path, `~/…` (expanded when the path is worked out, stored as typed), or a path relative to the worktree root with no `..`. `{workspace}` and `{branch}` are filled in for each workspace, with characters a file name can't hold (`/ \ : * ? " < > |`) replaced by `-`; no other placeholder is accepted. A path outside the repo needs `{workspace}` or `{branch}`, or every worktree gets the same directory:

```sh
workspace config set notes.default_dir '~/notes/api/{workspace}'
```

The `notes.dir` and `notes.default_dir` rows of `config show --json` carry `effective_path`, the absolute directory for the workspace asked about: `notes.dir`'s is the workspace's own value, else the rule's result; `notes.default_dir`'s is the rule's result alone.

`config get` prints nothing on stdout and exits 1 when the key is unset, so a client that finds no output should pick its own location. The "is not set" message on stderr marks that case, and `config show --name N --json` gives `value: null` for an unset key.

Before writing, `set` and `unset` back up the project's config file (via the same backup mechanism used elsewhere in workspace) and then rewrite it through a temp file and rename. Global keys are backed up the same way. **`YAML.dump` drops comments**, so a file you've hand-edited with comments loses them the first time `set` or `unset` touches it; use [`config edit`](#config-edit) to change a commented file by hand and keep them. When the old text had a comment, the command prints `Note: comments in <path> were not kept; backup at <path>` on stderr, and the `config set --json` row carries `comments_preserved: false` (`true` otherwise). The check looks for a `#` at the start of a line or after whitespace, outside a quoted scalar; a `#` line inside a block scalar (`|`, `>`) counts too, so the note can appear when nothing was lost. The backup is the old file, so copy the comments back from it by hand.

If the file isn't valid YAML (or isn't a mapping at the top level), `set` and `unset` stop with `Cannot parse <path>: ...` and leave it as written; fix or remove it and retry. Readers that run in the background (lock, alert, and handoff settings) warn and use their defaults instead of failing.

### Agent commands

`agent.kind` is the coding agent a new workspace runs in its main pane (`claude`, `codex`, `opencode` or `pi`; `claude` when unset). `agent.commands.<kind>` is the command that starts that agent; it defaults to the agent's own name. Both can be set at global, project and workspace scope (a worktree's own file), the nearest value winning:

```sh
# global: every workspace runs claude-dev instead of claude
workspace config set --scope global agent.commands.claude claude-dev

# project: the api project runs a different wrapper
workspace config set --scope project --name api agent.commands.claude claude-notes

# workspace: one worktree runs a third, and uses codex as its agent
workspace config set --scope workspace --name api.worktree-PROJ-123 agent.commands.claude claude-ticket
workspace config set --scope workspace --name api.worktree-PROJ-123 agent.kind codex
```

**What the value may be.** One program, optionally preceded by `VAR=value` words (`FOO=1 claude-dev`). workspace appends its own flags (`--dangerously-skip-permissions --continue`, and `--resume <id>` on `restore`) to the end, so the value cannot be a pipeline, a `;` or `&&` list or `sh -c '...'`. A name without a slash is looked up on `PATH`; `init`, `doctor` and `start` check that program is there.

**What `config set` checks.** An absolute-path program must exist and be an executable regular file (symlinks are followed); otherwise `config set` refuses with `agent_command_not_executable` (`details.path`, `details.reason`: `missing`, `not_executable` or `not_a_file`) and writes nothing. These checks run only when you set the value, never when it is read, so a path that later goes stale is never silently swapped for the default. Two things are only warnings, and the value is still saved: a bare name that is not on `PATH`, and a program whose name is neither the agent's name nor `<name>-...` (`claude-dev` is fine for `claude` but warned about for `codex`). `init`, `doctor` and `start` then check the program again at launch time. Warnings go to stderr, and to `warnings` in the `--json` row when there are any.

Any wrapper therefore has to pass its arguments through. A complete one:

```sh
mkdir -p ~/bin
cat > ~/bin/claude-dev <<'EOF'
#!/bin/sh
exec claude "$@"
EOF
chmod +x ~/bin/claude-dev        # and have ~/bin on PATH
workspace config set --scope global agent.commands.claude claude-dev
```

To add an environment variable or flags of your own, put them before `"$@"`:

```sh
#!/bin/sh
exec env FOO=1 claude --model sonnet "$@"
```

The command is used by every config written from then on, and at once by what workspace types itself: `restore`, `reactivate` and `--spawn`. A pane whose program is the configured command counts as that agent for `sessions`, `handoff` and the rest. Configs written earlier keep the pane they have; `workspace doctor` lists them and `workspace doctor --fix` rewrites the pane line (see [`doctor`](README.doctor.md#agent-pane-commands)). `launch` never rewrites it. The `agent.commands.*` keys only take effect in an agent daemon the next time it starts, and the value can carry `VAR=value` words, so `config show --json` masks it.

### Scopes

`--scope` names the layer a command works on, with the names a person sees: `global` (`~/.config/workspace/config.yml`), `project` (the main checkout's file) and `workspace` (the workspace's own file). The `layer` values in JSON are `global`, `project` and `worktree`; `workspace` is the `worktree` layer, and `worktree` is accepted as another spelling of `--scope workspace`. In a main checkout there is no file besides the project's, so `--scope workspace` means the project file there, and the result reports `scope: "project"`, `layer: "project"`. Naming a workspace that isn't known with `--scope workspace` fails with `unknown_workspace`.

With no `--scope`, `set`, `get` and `unset` use the highest layer the key allows at or below the workspace (`target_layer` in `config show --json`): the workspace's own file for a key a worktree may override, else the project's file, and the global file for a global-only key and for `workflows.defaults.include`. That holds for `--name <worktree>` as well as for a worktree cwd. A project-only key such as `locks.idle_grace` therefore lands in the parent project's file.

Precedence is workspace > project > global > default (see [Layers](#layers)). `workflows.defaults.include` is the one global-file key that may also be set at project and workspace scope: the packs a project's workflow steps start with are a project's choice, so a project may override the machine-wide default. A scope the key doesn't allow (see `overridable_in`) fails with code `scope_not_allowed`, a message that says why in a few words and which `--scope` to use, `details.key`, `details.scope` (the scope as typed) and `details.allowed` (the scopes it does allow, lowest first), and writes nothing. An unknown key fails with `unknown_config_key` (`details.key`), a bad value or an unknown `--scope` with `usage`, and a file that can't be parsed with `config_parse` (`details.path`, `details.reason`; the reason is the parser's message and never quotes a stored value).

`set --json` and `unset --json` print an action document whose row has `workspace` (the name whose file was written, null for the global file), `outcome` (`set`, `unset`, or `noop` for an `unset` of a key that wasn't in that file, which writes and backs up nothing), `key`, `value` (`set` only), `global`, `scope`, `layer`, `file`, `comments_preserved` and `effective`, the key's effective value for the workspace asked about after the write (null for a sensitive key). `effective` has the type `config show` gives the key (a number may be a float, a boolean may be a string). After a restart-required key (on `set` and on `unset`), the text output names the affected daemons: the workspace's own for a `workspace` write, the project and each of its worktrees for a `project` write, every known workspace for a `global` write. Past three workspaces it gives their count and `workspace daemon restart --all` instead of a list. Put a value that starts with a dash after `--`: `workspace config set dev.up -- -x`.

`config show --scope S` keeps the document and changes what each row means. `value`, `source_file`, `line` and `column` come from S's file alone (`value` is null when the key isn't in that file), `effective` and `source` are the resolution up to S (`project`: global < project; `global`: global < default; `workspace`: everything), and `layers[]` stops at S. The document gains `scope` and `scope_layer` (the layer S names for this workspace). Text mode prints S's file. `--json` now works with `--global` (it is `--scope global`).

```sh
workspace config set --scope project handoff.auto true
workspace config set --scope workspace dev.ready_timeout 90s --name myapp.worktree-fix
workspace config set --scope project workflows.defaults.include commits
workspace config unset --scope workspace dev.ready_timeout --name myapp.worktree-fix --json
workspace config show --scope project --json dev.ready_timeout --name myapp.worktree-fix
```

### Layers

Each key lists the layers it may be set in (`overridable_in`, also the **Layers** column of the key table above). The highest layer that holds a value wins; a key with no value anywhere falls back to its built-in default.

| Layer | `--scope` | File | Wins over |
|-------|-----------|------|-----------|
| `worktree` | `workspace` | `~/.config/workspace/projects/<project>.worktree-<name>.yml` | project, global, default |
| `project` | `project` | `~/.config/workspace/projects/<project>.yml` (the main checkout's) | global, default |
| `global` | `global` | `~/.config/workspace/config.yml` | default |

Two things to know about the worktree layer. A worktree with no `.workspace-project` marker has no name of its own for the tool to find, so its worktree-level overrides are ignored there, and `config set --scope workspace` from inside it fails and asks for `--name <project>.worktree-<name>` (`start` and `add` write the marker). And `kill` and `prune` delete the worktree's file, and its overrides with it.

```sh
workspace config set --scope project handoff.auto true
workspace config set --scope workspace dev.ready_timeout 90s
```

### `config edit`

```sh
workspace config edit [--scope SCOPE] [--name NAME] [--json]
```

Opens one layer's file in `$VISUAL`, else `$EDITOR`. The scope defaults to `workspace`, which is the workspace's own file; in a main checkout that is the project's file. It resolves the file as `set`, `get` and `unset` do (same names, `unknown_workspace` for a workspace that isn't known, the same refusal for a worktree with no name) but checks no key. A file that doesn't exist yet is created first, through a temp file and rename, with the one-line header `# workspace config (<layer>). See docs/README.config.md`; an existing file is not touched.

The editor is run without a shell: the variable is split into words (`code --wait` is two) and the path is the last argument, so nothing in the path or the variable is interpreted by a shell. A path to the editor that contains spaces must be quoted in `$EDITOR`. A blank `$VISUAL` or `$EDITOR` counts as unset. If the variable is not a valid command (an unbalanced quote), or the editor can't be run or exits non-zero, the command fails with the error code `editor_failed`. With neither variable set, under `--no-input` (or `WORKSPACE_NO_INPUT`), or when stdin or stdout is not a terminal, it prints the path, opens nothing and exits 0.

Example for a script or an agent that edits the file itself:

```sh
workspace config edit --scope global --json    # just the path
```

With `--json` no editor is opened either; the action document gives the path, which suits a script or an agent that edits the file itself:

```json
{"schema_version":1,"ok":true,"action":"config edit","status":"ok",
 "results":[{"workspace":"api.worktree-fix","outcome":"ready","reason":null,"message":null,"global":false,
  "scope":"workspace","layer":"worktree","file":"/Users/me/.config/workspace/projects/api.worktree-fix.yml","created":true}],
 "warnings":[],"summary":{"ready":1}}
```

Editing by hand is the way to keep comments: `config set` and `unset` rewrite the whole file and drop them. Nothing checks a hand edit, so run `workspace config validate` afterwards.

### `config keys`

```sh
workspace config keys [QUERY] [--settable] [--json]
```

Describes the keys in the schema; it reads no config file and prints no stored value. With no `QUERY` it lists every key on one line: name, type, default (`20s` for a duration, `(unset)` when there is none) and a shortened description. A `QUERY` equal to a key name prints that key in full: description, type (with unit, min, max or choices), default, the layers that may hold it, whether `set` accepts it, when a change applies (`next call`, `next event` or `daemon restart`) and example `workspace config set KEY VALUE` lines. Any other `QUERY` keeps the keys whose name or description contains it as a substring, ignoring case, so `workspace config keys timeout` finds every key whose description mentions a timeout. The list also has a `scope` column (the file the key lives in, `global` or `project`) and a `set` column (`set` when `config set` accepts the key, `-` otherwise), and ends with a footer line pointing at the detail view (text only, never in `--json`). `--settable` keeps only the keys `set` accepts. When nothing matches, it fails with `unknown_config_key` (`details.key`, and `details.settable: true` when `--settable` was given, in which case the message says no *settable* key matches) and a message that points at `workspace config keys`. With `--json` that failure is the usual error document on stdout, exit 1.

`--json` prints one document, also for a single key:

```json
{"schema_version":1,"ok":true,"keys":[
 {"name":"dev.stop_timeout","scope":"project","doc":"Grace period before force-stopping the dev environment, e.g. `20s` or `20`",
  "type":"duration","default":20,"choices":null,"min":null,"max":null,"unit":"seconds",
  "layers":["project"],"settable":true,"applies":"next_call","restart":false,"sensitive":false,
  "examples":["20s","1m"]}]}
```

`scope` is the same field `config show --json` calls `scope`. A few names, `hooks` and `layouts`, exist in both scopes, so a key is identified by `(name, scope)`, not by name alone. `layers` uses the layer names `global`, `project` and `worktree`, while `--scope` takes `global`, `project` and `workspace` (`worktree` is the same as `workspace`). `default` is the value in the unit given (seconds for a duration) and `examples` is empty for a key `set` doesn't accept. Example values come from the key's `examples` in the schema, else from its `choices`; the table above shows them in its Examples column.

### `config show --json`

```sh
workspace config show --name api.worktree-fix --json
```

With a key instead of a workspace, the same document with `keys` filtered to that key's one row:

```sh
workspace config dev.ready_timeout --name api.worktree-fix --json
```

Prints one document with every key in the table above, the value each reader would use, and the file it comes from. It reads the layers the workspace reads, which is not always the file `workspace config` prints: `dev`, `locks`, `alerts`, `handoff`, `commands` and `notes` come from the **parent project's** file even in a worktree (the same file `config set` writes), except `notes.dir`, which a worktree reads from its own file and the main checkout from the project's, `hooks` and `pipeline` from the workspace's own file, and `statusline`, `context`, `launch` and `event_log_compact_threshold` from the global file.

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
- `resolve` says whose file the readers consult: `parent`, `own`, `own_then_parent` (a worktree's own file and never the project's; a main checkout reads the project's; today that is `notes.dir`), `merge` (global, then the workspace's own; the row reports one scope's file), `global`, or `none` (nothing reads it; today that is global `hooks`). `target_layer` is where `config set` writes the key (`worktree` or `project` for a key a worktree owns, depending on the workspace asked about), and null for a key edited by hand. `affects` lists the workspaces that read the file a change lands in. `applies` is `next_call`, `next_event` or `daemon_restart`; treat an unknown value as plain text.
- `sensitive` keys are commands and hooks. Their `value` and `effective` are always null; `masked` is true when the key has a value. Neither `problems` nor `unknown_keys` ever quote a value.
- `problems` holds the problems `config validate` reports for that key, with `severity`, `code`, `message`, `line` and `column`.
- `overridable_in` lists the layers a key can be set in, lowest precedence first. An empty list means the key can't be set per layer.
- `layers[]` lists only the layers that hold a value for the key (lowest precedence first); use `files[].exists` to see which files exist.
- `type` is `command`, `duration`, `percent`, `text`, `path`, `enum`, `regex`, `boolean` or `mapping`.
- `effective_path` appears only on the `notes.dir` and `notes.default_dir` rows (`capabilities` reports `config_json: 2` when a client can rely on it). It is an absolute path with `~` expanded, and cleaned of `..` segments and a trailing slash, or null when it can't be worked out: the rule is relative to a checkout the workspace doesn't have, the rule uses `{branch}` and the checkout has no branch (a detached HEAD), or a file the key depends on can't be parsed. An invalid stored value is ignored, as in `effective`.
- `dev.configured` is a derived, read-only row (it can't be set, and a value written for it in a file is ignored and reported as `not_read`): `effective` is `true` when the project's `dev.up` is set, `false` when it is not, and `null` when the project's file can't be read. It is what makes `start` and `launch` send the `dev` pack, so a reader need not infer it from `dev.up`, whose `value` and `effective` are always masked. `value` is `null`, `masked` is `false` and `source` is `default`.

A file that can't be parsed doesn't fail `config show --json`: it is reported in `files` and its keys are `unreadable`. (Plain `workspace config` still refuses and prints the error.) An unknown workspace is an error document with code `unknown_workspace`.

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
| `escaped_path` | warning | A path key (`notes.dir`, `notes.default_dir`) has a backslash before a space or `~`, as if typed for a shell; config values are used as written, so the directory name would contain the backslash |
| `shared_notes_dir` | warning | `notes.default_dir` is an absolute path (or `~/…`) with no `{workspace}` or `{branch}`, in a project that has worktrees, so they would all share one notes directory |
| `unknown_spine_template` | warning | `spine.template` names no `spine` library entry, so `spine init` would answer `unknown_template` |
| `not_read` | info | The key is set where no reader looks: a parent-scoped key in a worktree's file, or global `hooks` |

New codes may be added; treat an unknown one by its `severity`.

### Config file locations

- **Global:** `~/.config/workspace/config.yml`
- **Project:** `~/.config/workspace/projects/<name>.yml`

### Global settings

<!-- BEGIN GENERATED: global-settings -->
| Setting | Description |
|---------|-------------|
| `context.patterns` | Edited in the file by hand: a mapping of agent kind (`claude`, `codex`, ...) to a regex with exactly one capture group that reads the percent of the context window used from that agent's pane. A kind listed here is read from its pane whatever `context.source` says; Codex has a built-in reading of its "Context N% used" line. `context.pattern` stays the fallback in `scrape` mode for a kind with neither. See [`handoff`](README.handoff.md#codex) |
| `hooks` | Global hooks applied to all projects |
| `layouts` | Default tmux pane layouts |
| `event_log_compact_threshold` | Size warning threshold (e.g., "10kb", "1mb"). Default: 1mb |
<!-- END GENERATED: global-settings -->

### Project settings

<!-- BEGIN GENERATED: project-settings -->
| Setting | Description |
|---------|-------------|
| `dev.configured` | Read-only, shown by `config show --json` only: `effective` is `true` when the project's `dev.up` is set, which is what makes `start` and `launch` send the `dev` pack. Not a key to write |
| `hooks` | Project-specific hooks (e.g., `post_launch`) |
| `layouts` | Project-specific tmux pane layouts |
| `worktree_hooks` | Hooks seeded into new worktrees created from this project |
| `pipeline` | Deprecated (use [`workspace workflow`](README.workflow.md)): pipeline stages (`pipeline.panes`: role, timeout) the agent daemon dispatches work through |
<!-- END GENERATED: project-settings -->

Keys you can set with `workspace config set` are listed in the table above; the settings here are edited by hand.

## Examples

```sh
# Show config for the current directory's workspace
workspace config

# Show config for a specific workspace
workspace config --name myproject

# Print one key's effective value
workspace config dev.stop_timeout

# Print where a workspace's notes go
workspace config notes.dir

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

# Set a key for the whole project, or for one worktree only
workspace config set --scope project handoff.auto true
workspace config set --scope workspace dev.ready_timeout 90s

# Edit a config file by hand, keeping its comments
workspace config edit --scope global
workspace config edit --name myproject.worktree-fix
workspace config edit --scope global --json    # just the path
```

## JSON output

`config edit --json` prints an action document (the action is `config edit`) with one `ready` row carrying `global`, `scope`, `layer`, `file` and `created`; see [`config edit`](#config-edit).

`config set --json` prints an action document (see [README.json.md](README.json.md#actions); the action is `config set`) with one `set` row carrying `key`, `value` and `global`; `workspace` is the project, or null for a global key.
