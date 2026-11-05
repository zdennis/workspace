# workspace go

Start a workflow with one argument. `go` reads the argument, picks the workflow, prints which one and why, then runs it.

`go` runs a workflow in one of two ways:

- **Here**: in the checkout you are standing in. This only works in a git worktree that `workspace` created (one under `.worktrees/`, with its own workspace) and that is on a branch other than the default branch. Bare `go`, a ref for the branch you are on, and free text with `--here` run here.
- **In a new checkout**: `go` makes (or reuses) `.worktrees/<branch>` with its own workspace and tmux session, waits for its agent, and runs the workflow there. This is `workflow start`. Free text always goes this way unless you give `--here`, even when you are standing in a worktree workspace. The new branch starts from the default branch, so uncommitted work in the worktree you ran `go` from stays behind there.

`--dry-run` shows which one you will get: it prints the decision line (for example `go: rpiv (built in for jira), makes or reuses the worktree workspace for PROJ-123.`) and makes nothing.

## Usage

```sh
workspace go [REF | "TEXT"] [--workflow ID] [--input KEY=VALUE]... [--here] [--text] [--base REF] [--dry-run] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--workflow ID` | Use this workflow instead of the configured one |
| `--input KEY=VALUE` | Set a workflow input; repeatable. Needed only for an input nothing else fills: see [Free text and `task`](#free-text-and-task) |
| `--here` | Run free text in this worktree workspace instead of making a new one. If a run is already going here, add the text to its plan as a task instead: see [Adding to a run already going](#adding-to-a-run-already-going). Refused with `go_here_unavailable` where `go` can't run here, and as a usage error with a ref for another branch |
| `--text` | Read the quoted sentence as plain text: no pull request, issue or ticket is taken out of it, and it is free text as it was before `go` read sentences. A usage error with no argument or one with no whitespace. See [A ticket, pull request or issue in a sentence](#a-ticket-pull-request-or-issue-in-a-sentence) |
| `--base REF` | Start the new branch from this branch, tag or commit instead of the default branch. Useful when the local default branch may be behind origin (`--base origin/main`). Values such as `HEAD` or `HEAD~1` are read in the checkout you run `go` in, not the main checkout. A usage error where `go` runs here, since the checkout starts from where it is. A value git can't find, or one starting with `-`, is refused as `unknown_base` before anything is made, `--dry-run` included. For a branch that already exists the real run ignores the value and adds a warning to `warnings`; `--dry-run` does not show that warning. A foreign branch gets no fork check here, as with `workflow start --base` |
| `--dry-run` | Check everything and create nothing |
| `--json` | Print one JSON document; other output goes to stderr |

## Details

### What the argument means

| You type | `go` reads it as | It runs |
| --- | --- | --- |
| a JIRA key or URL, a pull request (`'#123'` or URL), an issue URL, or a branch | a ref | here when you are in a checkout that is on that branch, else in a new checkout for it (`--here` with a ref for another branch is a usage error) |
| text with a space in it that holds one pull request, issue or ticket | that ref, with the whole text as the task | as for the ref; `--here` and `--text` turn this off |
| other text with a space in it | free text; the new branch's name comes from it | in a new checkout on a new branch; with `--here`, here |
| nothing | no ref | here |

Whitespace is the test for a sentence: a lone word is a ref, never text. A lone word that names a workflow is not read as one: `go rpiv` looks for a branch called `rpiv`. Use `--workflow rpiv` to name a workflow. A lone JIRA key in lowercase (`proj-123`) is a ticket only when its ticket reads, and `--workflow` turns that lookup off, so the word stays a branch name; a branch of that exact name wins, and a miss leaves the word as it was (`unknown_ref` if no such branch).

The branch of a new JIRA ref is the key as written, `PROJ-123`. A branch that matches the key apart from case (`proj-123`) is reused by its own name, local branches first, then origin's, so an older lowercase worktree is found. A key that lowercases to `pr-<n>` or `issue-<n>` (`PR-5`, `ISSUE-7`) keeps its case, since those names belong to pull requests and issues. Ticket keys keep their case everywhere else (the decision line, `--input`, the ticket lookup).

Bare `go` outside a checkout it can run in is a usage error. Type a ref (`workspace go PROJ-123`) or quoted free text (`workspace go "fix the login timeout"`) instead.

### Where it runs here

`go` runs here for bare `go`, a ref for the branch you are on, or free text with `--here`, and then only when all of these hold:

- the directory is a git worktree that `workspace` created, with its own workspace. A worktree made by plain `git worktree add` counts as outside a workspace, as does a main checkout;
- it is on a branch, not a detached HEAD and not in the middle of a rebase;
- the branch is not the default branch or the main checkout's branch;
- the repository is not a bare repository (worktrees of one never run here).

The default branch is read from `origin/HEAD`, else it is `main` or `master`. If neither exists, `go` cannot tell which branch is the default, so it checks only against the branch the main checkout holds. It still runs here in a worktree workspace on any other branch.

If `go` runs here (bare, a ref for the current branch, or free text with `--here`) from the Claude Code pane it would type into, it types nothing and answers `parked`: the caller ends its turn and the run starts after it (see [Resuming from the run's own pane](README.workflow.md#resuming-from-the-runs-own-pane)).

Anywhere else, and for free text without `--here`, `go` makes or reuses a new checkout. `--here` where `go` can't run here is refused with `go_here_unavailable` and starts nothing; it never falls through to a new checkout. It looks for the ref's plain branch name (`PROJ-123`, or the existing branch that matches it apart from case), so a worktree made with `start PROJ-123 --slug` is not found by `go PROJ-123`, which makes a second one; name that branch instead. If the workspace for a worktree is stopped, `--dry-run` passes and the real run then fails at the pane, as `workflow run` does. Bring it up first with `workspace launch NAME`.

### How the workflow is chosen

`go` takes the first of these that applies:

1. `--workflow ID`
2. `workflows.by_ref.<kind>`, where `<kind>` is `jira`, `github_pr`, `github_issue`, `branch` or `prompt` (free text, or no argument)
3. `workflows.default`
4. built in: `pr-feedback` for a pull request, `rpiv` for everything else

Running in this worktree, a setting of the worktree's own wins over the project's. Making or reusing another checkout, only the project's and the global settings count.

Set the config ones with `workspace config set workflows.default rpiv` or `workspace config set workflows.by_ref.jira rpiv`. List the ids with `workspace workflow show`. An id no workflow has is `unknown_workflow`, raised before anything is made; the error lists the known ids.

### A ticket, pull request or issue in a sentence

A sentence without `--here` or `--text` is searched for one pull request, issue or ticket: a GitHub pull request or issue URL, an Atlassian `/browse/` URL, or a bare JIRA key such as `PROJ-123`. When it holds exactly one, `go` runs that ref as if you had typed it alone (its branch, its checks, `fork_pull_request` included) and passes the whole sentence as the task. `go` prints a `go:` line that names the ref.

- A key inside a sentence must be uppercase: `fix PROJ-123` is read, `fix proj-123` is not. Only a lone word may be lowercase.
- Some prefixes are never read as keys, in a sentence or as a lone word: `PR`, `ISSUE`, `UTF`, `RFC`, `CVE` and a few more such as `SHA`, `ISO` and `HTTP`. An Atlassian `/browse/` link is the exception: its key is read whatever the prefix.
- A link beats a bare key: a sentence with one link and one key is read as the link. Two links, or two keys and no link, are not read: the text stays free text and a warning names them (use `workspace go ID --input task=TEXT` to pick one).
- A link is proof enough. A bare key needs its ticket to read (the lookup `ticket show` makes); a key whose ticket is not found or cannot be read leaves the text free text, with a warning.
- A pull request or issue of a repository this project does not track is a mention, not a ref, and a warning says so.
- A refusal on the ref that was read out of the sentence (`branch_not_allowed`, `branch_exists`, `unknown_ref`) ends with the token `go` read and a hint to pass `--text`. A refusal that already names a next command (`details.next`, for a workspace that exists) is left as it was, since `--text` would make a second one.
- `--here` takes the sentence as the task as written, and `--text` does the same for any run: nothing is read out of it.

### Free text and `task`

Free text is enough on its own. It names the new branch and also fills the workflow's `task` input, in a new checkout or, with `--here`, here. `--input task=...` is needed only for a branch or bare `go` with a workflow that requires `task` (`rpiv` does): nothing else fills it, and the run ends with `input_required`, naming the missing input.

```sh
workspace go PROJ-123 --input task="Fix the login timeout"
```

When the text is not used as the task (you gave `--input task`, or the workflow has no `task` input; the text still names a new branch), `go` prints a warning and adds it to `warnings` in the JSON.

### Adding to a run already going

`go --here "TEXT"` with a workflow run already going on this checkout does not start a second run. It adds TEXT as a new task at the end of the workspace's `IMPLEMENTATION_PLAN.md`, as `workspace plan task add` does (the next id after the last, `T9` after `T8`), and prints `go: task for run ID (WORKFLOW at step STEP), added to this workspace's plan.` Nothing is typed into any pane: the run's agent takes the task the next time it reads the plan. With `--dry-run` it says `would add` and writes nothing. In `--json` the row is the `plan task add` row (`outcome` `added`, or `dry_run`) plus `workspace`, `run_id` and `decision` with `route: task`, `source: run` and `workflow` the run's workflow id.

Bare `go --here` with a run going stays `checkout_has_run`: there is no text to add. Without `--here`, a run going does not matter: the text makes a new workspace.

`--workflow`, `--input` and `--base` are usage errors on this path, because the run already has its workflow and inputs and they would be ignored.

Before it writes anything, `go` refuses when the task would not be picked up:

- `checkout_has_run`: the run is at a step from which no later step reads the plan (a workflow such as `investigate` never does, and an `rpiv` run on `verify` has passed `implement`). Leave off `--here` to make a new workspace for the text, or cancel the run (`details.next`).
- `no_plan`: the run's `plan` step has not written the plan file yet. `go` never makes it, because `plan init` would create the file that step is due to write. Run `go` again after the step has, or leave off `--here`. `details.run_id` and `details.step` name the run.
- `plan_done`: the plan is marked `status: done` while the run goes on. Edit the file to reopen it, or leave off `--here`. A plan whose tasks are all checked but whose status is still `active` takes the task, since the run (in `implement`, say) can still pick it up.
- `invalid_task`: the text does not fit one task line (over 500 characters, more than one line, or containing ` -- `). `go` does not reword it.
- `plan_write_conflict`: the plan file kept changing while the task was written, so nothing was written. Run it again.

A plan marked `status: paused` still takes the task, with a warning (printed, and in `warnings`): the agent will not take it until someone resumes the plan with `workspace plan start`.

A task added while an `rpiv-auto-approve` run is in `plan_review` changes the plan's revision. The approval the reviewers write is bound to the revision they read, so the step's check fails. Its `on_fail` sends the run back to `plan` and counts one of that step's retries (`max: 9`), and the plan agent starts again and may rewrite the file, so the new task can be reworded or dropped. Add it before `plan_review` starts, or after the plan is approved.

### Pull requests from forks

A pull request from another repository is refused with `fork_pull_request`: its code would run in an agent that loads its `CLAUDE.md` and hooks. Nothing is made. The error carries the command to use if you trust the code: `workspace start '#N'`, then `workspace workflow run ID` in the workspace it makes.

Every explicit ref gets this check. Bare `go` and free text with `--here` run in a checkout you already work in, so they skip it, as `workflow run` does. Free text without `--here` makes a new checkout and reads no pull request, so there is nothing to check.

### `--json`

The document is the row `workflow run` or `workflow start` prints, plus:

- `decision`: `workflow`, `source` (`flag`, a config key such as `workflows.by_ref.jira`, or `built_in`), `kind` (a ref kind such as `jira`, `github_pr`, `github_issue` or `branch`, or `prompt` for free text; a sentence that held a ref has the ref's kind, not `prompt`), `extracted` (the canonical URL or uppercase key read out of the sentence; `null` when nothing was, so a script tells a ref typed alone from one found in text), `route` (`run` in place, `start` for a new or reused checkout, where nothing is typed into the calling pane, or `task` when `--here` added the text to the plan of a run already going, where nothing is typed into any pane) and `reason`
- `warnings`: strings, including those from `workflow start`

With `--dry-run` the outcome is `dry_run` and nothing was created.

### Refusals

Each leaves nothing behind, `--dry-run` included.

- `go_here_unavailable`: `--here` was given where `go` can't run here: a main checkout, a worktree with no workspace of its own, a detached HEAD, or the default or main checkout's branch. Nothing is started. Drop `--here` for a new checkout. `details.path` is the checkout's root.
- `branch_not_allowed`: the branch is the default branch or the one the main checkout holds, so a run would land on the branch everyone shares. A name that is another name for one of them counts (a branch that points at it, or the same name in other letter case), and so does a ref whose existing checkout holds one. Name a new branch, or reword the text (`go "main !"` makes the name `main`). `details.branch`, `details.path`, `details.reason` (`default_branch` or `main_checkout`).
- `branch_exists`: free text makes the name of a branch that already exists, or differs from one only in letter case. Reword the text, or run the `workspace go BRANCH` command the message gives. For a ref, the existing checkout for it holds another branch or none: switch it back or name another ref. `details.held` is the branch it holds, or null.
- `unknown_base`: `--base` is not a branch, tag or commit of this repository, or starts with `-`. Nothing is made, `--dry-run` included. For a branch that is only on origin, run `git fetch` or give `origin/NAME`. `details.base` is the value.
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

# Free text: a new branch named from it, in a new checkout (also from inside a worktree workspace)
workspace go "try the thing"

# The same, starting from origin's main when the local default branch may be behind it
workspace go "try the thing" --base origin/main

# A sentence holding one ticket, pull request or issue is read as that ref, with the sentence as the task
workspace go "fix the login timeout from PROJ-123"

# The same sentence kept as plain text: a new branch named from it
workspace go --text "fix the login timeout from PROJ-123"

# Free text in a worktree workspace off the default branch: run the workflow here
workspace go --here "try the thing"

# A run is already going here: add the text to its plan as a new task
workspace go --here "also handle the empty list"

# In a worktree workspace off the default branch: run the workflow here
workspace go

# See where it would run and with which workflow, making nothing
workspace go fix-login --workflow investigate --dry-run

# Scripted
workspace go "try the thing" --json
```
