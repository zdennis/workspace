# workspace promote

Moves the work in a main checkout (its staged, unstaged and untracked changes, plus the commits of the branch it is on) into a new worktree at `.worktrees/<branch>`, leaves the main checkout clean on the default branch, and turns the worktree into a workspace the way [`start`](README.start.md) does. It carries the plan, the spine and chosen notes into the new workspace's notes directory.

## Usage

```sh
workspace promote [BRANCH] [--name PROJECT] [--title TEXT] [--spine[=TEMPLATE] | --no-spine] [--plan[=TITLE]]
                  [--carry-note FILE]... [--launch [--prompt TEXT] [--prompt-timeout DURATION]]
                  [--agent-kind KIND] [--[no-]headless] [--force] [--dry-run] [--json]
```

`BRANCH` is a plain branch name: a new branch made at the main checkout's `HEAD`, the branch the checkout is on, or an existing branch whose tip is `HEAD`. Ticket refs are not accepted; resolve one with `workspace ticket show REF --json` and pass the branch and `--title`. Left out, `BRANCH` means the branch the checkout is on. On the default branch a name is required: the real run refuses with `branch_required` (exit 2), while `--dry-run` answers with the lists and `branch_required: true`.

Nothing is launched unless you pass `--launch`. The usual flow is to run promote from the AI session in the main checkout, seed the new workspace, and then start its agent. The steps are in the built-in `promote` pack: `workspace instructions compose --pack promote` prints it (see [Seeding the new workspace](#seeding-the-new-workspace)).

## Options

| Option | Description |
|--------|-------------|
| `BRANCH` | The branch to move the work to (see above) |
| `--name PROJECT` | The main checkout's workspace, from any directory. Without it, the working directory must be the top of a main checkout. A linked worktree's workspace is `not_main_checkout`; an unknown name is `unknown_workspace` |
| `--title TEXT` | The new workspace's task title |
| `--spine[=TEMPLATE]` | Make the spine (`spine init`) when none was carried; `TEMPLATE` as for `start --spine` |
| `--no-spine` | Make no spine, even when `spine.auto` is true |
| `--plan[=TITLE]` | Make the plan (`plan init`) when none was carried |
| `--carry-note FILE` | Copy a note, a path relative to the main checkout's notes directory, into the new one. Repeatable; never over a file that is already there |
| `--launch` | Launch the new workspace once it is made: with a plan, as `plan start` does, else with `--prompt` |
| `--prompt TEXT` | With `--launch`: text for the agent's first prompt (after the plan's line, when there is a plan) |
| `--prompt-timeout DURATION` | With `--launch`: how long to wait for the agent (default 60s) |
| `--agent-kind KIND` | The new workspace's main agent: `claude`, `codex`, `opencode`, `pi` |
| `--[no-]headless` | With `--launch`: start the session in plain tmux (see [`launch`](README.launch.md)) |
| `--force` | Move even while an agent pane of the main checkout works or waits. The caller's own pane (`$TMUX_PANE`) never counts |
| `--dry-run` | Say what would move and write nothing, not even `info/exclude` |
| `--json` | Print one JSON document on stdout; other output goes to stderr |

## What moves and what stays

Moves:

- Staged, unstaged and untracked changes, with the index kept apart from the working tree (a file both staged and changed again stays that way).
- The commits of the branch: the new branch starts at the main checkout's `HEAD`.
- `IMPLEMENTATION_PLAN.md` and `spine/` from the main notes directory. The old ones are renamed `IMPLEMENTATION_PLAN.md.moved-<time>` and `spine.moved-<time>`, so nothing is deleted. The template's Ship stage is added to the moved spine when it lacks one.
- Each `--carry-note` file, copied.

Stays:

- Ignored files such as `.env`. To get them into new worktrees, use the project's `worktree_hooks` (see [`config`](README.config.md)).
- Untracked nested repositories: listed in `moved.left_behind` with a `left_behind` warning.
- A submodule's own changes: promote refuses (`submodule_changes`). The new worktree's submodules are empty; the `submodules_not_initialized` warning gives the `git submodule update --init` command.
- Locks the main session holds (`devenv`, edit): reported as `locks_held`, not released.
- On the default branch with local commits ahead of `origin`: the new branch has them, the local default is left where it is, and `default_ahead` gives the count and the `git reset --keep` command that moves it back. Promote never resets a branch.
- When you name a branch other than the current one, the current branch is left as it is.

## Order of steps

1. The agent check, first of all: refuses with `agent_working` while a pane of the main checkout's workspace is `working` or `waiting` (`--force` moves anyway). It runs before the git checks, so it can refuse ahead of `detached_head` or `nothing_to_move`. Under `--dry-run` it never refuses; it adds an `agent_working` warning instead.
2. Git checks, which write nothing (all of them run under `--dry-run`): the path is the top of a main checkout; `HEAD` is on a branch; no merge, cherry-pick, revert, bisect or rebase is stopped; no unmerged, intent-to-add or `--assume-unchanged`/`--skip-worktree` files; no submodule with changes; no untracked file where a deleted tracked file was; the default branch exists and is not checked out elsewhere; the target branch is free (a new name, the current branch, or an existing branch whose tip is `HEAD`); `.worktrees/<branch>` is free; there is something to move.
3. `.worktrees/` and the main notes directory are listed in the repository's `info/exclude`. This is the only write before the move, and changes no tracked file.
4. The changes are stashed with one tagged `git stash push --include-untracked`, pinned to `refs/workspace/promote/<id>`, and dropped from the shared stash list. With only commits and no changes, there is no stash.
5. The main checkout switches to the default branch, unless it is already on it.
6. The worktree is added on the target branch.
7. In the worktree, the pinned commit is applied with `--index`, and the result is compared with trees recorded before the stash: the index tree must match, and the working tree must match on every recorded path. An extra file the main checkout did not have (usually written by a hook) is an `extra_untracked` warning, not a failure.
8. The pinned ref is deleted. Only now is the move done.
9. `start` makes the worktree a workspace (config, notes directory, agent hooks, project marker), with no launch, no plan and no spine. Then the notes are carried, and then the spine (when `--spine` or `spine.auto` asks) and the plan (when `--plan` asks) are made if not carried. This order means a fresh plan or spine never hides the carried one.
10. With `--launch`, the agent is started last.

`post-checkout` hooks run in steps 5 and 6; those steps are judged by the resulting state, so a failing hook is a `hook_failed` warning, not a failure.

A failure from step 4 to step 7 is undone in reverse: the worktree and any branch the command made are removed, the main checkout goes back to its branch, the pinned commit is applied there, and the ref is deleted once the trees match. That is `move_failed` with `rolled_back: true`. If undoing fails too, nothing more is tried and the ref stays: `move_incomplete`. It is also the answer when git stored the stash but could not clean the checkout afterwards (`details.step` `stash`). After step 7 nothing is rolled back; every later problem is a warning. A `start` failure after the move is an error that keeps the move and carries `details.moved` and `details.next` (`["workspace start BRANCH"]`, which adopts the worktree).

## JSON documents

`--json` prints one document. The shapes below are pinned by fixtures in `spec/fixtures/promote/`, which a spec checks against real output; read those files for every key and value type.

| Fixture | Document |
|---------|----------|
| `success.json` | A real run: `start`'s keys (`project`, `workspace`, `path`, `branch`, `created`, `launched`, `agent_kind`, `notes_dir`, `task`, `packs`, and `spine`/`plan` when they were made), plus `dry_run`, `branch_required`, `moved`, `notes`, `next`, `warnings` |
| `dry_run.json` | A smaller document, nothing written: `schema_version`, `ok`, `dry_run`, `branch_required`, `project`, `workspace`, `path`, `branch`, `launched` (false), `moved`, `notes`, `next`, `warnings`. `notes` outcomes are `would_move` and `would_copy`; `moved.snapshot` is null |
| `dry_run_branch_required.json` | A dry run on the default branch with no `BRANCH`: `branch_required: true`, and `workspace`, `path`, `branch`, `moved.branch`, `moved.branch_created` are null. The branch checks did not run, so a later run with a name can still be refused by them |
| `agent_working.json` | The `agent_working` error, with `retry` of `--force` |
| `move_failed.json` | The `move_failed` error |
| `move_incomplete.json` | The `move_incomplete` error |

Details worth knowing:

- Paths in `moved` are relative to the checkout, sorted, and capped at 200 per list; `*_count` holds the full count. `path`, `notes_dir` and `moved.main.path` are absolute.
- `moved.snapshot` is null when nothing was uncommitted. `kept: true` only goes with the `snapshot_not_deleted` warning.
- `notes.plan` and `notes.spine` are `moved`, `none` or `skipped` (a clash in the new notes directory; a warning says which). `notes.carried[].outcome` is `copied`, `missing` or `skipped`.
- `next` holds plain command strings that promote never runs: `workspace plan start --name WS` when the plan has tasks, else `workspace launch WS`. It is empty when launched.
- `warnings[]` entries are `{code, message, ...}`. `start`'s plain-text warnings arrive as `{"code": "start_note", "message": ...}`.
- With `--launch`, a prompt that was not delivered is the `launch_failed` warning and exit code 1; the document still says `ok: true`, because the move and the workspace are done.

Errors use the standard envelope (`ok: false`, `error`, `code`, `details`, `retry`). A caller should check `ok` and `code`, not only the exit status.

## Error codes

All refuse before anything changes, except `move_failed` (undone) and `move_incomplete` (kept under a ref). The list is also in [README.json.md](README.json.md#promote-codes).

| Code | `details` |
|------|-----------|
| `not_main_checkout` | `path` |
| `detached_head` | `path` |
| `git_operation_in_progress` | `path`, `operation` (`merge`, `cherry_pick`, `revert`, `bisect`) |
| `rebase_in_progress` | `path` |
| `unmerged_files` | `paths`, `count` |
| `intent_to_add` | `paths`, `count` |
| `submodule_changes` | `paths` |
| `hidden_files` | `paths`, `count` (files marked `--assume-unchanged` or `--skip-worktree`) |
| `path_conflicts` | `paths`, `count` |
| `no_default_branch` | `path` |
| `branch_required` | `from_branch` (a usage error, exit 2) |
| `branch_exists` | `branch`, `commit` |
| `branch_checked_out` | `branch`, `path` (the worktree it is checked out in), `workspace` (its name, or null) |
| `worktree_exists` | `path` |
| `nothing_to_move` | `branch` (the message points at `workspace start BRANCH`) |
| `agent_working` | `workspace`, `panes` (each `pane`, `state`) |
| `stash_failed` | `path` (the stash stored nothing; nothing changed) |
| `move_failed` | `step` (`stash`, `switch`, `worktree_add`, `apply`, `verify`), `rolled_back`, `snapshot` (`ref`, `id`, `kept`, or null) |
| `move_incomplete` | `step`, `steps_done`, `snapshot`, `main_branch`, `worktree` (or null), `recover` |

Also: `usage`, `config_parse` and `unknown_workspace`, and any `start` code after the move (with `details.moved` and `details.next`).

`details.recover` is an array of strings, one shell command each, in order, every one starting with `git -C `, at most 8. Promote never runs them.

## Time budget

Without `--launch`, promote runs local git commands and `start`'s no-launch steps: a stash, a branch switch, a worktree checkout, one stash apply, two tree snapshots, then file writes. On a typical repository this takes 1 to 5 seconds. The parts without a bound are the repository's own `post-checkout` hook, which runs twice, and the size of the tree. The project's `worktree_hooks` are seeded into the new config, not run; they run when the session launches. Allow 60 seconds without `--launch`.

`--launch` also waits for the agent to be ready before typing the first prompt, up to `--prompt-timeout` (default 60s). Allow `--prompt-timeout` plus 60 seconds: 120 seconds at the default.

## Event

One `workspace_promoted` line is written to the event log after a successful move, just after the `worktree_started` line (with `promoted: true`) that `start` writes. It holds names, never paths. A dry run or a failed move writes none. The fields are in [README.event-log.md](README.event-log.md).

## The stash window

The changes travel through git's stash, which is shared by every worktree and every session. Promote finds its entry by a unique tag (never by position), pins it to a private ref and drops it from the list right away. For a few milliseconds between the push and the drop, the entry is on the shared list, and another session's bare `git stash pop` could apply it to that session's checkout instead. Nothing is lost if that happens, but the changes land in the wrong place, and promote's own check then fails and rolls back or stops. This window is accepted in this version.

## Recovery

If a move stops part way and cannot undo itself, the changes are kept under `refs/workspace/promote/<id>`. They are not in `git stash list`. Two things point at them:

- The `move_incomplete` error lists the exact commands in `details.recover`. Run them in order. Usually that is `git -C <path> stash apply --index <sha>`, then `git -C <path> update-ref -d <ref> <sha>` once the work is back; it can start with commands that remove the new worktree or branch or switch the main checkout back. When the undo applied the changes but the check failed, the list holds `git stash show --include-untracked --stat <sha>` instead: the work is already back in the main checkout and the ref is kept for you to inspect, so do not apply it again.
- [`workspace doctor`](README.doctor.md) has a `promote-snapshot` row that warns about each leftover ref in a known project's repository, with the same commands. It only reads; it never deletes a ref.

If `git stash apply` refuses because files are in the way, move them aside and run it again.

## Seeding the new workspace

Promote moves files and the branch; the session that ran it knows the rest. The built-in `promote` pack (`workspace instructions compose --pack promote`, listed by `workspace library list --kind play --scope builtin`) tells that session to:

1. run `workspace promote BRANCH --dry-run --json` and report what will move, choosing the notes to carry;
2. run promote from its own pane with no sub-agent still working, with `--title`, `--spine`, `--plan` and `--carry-note`, and read `workspace` and `notes_dir` from the answer;
3. set the goal and each stage with `workspace spine goal set`, `spine set` and `spine check`, and write the stage text;
4. add the plan's tasks with `workspace plan task add`;
5. write `HANDOFF.md` in the new notes directory;
6. start the new agent with `workspace plan start --name WS` (when there is a plan) or `workspace launch WS --prompt "Read <notes_dir>/HANDOFF.md and continue from it."`;
7. tell the person where the work went, and stop working on it in the main checkout.

`--launch` is the quick path for a person who wants no seeding.

## Examples

```sh
# See what would move, without writing anything
workspace promote fix-login --dry-run --json

# Move the work, make a spine and plan, carry a note
workspace promote fix-login --title "Fix the login bug" --spine --plan --carry-note research-login.md --json

# Move the current branch of the project "api" from any directory, then launch it
workspace promote --name api --launch

# Print the seeding steps
workspace instructions compose --pack promote
```
