# workspace go

Start a workflow with one argument. `go` reads the argument, picks the workflow, prints which one and why, then runs it.

`go` runs a workflow in one of two ways:

- **Here**: in the checkout you are standing in. This only works in a git worktree that `workspace` created (one under `.worktrees/`, with its own workspace) and that is on a branch other than the default branch.
- **In a new checkout**: `go` makes (or reuses) `.worktrees/<branch>` with its own workspace and tmux session, waits for its agent, and runs the workflow there. This is `workflow start`.

`--dry-run` shows which one you will get: it prints the decision line (for example `go: rpiv (built in for jira), makes or reuses the worktree workspace for PROJ-123.`) and makes nothing.

## Usage

```sh
workspace go [REF | "TEXT"] [--workflow ID] [--input KEY=VALUE]... [--dry-run] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--workflow ID` | Use this workflow instead of the configured one |
| `--input KEY=VALUE` | Set a workflow input; repeatable. Needed only for an input nothing else fills: see [Free text and `task`](#free-text-and-task) |
| `--dry-run` | Check everything and create nothing |
| `--json` | Print one JSON document; other output goes to stderr |

## Details

### What the argument means

| You type | `go` reads it as | It runs |
| --- | --- | --- |
| a JIRA key or URL, a pull request (`'#123'` or URL), an issue URL, or a branch | a ref | here when you are in a checkout that is on that branch, else in a new checkout for it |
| text with a space in it | free text; the new branch's name comes from it | here, else in a new checkout on a new branch |
| nothing | no ref | here |

Whitespace is the test, so a URL inside a sentence is free text, not a ref. A lone word that names a workflow is not read as one: `go rpiv` looks for a branch called `rpiv`. Use `--workflow rpiv` to name a workflow.

Bare `go` outside a checkout it can run in is a usage error. Type a ref (`workspace go PROJ-123`) or quoted free text (`workspace go "fix the login timeout"`) instead.

### Where it runs here

`go` runs here only when all of these hold:

- the directory is a git worktree that `workspace` created, with its own workspace. A worktree made by plain `git worktree add` counts as outside a workspace, as does a main checkout;
- it is on a branch, not a detached HEAD and not in the middle of a rebase;
- the branch is not the default branch or the main checkout's branch;
- the repository is not a bare repository (worktrees of one never run here).

The default branch is read from `origin/HEAD`, else it is `main` or `master`. If neither exists, `go` cannot tell which branch is the default, so it checks only against the branch the main checkout holds. It still runs here in a worktree workspace on any other branch.

Anywhere else `go` makes or reuses a new checkout. It looks for the ref's plain branch name, so a worktree made with `start PROJ-123 --slug` is not found by `go PROJ-123`, which makes a second one; name that branch instead. If the workspace for a worktree is stopped, `--dry-run` passes and the real run then fails at the pane, as `workflow run` does. Bring it up first with `workspace launch NAME`.

### How the workflow is chosen

`go` takes the first of these that applies:

1. `--workflow ID`
2. `workflows.by_ref.<kind>`, where `<kind>` is `jira`, `github_pr`, `github_issue`, `branch` or `prompt` (free text, or no argument)
3. `workflows.default`
4. built in: `pr-feedback` for a pull request, `rpiv` for everything else

Running in this worktree, a setting of the worktree's own wins over the project's. Making or reusing another checkout, only the project's and the global settings count.

Set the config ones with `workspace config set workflows.default rpiv` or `workspace config set workflows.by_ref.jira rpiv`. List the ids with `workspace workflow show`. An id no workflow has is `unknown_workflow`, raised before anything is made; the error lists the known ids.

### Free text and `task`

Free text is enough on its own. It names the new branch and also fills the workflow's `task` input, here or in a new checkout. `--input task=...` is needed only for a branch or bare `go` with a workflow that requires `task` (`rpiv` does): nothing else fills it, and the run ends with `input_required`, naming the missing input.

```sh
workspace go PROJ-123 --input task="Fix the login timeout"
```

When the text is not used as the task (you gave `--input task`, or the workflow has no `task` input; the text still names a new branch), `go` prints a warning and adds it to `warnings` in the JSON.

### Pull requests from forks

A pull request from another repository is refused with `fork_pull_request`: its code would run in an agent that loads its `CLAUDE.md` and hooks. Nothing is made. The error carries the command to use if you trust the code: `workspace start '#N'`, then `workspace workflow run ID` in the workspace it makes.

Every explicit ref gets this check. Bare `go` and free text run in a checkout you already work in, so they skip it, as `workflow run` does.

### `--json`

The document is the row `workflow run` or `workflow start` prints, plus:

- `decision`: `workflow`, `source` (`flag`, a config key such as `workflows.by_ref.jira`, or `built_in`), `kind`, `route` (`run` or `start`) and `reason`
- `warnings`: strings, including those from `workflow start`

With `--dry-run` the outcome is `dry_run` and nothing was created.

### Refusals

Each leaves nothing behind, `--dry-run` included.

- `branch_not_allowed`: the branch is the default branch or the one the main checkout holds, so a run would land on the branch everyone shares. A name that is another name for one of them counts (a branch that points at it, or the same name in other letter case), and so does a ref whose existing checkout holds one. Name a new branch, or reword the text (`go "main !"` makes the name `main`). `details.branch`, `details.path`, `details.reason` (`default_branch` or `main_checkout`).
- `branch_exists`: free text makes the name of a branch that already exists, or differs from one only in letter case. Reword the text, or run the `workspace go BRANCH` command the message gives. For a ref, the existing checkout for it holds another branch or none: switch it back or name another ref. `details.held` is the branch it holds, or null.
- `unknown_ref`: no branch, ticket or pull request has that name. For a branch that is only on origin, run `git fetch` and retry. If the name differs from a local branch only in letter case, or is origin's name for it (`origin/fix`), use the real name in `details.did_you_mean`; `--workflow` does not change that.
- `workflow_needs_claude`: the workspace's agent is not Claude Code, and the steps need a Claude Code pane. Nothing is made. Use `workspace workflow start ID REF --agent-kind claude`, or `workspace workflow run ID` in a workspace that runs Claude Code.

Three codes come from `workflow start` and reach `go` as they are:

- `fork_pull_request`: see above.
- `dirty_worktree`: the checkout has uncommitted changes to tracked files and the workflow needs it clean. Commit or stash them, and run again.
- `ticket_source_unavailable`: `gh` or `jira` is not installed, did not answer in time, or failed (`details.source`). Install or log in to it, and run again.

The other codes are those of `workflow start` and `workflow run`: see [workflow](README.workflow.md). All codes are listed in [JSON output](README.json.md).

## Examples

```sh
# A ticket: make or reuse its checkout and start the chosen workflow
workspace go PROJ-123 --input task="Fix the login timeout"

# Free text: a new branch named from it, in a new checkout
workspace go "try the thing"

# In a worktree workspace off the default branch: run the workflow here
workspace go

# See where it would run and with which workflow, making nothing
workspace go fix-login --workflow investigate --dry-run

# Scripted
workspace go "try the thing" --json
```
