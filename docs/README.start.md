# workspace start

Create a git worktree and launch it as a workspace project.

## Usage

```sh
workspace start [options] <jira-key|jira-url|pr-url|pr-ref|issue-url|branch>
```

## Options

| Option | Description |
|--------|-------------|
| `--prompt PROMPT` | Send an initial prompt to the coding agent once it is ready (up to 60s); exits 1 if it can't be sent. See [`launch`](README.launch.md#details) |
| `--prompt-timeout DURATION` | How long to wait for the coding agent to be ready for `--prompt` (e.g. `90s`, `2m`, or a plain number of seconds); default 60s |
| `--base REF` | Branch/ref a new branch is created from, instead of prompting |
| `--yes` | Accept every default instead of prompting (e.g. the default base branch) |
| `--title TITLE` | A human title for the workspace's task; it is the first `display_label` of its panes in [`sessions --json`](README.sessions.md). See [Tasks](#tasks) |
| `--headless` / `--no-headless` | Start the session in the background with plain tmux instead of iTerm2; the default follows [`launch`](README.launch.md#headless) |
| `--json` | Emit the JSON schema below instead of plain text; never prompts. Only the JSON document goes to stdout — progress and warnings go to stderr or the `warnings` field (see [`--json` output](#--json-output)) |

## Accepted Inputs

| Input | Example | Behavior |
|-------|---------|----------|
| JIRA issue key | `PROJ-123` | Used as branch name |
| JIRA URL | `https://mycompany.atlassian.net/browse/PROJ-123` | Extracts issue key |
| GitHub PR URL | `https://github.com/owner/repo/pull/471` | Checks the PR out with `gh pr checkout --worktree` as branch `pr-471` in `.worktrees/pr-471`; works for PRs from forks |
| GitHub PR ref | `#471` or `owner/repo#471` | Same as the PR URL; `#471` means a PR of the current repo. Quote `#n` (`'#471'`), or your shell treats it as a comment. Run it from a checkout of the repo the PR belongs to |
| GitHub issue URL | `https://github.com/owner/repo/issues/123` | Creates branch `issue-123` |
| Branch name | `user/PROJ-123` | Used as-is |

## Details

A pull request is always checked out by `gh pr checkout <n> --worktree <path> --branch pr-<n>`, never by its head branch name, so a PR from a fork can't be mistaken for a branch of your repo. The local branch is `pr-<n>`; `--base` is ignored (with a note). Re-running `start` for the same PR reuses its worktree. Needs a `gh` recent enough to have `--worktree` (the error says so if not).

Must be run from within a git repository. Creates a worktree in `.worktrees/` under the project root, generates a tmuxinator config, and launches it. When run from inside a linked worktree, `start` resolves the parent repo first — the worktree is created under the parent repo's `.worktrees/` and named after the parent project, so an existing session is reused rather than a nested workspace created (this applies when the worktree belongs to the surrounding repo; a standalone repo nested inside a worktree, and worktrees of a bare clone, keep the cwd repo's own root).

If the branch already exists (locally or remotely), it checks it out. If not, it prompts you to choose a base branch for creation.

If multiple remote branches match your input, you'll be prompted to select one or create a new branch.

If a worktree for the branch already exists at a non-standard location (created outside of workspace via `git worktree add`), it is automatically adopted — a tmuxinator config and project marker are created, and the worktree is launched without being recreated.

Before launching, `start` installs each detected coding agent's hooks (session monitoring, edit lock enforcement) and — for Claude Code — `statusLine` routing through `workspace statusline` into the worktree's `.claude/settings.json`, so `workspace handoff check` and `sessions --json` can read the agent's context usage from the worktree right away. This is idempotent and backs the settings file up first; an existing statusLine command is preserved into the global `statusline.command` config (see [workspace statusline](README.statusline.md)).

### Non-interactive use (scripts, agents)

`start` never blocks on stdin when stdin isn't a TTY. Whenever it would otherwise
prompt, it instead:

- uses `--base` if given, for the base-branch choice;
- uses `--yes`'s default if given (the default branch, for the base-branch choice;
  "create a new branch" for an ambiguous match);
- otherwise raises a usage error naming `--base`/`--yes` rather than guessing.

`--json` never prompts either, regardless of whether stdin is a TTY — pass `--base`
and/or `--yes` alongside it when the branch might need to be created.

### Tasks

`start` records a task for the new workspace: its title (`--title`, optional), the input it started from (`ref`), its branch and worktree path. The record is one JSON file, `<id>.json`, under `~/.local/state/workspace/.tasks/` (`$XDG_STATE_HOME/workspace/.tasks/`), mode 0600, written under a lock so concurrent `start`s never clobber each other. It lives there rather than in the worktree because removing a worktree deletes its untracked files.

The task id is exported as `WORKSPACE_TASK` in every pane of the workspace, through a `pre_window:` line the worktree template writes into the workspace's tmuxinator config. Run `workspace init --force` once to refresh an installed template that predates it; a workspace whose config already exists keeps the config it has, so its panes get no `WORKSPACE_TASK`. Starting a workspace that already has an active task keeps that task, and a `--title` replaces its title.

[`finish`](README.finish.md) and [`kill`](README.kill.md) archive the task, moving it to `.tasks/archive/` with an `outcome` (`merged` for `finish`, `abandoned` for `kill`, `discarded` for `kill --force`) and `archived_at`. The newest 200 archived tasks are kept. [`sessions --json`](README.sessions.md) reports the active task and a status derived from the panes' states.

### `--json` output

On success, one line of JSON on stdout (nothing else is written to stdout under
`--json`):

```json
{"schema_version":1,"project":"myproject","workspace":"myproject.worktree-PROJ-123","path":"/path/to/.worktrees/PROJ-123","branch":"PROJ-123","base":null,"created":true,"headless":false}
```

- `project` — the parent project name
- `workspace` — the generated tmuxinator config name
- `path` — the worktree's filesystem path
- `branch` — the branch checked out in the worktree
- `base` — the ref the branch was created from, or `null` when the branch (or
  worktree) already existed
- `created` — whether the worktree was created by this run, as opposed to reused
  or adopted
- `task` — the workspace's task, `{"id", "title"}` (see [Tasks](#tasks))
- `headless` — whether the session was started headless (see
  [`launch`](README.launch.md#headless))
- `session_reused` — present only when the workspace's tmux session was
  already running (headless or windowed), in which case it was attached to as
  it is instead of started again. Running `start` again for the same
  workspace is safe this way
- `warnings` — present only when non-empty; notes about a flag that was silently
  adjusted, e.g. `--base` ignored because the branch already existed, a
  statusLine command displaced during worktree settings installation (see
  [`workspace statusline`](README.statusline.md)), or run from inside a
  worktree ("run from inside a linked worktree; using parent repo …")

On a hard error (bad input, `--base`/`--yes` needed, git failure), exits 1 with
the error on stdout instead of the success doc:

```json
{"schema_version":1,"ok":false,"error":"..."}
```

The worktree can also be created successfully but the `--prompt` fail to reach
the coding agent. In that case the success doc above is still emitted, but with
`error` and `prompt_failures` added and exit code 1:

```json
{"schema_version":1,"project":"myproject","workspace":"myproject.worktree-PROJ-123","path":"/path/to/.worktrees/PROJ-123","branch":"PROJ-123","base":null,"created":true,"headless":false,"error":"Prompt was not sent to every workspace.","prompt_failures":{"myproject.worktree-PROJ-123":"agent never became ready"}}
```

Headless, when tmuxinator can't start the session (it fails, times out after 60
seconds, or its session never appears), the success doc is emitted
with `error` set to `Could not start the workspace session: <reason>` (and no
`prompt_failures`), and the exit code is 1.

If a flag was silently adjusted — e.g. `--base` passed for a branch/worktree that
already existed — the success doc includes a `warnings` array instead of printing
to stderr:

```json
{"schema_version":1,"project":"myproject","workspace":"myproject.worktree-PROJ-123","path":"/path/to/.worktrees/PROJ-123","branch":"PROJ-123","base":null,"created":false,"headless":false,"warnings":["Note: --base ignored; branch 'PROJ-123' already exists."]}
```

## Examples

```sh
# Start from a JIRA key
workspace start PROJ-123

# Start from a GitHub PR
workspace start https://github.com/org/repo/pull/471

# Start from a PR ref of the current repo, or of another repo
workspace start '#471'
workspace start org/repo#471

# Start from a GitHub issue
workspace start https://github.com/org/repo/issues/42

# Start from a branch name
workspace start feature/my-feature

# Start with an initial prompt for Claude
workspace start PROJ-123 --prompt "Fix the login bug"

# Start in the background with plain tmux, e.g. from CI
workspace start PROJ-123 --headless --yes --json

# Non-interactive, from a script or agent
workspace start PROJ-123 --base main --yes --json
```
