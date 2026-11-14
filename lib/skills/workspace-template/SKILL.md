---
name: workspace-template
description: "Choose, check and apply the tmuxinator template sets that write a workspace tmuxinator config: `template list|show|use|new|edit`, `status` (current, stale, modified), `apply` (--dry-run first), `backup`, `restore`, `adopt`, `import`. Use for tmuxinator pane layout changes or bringing configs up to date. Not starting or ending workspaces: use workspace-lifecycle."
---

Written against workspace 0.123.0; check with the working --help form.

Shared rules for `--json`, exit codes and error codes: [machine-contract](../workspace/references/machine-contract.md).

A tmuxinator template is a set of two files, `project.yml` (standard project) and `worktree.yml` (git worktree), kept as a `template` entry of the library. `start`, `add` and `launch` render a new tmuxinator config from the selected set. Full reference: `docs/README.template.md` in the workspace checkout.

## Which task

| Intent | Commands |
|---|---|
| Change what NEW workspaces get | `template new NAME --from default`, `template edit NAME`, `template use NAME`. Existing configs do not change. |
| Bring EXISTING configs up to date with the selected set | `template status --all`, then `template apply --all --dry-run --diff`, then `template apply --all`. |
| Make a running session take the new layout | `template apply ... --relaunch` (ask first, see Safety). |
| Undo an apply | `template backups list`, then `template restore ID`. |
| A config that shows `untracked` | `template adopt WS`, then `status`. |
| Move sets between machines | `template export DIR`, `template import PATH`. |

## How a set is selected

A set is a folder `template/NAME/`, in the project's library, the global library, or the read-only built-in `default`.

- `tmuxinator.template` names the set for both kinds (default `default`). `tmuxinator.worktree_template` names another for worktree configs; unset, it follows `tmuxinator.template`. Both are layered config keys: global, project, worktree.
- `template use NAME` sets `tmuxinator.template` after checking the set exists (`unknown_template` otherwise). `--kind worktree` sets the worktree key. The layer it writes: with `--scope` it is that layer (`global` or `project`); with none, outside a workspace it is global, but inside one it is the worktree layer in a worktree workspace and the project layer in a main checkout. Pass `--scope global` explicitly when the change is meant for every project.
- Flags by verb: `--scope` is taken only by `list`, `new`, `use`, `export` and `import` (any other verb refuses it with a usage error). `--name WS` is taken by `list`, `show`, `path`, `variables`, `render`, `validate`, `diff`, `new`, `edit`, `use`, `export` and `import`, and defaults to the workspace of the current directory, except that `variables` shows a workspace's values only when `--name` is given explicitly.
- A project's own sets are searched only for a project that already has a tmuxinator config.

## The three levels

| Level | Affects | Set it with |
|---|---|---|
| Global | Every project without a narrower setting | `template use NAME --scope global`, with a set made by `template new NAME --scope global` |
| Project | One project: its main checkout and worktrees | `template new NAME --scope project`, then `template use NAME --scope project` (run in that project) |
| Worktree | One worktree workspace | `template use NAME --name WS` with no `--scope` (the worktree layer is the default inside a worktree workspace) |

`use` changes only configs written from then on. An existing config changes only through `template apply`, plus `--relaunch` (or a manual relaunch) if its session is running. After `use`, existing configs read `stale` (the reason is the set switch).

Trap: `use NAME --scope global` on a set that lives in a project's library passes the existence check, but every other project then gets `unknown_template` at `start`. Make a global set with `new NAME --scope global` first.

## Read verbs (safe)

- `template list [--scope SCOPE] [--name WS]`: every set, with the kinds each is selected for.
- `template show [NAME] [--kind project|worktree]` prints a set's files; `template path [NAME]` says where they are. With no NAME, each kind's selection.
- `template variables [--kind K] [--name WS]`: the placeholders (`{{PROJECT_NAME}}`, `{{WORKSPACE_NAME}}`, `{{AGENT_COMMAND}}`, ...), with a workspace's values under `--name`.
- `template render [NAME | --file FILE] [--kind K] [--name WS | --sample] [--diff]` fills a set and prints it; writes nothing. `--name` needs a render record (`no_render_record` otherwise); `--sample` needs none.
- `template validate [NAME | --file FILE] [--kind K]`: errors exit 1, warnings alone exit 0. Run it after any edit.
- `template diff [NAME] [--against NAME]` compares a set with another (default `default`).
- `template status [WS... | --all | --project [NAME]]` re-renders each config and compares it with the file:

