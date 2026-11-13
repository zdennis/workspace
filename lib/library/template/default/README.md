---
description: The tmuxinator templates workspace ships: a three-pane project layout and its worktree variant
---
# default

The built-in tmuxinator template set. Select it with `tmuxinator.template` (and `tmuxinator.worktree_template`), or copy it with `workspace template new NAME` and edit the copy.

- `project.yml` is the layout of a standard project, rooted in the checkout.
- `worktree.yml` is the layout of a git worktree, rooted in the worktree directory.

Both open one window of three panes, top to bottom:

0. A banner of the workspace's display name (`ascii-banner "NAME"` when it is installed, else `|| echo "NAME"`). Its command also tags the tmux session with `@workspace` and sizes the panes to 15% and 35%.
1. The coding agent (`{{AGENT_COMMAND}}`, from `agent.kind` and `agent.commands.<kind>`).
2. A shell, which has focus (`startup_pane: 2`). It starts with `Ready to work on NAME` for a project or `Worktree — BRANCH (PROJECT)` for a worktree. `workspace rename` rewrites the banner text and these lines, and `workspace template adopt` reads the banner and the `Worktree — ...` line, so keep their forms in a copy.

`tmux_options: -CC` opens the session in iTerm2's tmux integration. `workspace launch` attaches it and starts the workspace's agent daemon (`agentd`). Running `tmuxinator start` yourself skips the daemon.

`workspace template variables` lists the placeholders each kind takes; so does [docs/README.template.md](../../../../docs/README.template.md), from `lib/workspace/core/template_variables.rb`.
