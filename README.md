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
- **[ascii-banner](https://github.com/zdennis/homebrew-bin/blob/main/docs/README.ascii-banner.md)** — terminal banner display (optional, used in tmuxinator templates)

## Installation

1. Clone the repo and add `bin/` to your PATH:

```sh
git clone git@github.com:zdennis/workspace.git ~/source/opensource/workspace
export PATH="$HOME/source/opensource/workspace/bin:$PATH"
```

2. Run the init command to install tmuxinator templates:

```sh
workspace init
```

This creates `~/.config/tmuxinator/` (if needed) and copies the project templates into it. Use `--dry-run` to preview what would happen:

```sh
workspace init --dry-run
```

3. Run the doctor command to verify all dependencies are installed:

```sh
workspace doctor
```

This checks for all required tools and provides install instructions for anything missing.

## Usage

```
workspace <subcommand> [options]
```

### Subcommands

| Subcommand | Docs | Description |
|------------|------|-------------|
| add | [README](docs/README.add.md) | Add a tmuxinator config for a project directory |
| alfred | [README](docs/README.alfred.md) | Manage the Alfred workflow for workspace focus |
| cleanup | [README](docs/README.cleanup.md) | Detect and remove zombie sessions from state |
| config | [README](docs/README.config.md) | Show project or global configuration |
| current | [README](docs/README.current.md) | Print the workspace project name for the current directory |
| deactivate | [README](docs/README.deactivate.md) | Deactivate Claude in a project's tmux pane (sends Ctrl-C) |
| dir | [README](docs/README.dir.md) | Print the root directory of a workspace project |
| doctor | [README](docs/README.doctor.md) | Check that all required dependencies are installed |
| event-log | [README](docs/README.event-log.md) | Manage the append-only event log (compact) |
| focus | [README](docs/README.focus.md) | Bring a project's iTerm window to the front |
| init | [README](docs/README.init.md) | Install tmuxinator templates and create workspace config directory |
| kill | [README](docs/README.kill.md) | Kill a worktree project and remove its worktree |
| launch | [README](docs/README.launch.md) | Launch tmuxinator projects in iTerm2 windows |
| layout | [README](docs/README.layout.md) | Save/restore tmux pane layouts (auto-saved before resize) |
| list | [README](docs/README.list.md) | List active projects (`--all` for all available) |
| lookup | [README](docs/README.lookup.md) | Find a workspace project by worktree path, branch, or project name |
| reactivate | [README](docs/README.reactivate.md) | Reactivate Claude in a project's tmux pane |
| relaunch | [README](docs/README.relaunch.md) | Stop and relaunch all active workspace projects |
| repair | [README](docs/README.repair.md) | Rebuild state from live iTerm windows |
| resize | [README](docs/README.resize.md) | Resize tmux panes for a running project |
| start | [README](docs/README.start.md) | Create a git worktree and launch it (from JIRA key, PR/issue URL, or branch) |
| status | [README](docs/README.status.md) | Show detailed state of tracked launcher sessions |
| stop | [README](docs/README.stop.md) | Stop active workspace projects and their tmux sessions |
| tile | [README](docs/README.tile.md) | Tile windows across the screen (`--all` for all projects) |
| version | [README](docs/README.version.md) | Print the workspace version |
| whereis | [README](docs/README.whereis.md) | Print the workspace installation directory |

Run `workspace <subcommand> --help` for subcommand-specific help.

## Project Structure

```
lib/workspace.rb                  # Module root, build_cli factory, error classes
lib/workspace/
  cli.rb                          # CLI dispatch and OptionParser definitions
  config.rb                       # Path constants and configuration
  state.rb                        # JSON-persisted session state
  git.rb                          # Git and worktree operations
  doctor.rb                       # Dependency checking
  tmux.rb                        # Tmux session management
  project_config.rb               # Tmuxinator config generation
  iterm.rb                        # iTerm2 AppleScript automation
  window_layout.rb                # Window positioning math and arrangement
  window_manager.rb               # iTerm2 window operations
  commands/
    cleanup.rb                    # Zombie session detection and removal
    focus.rb                      # Window focusing
    init.rb                       # Template installation
    kill.rb                       # Session teardown
    launch.rb                     # Launch orchestration
    layout.rb                     # Pane layout save/restore
    resize.rb                     # Pane resizing
    start.rb                      # Worktree creation flow
    stop.rb                       # Worktree teardown
    tile.rb                       # Window tiling
```

No runtime dependencies beyond Ruby stdlib. The CLI receives all collaborators via constructor injection.

## Development

```sh
git clone git@github.com:zdennis/workspace.git
cd workspace
bundle install
bundle exec rake          # runs StandardRB + RSpec
```

Generate YARD docs:

```sh
bundle exec yard
open doc/index.html
```

## State

Workspace tracks launcher pane UUIDs and iTerm window IDs in `~/.workspace-state.json`. This file is managed automatically.

## Tmuxinator Templates

The repo includes two templates in `lib/templates/` that are installed to `~/.config/tmuxinator/` by `workspace init`:

- **`workspace.project-template.yml`** — standard project layout with 3 panes (banner, claude, shell)
- **`workspace.project-worktree-template.yml`** — worktree variant, roots into the worktree directory

Templates use placeholders like `{{PROJECT_NAME}}` and `{{PROJECT_ROOT}}` that are filled in automatically by `workspace add` and `workspace start`.

## License

MIT
