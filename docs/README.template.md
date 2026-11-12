# workspace template

Tmuxinator templates and the placeholders they may hold. The full guide comes later; the table below is generated.

`workspace template variables [--kind K] [--name WS]` prints it (with each placeholder's value in a workspace's config under `--name`). `workspace template render [NAME | --file F] [--kind K] [--name WS | --sample] [--diff]` fills a tmuxinator template without writing anything: from a workspace's render record and current agent settings, or from the sample values below; `--file` tries one you have not saved, `--diff` shows what would change in the workspace's config. Problems with the file go to stderr, and the exit status is 1 when one is an error.

`workspace template apply [WS...] [--all | --project [NAME]] [--dry-run] [--diff] [--force] [--rollback-all-on-error]` renders existing configs again from their render records with the tmuxinator template each selects today and the current agent settings. Every config it writes is copied first into one backup batch under `~/.local/state/workspace/backups/tmuxinator/` (the `Backup:` line names it). `--dry-run` writes nothing and says `would apply` for each config it would rewrite. A config edited since it was rendered is skipped unless `--force`; one with no render record is always skipped. Skipping is not a failure: the exit status stays 0. When another tmuxinator template renders exactly the same text, only the render record is rewritten (`render record only`). Each workspace waits for its startup lock, and one renamed or removed meanwhile is skipped. `--rollback-all-on-error` puts back everything the batch wrote at the first workspace that fails. A running session keeps its old layout until you relaunch it. Exit 3 when some workspaces failed, 1 when all did.

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
