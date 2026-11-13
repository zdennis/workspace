# workspace template

Chooses, checks and re-renders the tmuxinator templates that `start`, `add` and `launch` write a workspace's tmuxinator config from. A tmuxinator template is a set of two files, `project.yml` for a standard project and `worktree.yml` for a git worktree, kept as a `template` entry of the [library](README.library.md). Workspace ships one, `default`; you can make your own, select it, and apply it to the configs that already exist, with a backup of each file before it is written.

## Usage

```sh
workspace template list [--scope SCOPE] [--name WS] [--json]
workspace template show [NAME] [--kind KIND] [--name WS] [--json]
workspace template path [NAME] [--kind KIND] [--name WS] [--json]
workspace template variables [--kind KIND] [--name WS] [--json]
workspace template render [NAME | --file FILE] [--kind KIND] [--name WS | --sample] [--diff] [--json]
workspace template validate [NAME | --file FILE] [--kind KIND] [--name WS] [--json]
workspace template diff [NAME] [--against NAME] [--kind KIND] [--name WS] [--json]
workspace template new NAME [--from NAME] [--scope SCOPE] [--name WS] [--json]
workspace template edit [NAME] [--kind KIND] [--name WS] [--json]
workspace template use NAME [--kind KIND] [--scope SCOPE] [--name WS] [--json]
workspace template status [WS...] [--all | --project [NAME]] [--json]
workspace template apply [WS...] [--all | --project [NAME]] [--dry-run] [--diff] [--force] [--rollback-all-on-error] [--relaunch] [--json]
workspace template adopt [WS...] [--all | --project [NAME]] [--dry-run] [--json]
workspace template backup [WS...] [--all | --project [NAME]] [--json]
workspace template backups list [--json]
workspace template backups prune [--json]
workspace template restore BACKUP_ID [WS|TEMPLATE...] [--force] [--relaunch] [--json]
workspace template export DIR [--scope SCOPE] [--force] [--json]
workspace template import [PATH] [--scope SCOPE] [--force] [--json]
```

`workspace template --help` lists the verbs and `workspace template VERB --help` gives each one's options.

## Changing the layout of every workspace

Make your own copy of the default set, edit it, check it and select it:

```sh
workspace template new team --from default
workspace template edit team          # opens both files in $VISUAL or $EDITOR, then validates them
workspace template use team           # new configs render from team
```

`use` changes only configs written from then on. To bring the existing ones along, look first, then apply:

```sh
workspace template status --all
workspace template apply --all --dry-run --diff
workspace template apply --all
```

A running session keeps its old layout until it is relaunched: `workspace template apply --all --relaunch` stops each running workspace whose config it rewrote and launches it again (never the one you run it from, which it names for you to relaunch by hand; nothing after `--rollback-all-on-error` rolled back), and `template restore ID --relaunch` does the same for the workspaces whose config it puts back. Every config `apply` writes is copied into a backup batch first, and `workspace template restore ID` puts the batch back.

## Sets and how one is chosen

A set is a folder `template/NAME/` holding `project.yml` and `worktree.yml`, in one of three scopes: the project's own library, the global library, or the built-in `default` shipped with workspace. The built-in set is read-only (`template edit` refuses it with `template_builtin_readonly`); `template new NAME --from default` copies it.

Two layered config keys choose the set a new config is rendered from (see [`config`](README.config.md)):

- `tmuxinator.template` names the set for both kinds. The default is `default`.
- `tmuxinator.worktree_template` names a different set for worktree configs. Unset, it follows `tmuxinator.template`.

`template use NAME` sets `tmuxinator.template` after checking that a set of that name exists; `--kind worktree` sets `tmuxinator.worktree_template`, and `--scope project` writes the project's layer. Inside a checkout whose workspace isn't registered, `template use NAME --scope global` writes the global layer. A name no set has is `unknown_template` (`details.kind` is `tmuxinator`). `template list` shows every set and the kinds each one is selected for; `template show` prints a set's files and `template path` where they are.

A project's own sets are searched only for a project that already has a tmuxinator config, so a project's set takes effect from its second config on (its worktrees, and `apply`).

## Checking a set

`template variables` lists the placeholders a set may hold, with a workspace's values under `--name`. `template render` fills a set and prints the result without writing anything: from a workspace's render record and current agent settings (`--name`, or the workspace of the current directory), or from the sample values in the table below (`--sample`). `--file FILE` tries a file you have not saved into a set, and `--diff` shows what the fill would change in the workspace's config. A workspace with no render record cannot be rendered with `--name` (`no_render_record`); `--sample` needs none.