| State | Meaning | Next |
|---|---|---|
| `current` | Equals what the selected set renders today. | Nothing. |
| `stale` | Last render was untouched, but a render today differs; `reasons` says why (the set was switched or changed, or the agent settings did). | `apply`. |
| `modified` | Edited by hand or by another tool. | `apply` skips it; ask before `--force`. |
| `untracked` | No render record, so nothing to render from. | `adopt`. |

## Change a set

`template new NAME [--from NAME] [--scope SCOPE]` copies a set (default `default`) after validating the source; `template_exists`, `invalid_template` and `unknown_template` are the refusals, and the name `legacy` is reserved. `template edit [NAME]` opens both files in `$VISUAL` or `$EDITOR`, then validates them; the built-in set refuses (`template_builtin_readonly`), so `new` a copy first. Under `--json` it opens nothing and only validates; with no editor, under `--no-input` or off a terminal it prints the paths instead. Edit the files with your own tools, then run `validate`.

## Apply to existing configs

`template apply [WS... | --all | --project [NAME]]` re-renders each selected config from its render record with the set that workspace selects now, and writes it when that changes it. Without a selector it acts on the workspace of the current directory.

- `--dry-run` writes nothing, takes no backup, and says `would apply`. `--diff` adds each unified diff. Run both first and read the rows.
- Each config and record is copied into one backup batch first (the `Backup:` line, `backup` in `--json`).
- `modified` is skipped (`template_modified`) unless `--force`; an `adopt` record that was not an exact render (`approx`) is skipped as `template_approx` unless `--force`. `untracked` is skipped even with `--force`.
- `--rollback-all-on-error` stops at the first failure and puts back the whole batch.
- `--relaunch` stops and launches again each workspace whose session was running and whose config was rewritten. It never relaunches the caller's own workspace (the current directory's, or the one holding `$TMUX_PANE`): that row is `skipped` with `relaunch_own_workspace`. Run `workspace relaunch NAME` yourself only if the person asked (see workspace-lifecycle: it goes on in the background and your own pane closes with the session). Other skips: not_active, not_running; warnings `relaunch_not_active` and `relaunch_own_workspace_unknown` (tmux could not place the pane). After a rollback nothing is relaunched.
- Exit codes: skipping is not a failure (exit 0 when everything skipped). `partial` is exit 3, `failed` exit 1. A failed relaunch also makes the run `partial` (exit 3), so read each row's `outcome`, `reason` and, under `--relaunch`, the relaunch field and its relaunch_code.

## Backups, adopt, export and import

- `template backup [WS... | --all | --project]` takes a `manual` batch. `template backups list` shows batches (newest first); `template backups prune` deletes batches beyond the limits; run it only when asked. It applies the limits `tmuxinator.backups.keep` (default 20) and `.max_age`.
- `template restore BACKUP_ID [WS|TEMPLATE...] [--force] [--relaunch]` puts back configs and records as the batch saw them, after taking a batch of its own (reason `restore`), so a restore can be undone. A file changed since the batch is `restore_conflict` unless `--force`. An unknown id is `backup_not_found`. It has no `--dry-run`, and with no WS it restores the whole batch: run `backups list` first and name the WS. Only a restore that rewrote a config relaunches under `--relaunch`.
- `doctor --fix` also runs `apply` without `--force` and with no dry run (`modified` and `approx` configs are skipped).
- `template adopt [WS... | --all | --project] [--dry-run]` builds the render record of an `untracked` config from the file; it never rewrites the config. The result is `exact` (reads `current`) or `approx` (reads `modified`).
- `template export DIR [--scope SCOPE] [--force]` writes the sets as plain files. `template import [PATH] [--scope SCOPE] [--force]` (a bare import with no edited legacy copy writes nothing and says so; global scope only) validates every set first, backs up a set it replaces, and refuses one a config key selects (`template_in_use`) unless `--force`.

## Safety

- Run `apply --dry-run --diff` (or `--json --dry-run`) and read it before any real `apply`.
- Do not add `--force` to `apply`, `restore` or `import` to get past a skip or refusal unless the person asked: `modified` means someone edited the file by hand, and `--force` overwrites that edit (the backup keeps a copy).
- Do not use `--relaunch` unasked. It stops running sessions and every agent in their panes. Never relaunch the workspace you are running in.
- `use`, `new`, `edit` and `import` change what future configs render from (a bare `import`, with no PATH, builds the global set `local` and sets the global `tmuxinator.template` to it); ask the person first for `use` at global scope or `import`; `apply` and `restore` change existing files. Say which you did.
- With `--all` or `--project`, `apply` writes many workspaces. Prefer named workspaces unless the person asked for all.
- Unattended with no person to ask: record the decision with `workspace ask` and stop. See workspace-inbox.

Add `--json --no-input` where `--help` lists `--json`; every verb accepts `--json`.
