# workspace rename

Gives a stopped worktree workspace a new branch, and with it a new directory, workspace name and tmux session. It moves the worktree with `git worktree move`, renames the branch with `git branch -m`, and rewrites every file workspace keeps under the old name. Nothing is launched afterwards.

## Usage

```sh
workspace rename [WORKSPACE] NEW [--name WS] [--dry-run] [--json]
```

`NEW` is the new branch name. The directory, workspace name and session follow from it, as in [`start`](README.start.md); the new directory sits beside the old one. An adopted worktree stays in its own parent directory.

The workspace is the one named, else the one the current directory is in. Name it either as `WORKSPACE` before `NEW` or with `--name`, not both.

## The flow

```sh
workspace stop
workspace rename fix-login-v2
workspace restore <new workspace name>
```

The workspace must be stopped first: a tmux session or a running agent daemon is refused with `workspace_running`. Renaming beside live panes damages the agent's session. Claude Code's shell falls back to `$HOME` after the directory moves, and a write to the old absolute path recreates the old directory, so work lands outside the checkout.

The command prints the `restore` line to run next (`next` in `--json`).

## Options

| Option | Description |
|--------|-------------|
| `WORKSPACE` | The workspace to rename, before `NEW` |
| `NEW` | The new branch name |
| `--name WS` | The workspace to rename, as a flag. Not with `WORKSPACE` |
| `--dry-run` | Print the plan and any refusal; change nothing |
| `--json` | Print one document on stdout; text goes to stderr. A refusal is the error envelope (see [JSON output](README.json.md#rename-codes)) |

## What moves

- The worktree directory, and the branch, with its `branch.<name>.*` git config.
- The tmuxinator config `workspace.<name>.yml`: file name, `name:`, `root:`, the session targets, the `workspace-<session>` window and the banner. It is renamed last, so a config under the new name means the stores are done.
- The workspace's settings file under `~/.config/workspace/projects/`, the agent's socket, log and lock files, the state directory, the key in `~/.workspace-state.json` and the `.workspace-project` marker. These are the steps of the mixed-case migration in [`agentd`](README.agentd.md#renaming-a-mixed-case-workspace); both use the same code.
- The workspace's inbox file, with the scope on each item. Inbox ack ids are left as they are, so at worst an acked derived row comes back.
- The active task (`workspace`, `branch`, `path`) and the hook-event files.
- The session-ledger rows and pane bindings, under the new name and path, so `restore` finds them.

The remote branch is not touched (see below).

## Notes

The notes directory moves only when it is where the project's rule would put it for the old names: `notes.default_dir`, else the main checkout's notes plus the sanitized branch. It then goes to where the rule puts it for the new names, and `notes.dir` is written to match. `plan.notes.action` in the dry run says which case applies.

| `notes.action` | When |
|----------------|------|
| `move` | A directory of its own, at the rule's old location |
| `with_checkout` | Inside the checkout; it goes with the worktree |
| `stays` | `custom` (you set `notes.dir` to somewhere else), `same` (the rule gives the same directory), `nested` (the new place is inside the old one or the other way round, with a `notes_nested` warning) or `unresolved` (the location could not be read, with a `notes_unresolved` warning) |

A notes target that already exists is refused (`rename_target_taken`, `notes_target`), and so is a move to another volume (`rename_notes_other_volume`).

## Refusals

A refusal changes nothing. The full list with `details` is in [JSON output](README.json.md#rename-codes).

| Code | Cause |
|------|-------|
| `workspace_running` | A tmux session or agent daemon exists. Run `workspace stop` |
| `run_active` | A workflow run is going on the checkout, a gate wait included |
| `dev_lock_held` | The checkout holds the `devenv` lock. Run `workspace dev down` |
| `rename_main_checkout`, `rename_not_worktree` | A main checkout, or a workspace with no `.worktree-` part in its name. An adopted worktree is allowed |
| `rename_pull_request_branch` | The old or the new branch is a `pr-N` branch |
| `rename_no_change`, `rename_case_only` | `NEW` is the current name, or differs only in case |
| `rename_invalid_name` | Not a branch name git accepts, or too long for a config file name |
| `rename_target_taken` | The new branch, directory, config, state, session or notes target exists, a branch conflicts as a ref (`a` against `a/b`), or files a killed workspace left under the new name stand in the way (settings, socket, log, inbox, hook events); `details.taken` lists them and `details.fix`, for leftovers that hold no data of yours, gives the `rm` |
| `rename_notes_other_volume` | The notes would cross to another volume; move them by hand and set `notes.dir` |
| `rename_locked_worktree` | The worktree is locked; `git worktree unlock PATH` |
| `rename_in_progress` | An earlier rename is unfinished (see below) |
| `detached_head`, `rebase_in_progress` | The checkout has no branch, or a rebase is stopped |
| `unknown_workspace`, `checkout_missing` | No such workspace, or its checkout is gone |

## Finishing a half-done rename

A journal file is written before the first git step. If the two git steps fail they are undone in reverse and the command ends in `rename_failed`: nothing changed, no journal left. A signal (INT, TERM, HUP) waits for the step under way, then stops the same way.

A failure after the git steps keeps the journal and ends in `rename_incomplete`. The message prints the command that finishes it; run it again, from anywhere. Each step judges what is done by the state it finds, so a re-run skips finished work. A different `NEW` while a journal stands is refused (`rename_in_progress`). If no tmuxinator config is left under either name, a re-run can't help; `details.fix` gives the `rm` of the journal, and `workspace start` remakes the workspace.

## The agent's conversation

`~/.claude` is not touched. Claude Code finds a conversation by the checkout's path, and `claude --resume ID` works from the new path without moving a file, but `--continue` says `No conversation found`.

- `workspace restore <new workspace name>` resumes each agent session, because the ledger rows were carried to the new name.
- A plain `workspace launch <new workspace name>` starts a new conversation (the `transcript_not_continued` warning says so).
- A session ended by hand before `workspace stop` has no resumable end in the ledger, so `restore` doesn't resume it.

## What goes stale

Anything that stored the absolute path of the old directory keeps pointing at it, and the rename cannot fix that:

- `node_modules/.bin` links and scripts
- Python virtualenvs
- build caches and compiled output (bundler, webpack, Rust `target/`, and similar)

Reinstall or rebuild after the rename. Delete the cache if a tool misbehaves.

## The remote branch

The remote branch is left alone, and the local branch keeps tracking `origin/<old>`. Unsetting the upstream would make the next push create a second remote branch and leave the pull request behind. The result:

- `workspace push` refuses with `push_rejected` (`details.reason` `upstream_mismatch`) until you rename or unset the upstream. The `upstream_other_name` warning says so.
- `workspace prune` looks a pull request up by the local branch name, so it no longer finds one opened from the old name (`prune_pull_request` warning).
- Whether `gh pr view` follows `branch.<new>.merge` to the pull request was not proven. Check with `gh pr view` before relying on it.

To rename the remote branch by hand, from the renamed checkout:

```sh
git push origin NEW:NEW                      # create the new remote branch
git push origin --delete OLD                 # remove the old one
git branch --set-upstream-to=origin/NEW NEW
```

Spell out `NEW:NEW`: with `push.default` set to `upstream` or `tracking`, a bare `NEW` pushes to the old remote branch. Deleting the old branch closes a pull request opened from it, so open a new one or use GitHub's branch rename instead.

A pull request closes when its head branch is deleted, and GitHub can't retarget one. If one is open from `OLD`, open a new one from `NEW`.

## Event log

A finished rename writes a `workspace_renamed` line with `branch`, `from_branch`, `session` and `from_session` on top of the fields the lowercase migration writes (see [the event log](README.event-log.md)).

## Examples

```sh
workspace rename fix-login-v2                                  # the stopped workspace you are in
workspace rename --dry-run fix-login-v2                        # the plan and any refusal; nothing changes
workspace rename myproject.worktree-fix-login fix-login-v2     # name the workspace first, from anywhere
workspace rename fix-login-v2 --name myproject.worktree-fix-login
workspace rename fix-login-v2 --json                           # one document: plan, warnings and next
```
