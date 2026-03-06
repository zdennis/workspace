# workspace

A macOS CLI for managing tmuxinator-based development workspaces in iTerm2. Launch, focus, kill, and relaunch projects with automatic window positioning across multiple displays.

## Features

- **Launch** multiple tmuxinator projects with automatic window arrangement
- **Start** worktree-based workflows from JIRA keys, PR URLs, or branch names
- **Focus** a project's window and shake it to draw attention
- **Kill** and **relaunch** workspace projects with session state preservation
- **Add** new projects from any directory
- Reuses existing launcher panes instead of creating new windows
- Tracks iTerm window IDs for reliable window management across tab switches
- Positions windows left-to-right on the active display

## Requirements

- **macOS** (uses AppleScript and Accessibility APIs)
- **Ruby** (tested with 3.x)
- **[iTerm2](https://iterm2.com/)** — terminal emulator
- **[tmux](https://github.com/tmux/tmux)** — terminal multiplexer
- **[tmuxinator](https://github.com/tmuxinator/tmuxinator)** — tmux session manager
- **[window-tool](https://github.com/zdennis/window-tool)** — fast window management via Accessibility API (must be on PATH)
- **[gh](https://cli.github.com/)** — GitHub CLI (for `workspace start` with PR URLs)
- **git** — version control
- **[ascii-banner](https://github.com/zdennis/ascii-banner)** — terminal banner display (optional, used in tmuxinator templates)

## Installation

1. Clone the repo and add `bin/` to your PATH:

```sh
git clone git@github.com:zdennis/workspace.git ~/source/opensource/workspace
export PATH="$HOME/source/opensource/workspace/bin:$PATH"
```

2. Copy the tmuxinator templates to your config directory:

```sh
cp project-template.yml project-worktree-template.yml ~/.config/tmuxinator/
```

3. Ensure `window-tool` is on your PATH (see [window-tool](https://github.com/zdennis/window-tool)).

## Usage

```
workspace <subcommand> [options]
```

### Subcommands

#### launch

Launch tmuxinator projects in iTerm windows, arranged left-to-right on the active display.

```sh
workspace launch my-notes work-notes billing
```

Reuses existing launcher panes when available. Use `--reattach` to preserve tmux session state when reconnecting.

#### start

Create a git worktree and launch it as a workspace project. Run from within a git repository.

```sh
workspace start PROJ-123                                  # JIRA issue key
workspace start https://mycompany.atlassian.net/.../123   # JIRA URL
workspace start https://github.com/owner/repo/pull/471    # GitHub PR URL
workspace start user/PROJ-123                             # Branch name
```

Creates the worktree in `.worktrees/` under the project root, generates a tmuxinator config, and launches it.

#### kill

Kill workspace projects and their tmux sessions.

```sh
workspace kill                  # kill all active projects
workspace kill my-notes         # kill specific project
```

#### relaunch

Kill all active projects and relaunch them.

```sh
workspace relaunch
```

#### focus

Bring a project's iTerm window to the front and shake it.

```sh
workspace focus my-notes
```

#### add

Add a tmuxinator config for a project directory.

```sh
workspace add ~/Code/my-project
workspace add .                   # current directory
```

#### list-projects

List all available tmuxinator projects.

```sh
workspace list-projects
```

#### list

List currently active (launched) projects.

```sh
workspace list
```

#### status

Show detailed state of tracked launcher sessions.

```sh
workspace status
```

## State

Workspace tracks launcher pane UUIDs and iTerm window IDs in `~/.workspace-state.json`. This file is managed automatically.

## Tmuxinator Templates

The repo includes two templates that should be placed in `~/.config/tmuxinator/`:

- **`project-template.yml`** — standard project layout with 3 panes (banner, claude, shell)
- **`project-worktree-template.yml`** — worktree variant, roots into the worktree directory

Templates use placeholders like `{{PROJECT_NAME}}` and `{{PROJECT_ROOT}}` that are filled in automatically by `workspace add` and `workspace start`.

## License

MIT