`template validate` checks every file of a set: placeholders it does not know (`unknown_placeholder`), placeholders the kind requires and the file lacks (`missing_placeholder`), `{{PRE_WINDOW}}` sharing its line (`pre_window_not_alone`), an agent pane it cannot find (`no_agent_pane`, an error for a worktree file and a warning for a project file) or that is a literal `claude ...` line (`literal_agent_pane`, a warning), and a dummy render that is not valid YAML. Errors make the exit status 1; warnings alone leave it 0. `template new`, `template edit` and `template import` run the same check, and `config validate` and `doctor` warn when a selected set has errors or does not exist. `template diff NAME --against OTHER` shows how two sets differ (it compares with `default` when `--against` is left out).

Problems with a file go to stderr, and the exit status is 1 when one is an error.

## Placeholders

<!-- BEGIN GENERATED: placeholders -->
| Placeholder | Kinds | Required | Description | Source | Sample |
|-------------|-------|----------|-------------|--------|--------|
| `{{PROJECT_NAME}}` | project, worktree | project | The project's name (a worktree's parent project). | the project | `myapp` |
| `{{WORKSPACE_NAME}}` | project, worktree | project, worktree | The workspace's name, which is its config's name. | the workspace | `myapp.worktree-proj-123` |
| `{{PROJECT_ROOT}}` | project | project | The project's checkout directory. | the project | `/Users/me/src/myapp` |
| `{{DISPLAY_NAME}}` | project, worktree | no | The text of the launcher pane's banner. | the workspace name | `myapp` |
| `{{CONFIG_PATH}}` | project, worktree | no | The path of the config being written. | the config directory | `/Users/me/.config/tmuxinator/myapp.yml` |
| `{{TMUX_SESSION_NAME}}` | worktree | worktree | The tmux session name of the worktree. | the worktree | `myapp-wt-proj-123` |
| `{{WORKTREE_PATH}}` | worktree | worktree | The worktree's directory. | the worktree | `/Users/me/src/myapp/.worktrees/proj-123` |
| `{{WORKTREE_BRANCH}}` | worktree | worktree | The worktree's git branch. | the worktree | `proj-123` |
| `{{AGENT_COMMAND}}` | project, worktree | no | The agent pane's command: for Claude Code the flagged `--continue \|\|` line with the configured program, for another kind the bare configured command. | `agent.kind` and `agent.commands.<kind>` | `claude --dangerously-skip-permissions --continue \|\| claude --dangerously-skip-permissions` |
| `{{PRE_WINDOW}}` | worktree | no | A whole line: `pre_window: export WORKSPACE_TASK=ID` with a task id, dropped without one. | the workspace's task | `t_abc123` |
<!-- END GENERATED: placeholders -->

The banner line uses `{{DISPLAY_NAME}}`, the workspace name with every non-word character replaced by a space, because `ascii-banner` wraps only at whitespace. `{{PRE_WINDOW}}` is a whole line: it stands on a line of its own and the line is dropped when the workspace has no task id.

`workspace template render` refuses a placeholder the text holds when it has no value to put there, except `{{PRE_WINDOW}}`. A placeholder in the "Required" column must appear in a set of that kind; the rest may be left out.

### The agent command

`{{AGENT_COMMAND}}` is the text of the agent pane, worked out from `agent.kind` and `agent.commands.<kind>`:

- For `claude` (Claude Code) it is the flagged line with the configured program put in: `claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions` by default, so the flags stay and only the program changes (with `agent.commands.claude` set to `claude-dev`, both `claude` words become `claude-dev`).
- For any other kind it is the bare configured command, such as `codex`, with no `--continue ||` chain.

A set may also write the Claude Code line out as a literal `claude ...` pane. It is then searched and rewritten as before the placeholder existed, and `start --agent-kind` swaps it in the same way. A set with neither the placeholder nor a Claude Code pane gives `template_outdated` on `start --agent-kind codex`; `template validate` finds that first.

## The render record

Every tmuxinator config workspace writes has a render record beside it, `~/.local/state/workspace/.render/<name>.json` (the sidecar). It holds the set and kind the config came from, the sha256 of the tmuxinator template text, the inputs that filled it (name, paths, branch, task id, agent kind and the agent pane text written) and the sha256 of the file as written. `template status`, `apply`, `adopt` and `doctor` use it to tell what has changed since.

The record follows the config: `rename` moves and rewrites it with the config, `remove`, `kill` (and `finish`) and `prune` delete it with the config, and `doctor --fix`, `set-command` and the agent-pane refresh of `launch` update it with the file they patch. A backup batch keeps its own copy of a record it saved.

