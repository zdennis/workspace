# workspace start

Create a git worktree and launch it as a workspace project.

## Usage

```sh
workspace start [options] <jira-key|jira-url|pr-url|issue-url|branch>
```

## Options

| Option | Description |
|--------|-------------|
| `--prompt PROMPT` | Send an initial prompt to the coding agent once it is ready (up to 60s); exits 1 if it can't be sent. See [`launch`](README.launch.md#details) |
| `--prompt-timeout DURATION` | How long to wait for the coding agent to be ready for `--prompt` (e.g. `90s`, `2m`, or a plain number of seconds); default 60s |
| `--base REF` | Branch/ref a new branch is created from, instead of prompting |
| `--yes` | Accept every default instead of prompting (e.g. the default base branch) |
| `--headless` / `--no-headless` | Start the session in the background with plain tmux instead of iTerm2; the default follows [`launch`](README.launch.md#headless) |
| `--json` | Emit the JSON schema below instead of plain text; never prompts. Only the JSON document goes to stdout — progress and warnings go to stderr or the `warnings` field (see [`--json` output](#--json-output)) |

## Accepted Inputs

| Input | Example | Behavior |
|-------|---------|----------|
| JIRA issue key | `PROJ-123` | Used as branch name |
| JIRA URL | `https://mycompany.atlassian.net/browse/PROJ-123` | Extracts issue key |
| GitHub PR URL | `https://github.com/owner/repo/pull/471` | Fetches branch name via `gh` |
| GitHub issue URL | `https://github.com/owner/repo/issues/123` | Creates branch `issue-123` |
| Branch name | `user/PROJ-123` | Used as-is |

## Details

Must be run from within a git repository. Creates a worktree in `.worktrees/` under the project root, generates a tmuxinator config, and launches it.

If the branch already exists (locally or remotely), it checks it out. If not, it prompts you to choose a base branch for creation.

If multiple remote branches match your input, you'll be prompted to select one or create a new branch.

If a worktree for the branch already exists at a non-standard location (created outside of workspace via `git worktree add`), it is automatically adopted — a tmuxinator config and project marker are created, and the worktree is launched without being recreated.

### Non-interactive use (scripts, agents)

`start` never blocks on stdin when stdin isn't a TTY. Whenever it would otherwise
prompt, it instead:

- uses `--base` if given, for the base-branch choice;
- uses `--yes`'s default if given (the default branch, for the base-branch choice;
  "create a new branch" for an ambiguous match);
- otherwise raises a usage error naming `--base`/`--yes` rather than guessing.

`--json` never prompts either, regardless of whether stdin is a TTY — pass `--base`
and/or `--yes` alongside it when the branch might need to be created.

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
- `headless` — whether the session was started headless (see
  [`launch`](README.launch.md#headless))
- `session_reused` — present only when the workspace's tmux session was
  already running (headless or windowed), in which case it was attached to as
  it is instead of started again. Running `start` again for the same
  workspace is safe this way
- `warnings` — present only when non-empty; notes about a flag that was silently
  adjusted, e.g. `--base` ignored because the branch already existed

On a hard error (bad input, `--base`/`--yes` needed, git failure), exits 1 with
the error on stdout instead of the success doc:

```json
{"schema_version":1,"error":"..."}
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
