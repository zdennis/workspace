# workspace template

Tmuxinator templates and the placeholders they may hold. The full guide comes later; the table below is generated.

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