Because `rename` rewrites the config's text in place, the next `apply` after a `rename` may report `applied` with a diff: a fresh render of the same set can differ from the renamed text.

## Status

`template status [WS...] [--all | --project [NAME]]` reads only. It re-renders each workspace's selected set with the recorded inputs and the current agent settings and compares that with the file byte for byte. With no names and no flag it reports the workspace of the current directory.

| State | Meaning |
|-------|---------|
| `current` | The file is what the selected set renders today. |
| `stale` | The file is what was last rendered, but a render today would write something else, or the selected set is a different one. `reasons` says why. |
| `modified` | The file is not what was last rendered: it was edited by hand or by another tool. `stale` and `reasons` still say whether a render would change it. |
| `untracked` | There is no render record (or no config), so there is nothing to render it from. `template adopt` can build a record. |

`reasons` holds some of `template_switched` (the record names another set than the selected one, even if the text matches, so `apply` rewrites the record), `template_changed` (the selected set's text is not what was rendered), `agent_changed` (same text, but the agent settings give another pane), `template_unavailable` (the selected set cannot be read) and `render_failed` (it cannot be filled with today's inputs). `approx` is true when the record came from `template adopt` without an exact render, so `modified` may not mean a hand edit.

`doctor` shows the same as `template-current` rows, and `doctor --fix` runs `apply` without `--force` for the stale ones.

## Applying a set to existing configs

`template apply` renders each selected workspace's config again from its render record, with the set that workspace selects now and the current agent settings, and writes it when that changes it. Pick workspaces by name, with `--all` (every workspace that has a tmuxinator config) or `--project [NAME]`; with none of them it applies to the workspace of the current directory.

- `--dry-run` writes nothing, takes no backup and no lock, and says `would apply` for each config it would rewrite. `--diff` adds the unified diff of each change.
- Every config and record it will write is copied first into one backup batch under `~/.local/state/workspace/backups/tmuxinator/`; the `Backup:` line names it.
- A config edited since it was rendered (`modified`) is skipped, `skipped: modified`, unless `--force`. A record that `adopt` made without an exact render is skipped the same way, `skipped: approx`.
- A config with no render record is `skipped: untracked`, with or without `--force`: there is nothing to render it from. Run `template adopt` first.
- A workspace renamed or removed while `apply` waited for its lock is `skipped: gone`, and nothing is written for it.
- When another set renders exactly the same text, only the render record is rewritten (`already up to date; only its render record was updated`).
- `--rollback-all-on-error` stops at the first workspace that fails and puts back everything the batch wrote, deleting a config or record the batch created.
- `--relaunch` then stops each workspace whose session was running and whose config was rewritten, and launches it again, so the session takes the new layout. The workspace you run it from (the one of the current directory, and the one whose tmux session holds `$TMUX_PANE`, or, when that pane can't be placed or is unset, is the session `$TMUX` names) is never relaunched (`relaunch_own_workspace`; the warning names `workspace relaunch NAME` to run from outside it). A session still up after the stop is not launched (`relaunch_stop_failed`). A session that is up but not tracked as active is left alone (`not_active`; stop and launch it by hand). Nothing is relaunched after `--rollback-all-on-error` rolled back. Under `--dry-run` each such row says `would_relaunch` and nothing stops. `template restore --relaunch` does the same for the workspaces whose config bytes it put back (not one where only the render record changed).

Each workspace waits for its startup lock, the one `rename` and `launch` hold, so a workspace is never written while it is being renamed or started. `remove`, `kill` and `prune` take the same lock, so a removed config is not written back. A lock file that cannot be opened is `workspace_locked` for that workspace, and the others go on. A workspace that fails does not stop the others.

Skipping is not a failure: a run that skips every edited or untracked config exits 0. A script that must know reads the `skipped` tally or each row's `reason` under `--json`.

### Exit codes

`template` follows the exit codes every other verb uses ([`--json` documents](README.json.md)): a usage error, an error envelope or a failed action exits 1, and success 0. `apply`, `restore`, `adopt` and `backup` handle several workspaces, so they add one: `partial` (exit 3) when some workspaces failed and others did not, and `failed` (exit 1) when all did or `--rollback-all-on-error` rolled the batch back. Under `--relaunch`, a workspace that was not relaunched also makes the run `partial` (exit 3). `validate` and `edit` exit 1 when a file has an error.

## Configs with no render record

Configs written before render records existed are `untracked`. `template adopt [WS...] [--all | --project [NAME]] [--dry-run]` reads the inputs back out of the file (`name:`, `root:`, the banner, a worktree's `Worktree — BRANCH (PROJECT)` line, its task id and the agent its main pane runs), renders the set a new config would use now and writes only the record, never the config. When that render equals the file byte for byte the match is `exact` and the config reads `current`. Otherwise it is `approx`: the config reads `modified` and `apply` skips it unless `--force`. A config that already has a record is `skipped: tracked`. A config whose inputs cannot be read is `failed` (`adopt_unrecoverable`).

## Backups

`apply`, `restore` and `import` each take a backup batch before they write. `template backup [WS...] [--all | --project [NAME]]` takes one on request (reason `manual`). A batch is a directory under `~/.local/state/workspace/backups/tmuxinator/` named by its id, with a `manifest.json` and a copy of each file: a workspace's config and its render record, or a tmuxinator template set. A config that is a symbolic link is not copied (`backup_symlink`).

```sh
workspace template backups list                         # newest first: id, reason, workspaces, sets
workspace template restore 20261112T101500123456Z-a1b2c3          # the whole batch
workspace template restore 20261112T101500123456Z-a1b2c3 api      # only api
```

`restore` puts back each workspace's config and record as the batch saw them, and deletes a file the batch created. It first takes a batch of its own (reason `restore`) of what it replaces, so a restore can be undone by restoring that. A workspace whose files changed since the batch wrote them is `failed: restore_conflict` unless `--force`; a manual backup is compared with its copy alone. A workspace whose config and record are both gone and whose checkout is gone too is `skipped: gone`; a config deleted by accident while its checkout remains is put back. An unknown ID is `backup_not_found`, and a name the batch does not hold `unknown_workspace`.

Batches are pruned after each one is taken, by two global config keys: `tmuxinator.backups.keep` (default 20) and `tmuxinator.backups.max_age` (a duration, unset by default). A workspace's newest batch is never pruned. `template backups prune` applies the limits now, for after you change one.

## Moving tmuxinator templates between machines

`template export DIR` writes each set of the global library (`--scope project`: the project's) into `DIR/NAME/` with plain files, plus `DIR/templates.json` listing the workspace version and the sha256 of every file. `templates.json` is for people; `import` does not check it. Built-in sets and `legacy` are not exported, dotfiles are left out, and a set's folder already in DIR is `template_exists` unless `--force`. `DIR` cannot be inside a library.

`template import PATH` reads one set (a folder holding `project.yml` and `worktree.yml`, named after the folder) or a folder of them. Every set is validated first and nothing is written if one is invalid; a folder holding a symbolic link is refused (`invalid_template`). A set that already exists with other content is copied into a backup batch (reason `import`) and replaced; the same content is `unchanged`. Replacing a set a `tmuxinator.template` or `tmuxinator.worktree_template` key selects, or adding one called `default` (which would hide the built-in set every unset key renders from), is `template_in_use` unless `--force`. A set that hides one of the same name in a lower scope is warned about (`shadows_template`). `template restore` puts the replaced sets back and removes the ones the import added.

## Copies from an earlier `workspace init`

Earlier versions of `workspace init` copied the two files into `~/.config/tmuxinator/` as `workspace.project-template.yml` and `workspace.project-worktree-template.yml`, and new configs rendered from those copies. `init` no longer copies them and leaves an existing copy alone. A copy counts as unedited when its sha256 is that of any version of the file workspace ever shipped, so most upgrading installs need nothing and render from `default`. A copy that matches none of them is edited and keeps being used, as the set `legacy`, until you act: `init`, `doctor` and `template list` say so.

`template import` with no PATH reads those copies. If either was edited, `project.yml` and `worktree.yml` become the global set `local` (a kind that is missing or stock comes from the built-in set) and `tmuxinator.template` is set to `local`; the old files stay where they are. With no edited copy it changes nothing and says so. After that, `template validate local` and `template edit local` work as for any set.

## JSON output

Every verb accepts `--json` and prints one document on stdout. The read verbs (`list`, `show`, `path`, `variables`, `render`, `validate`, `diff`, `status`, `backups list`) print read documents; `new`, `edit`, `use`, `apply`, `adopt`, `backup`, `backups prune`, `restore`, `export` and `import` print the action document and exit through its `status`. The shapes are in [`docs/README.json.md`](README.json.md#tmuxinator-templates).

## Related

- [`library`](README.library.md): `template` is one of its kinds; `library remove --kind template` refuses a set a config key still selects (`template_in_use`).
- [`config`](README.config.md): `tmuxinator.template`, `tmuxinator.worktree_template`, `tmuxinator.backups.keep`, `tmuxinator.backups.max_age`.
- [`doctor`](README.doctor.md): the `templates` and `template-current` checks.
- [`init`](README.init.md), [`start`](README.start.md), [`rename`](README.rename.md).
