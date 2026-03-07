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
| init | [README](docs/README.init.md) | Install tmuxinator templates and create config directory |
| doctor | [README](docs/README.doctor.md) | Check that all required dependencies are installed |
| launch | [README](docs/README.launch.md) | Launch tmuxinator projects in iTerm2 windows |
| start | [README](docs/README.start.md) | Create a git worktree and launch it (from JIRA key, PR/issue URL, or branch) |
| add | [README](docs/README.add.md) | Add a tmuxinator config for a project directory |
| kill | [README](docs/README.kill.md) | Kill active workspace projects and their tmux sessions |
| relaunch | [README](docs/README.relaunch.md) | Kill and relaunch all active workspace projects |
| focus | [README](docs/README.focus.md) | Bring a project's tmux window to the front and shake it |
| list-projects | [README](docs/README.list-projects.md) | List all available tmuxinator projects |
| list | [README](docs/README.list.md) | List currently active (launched) projects |
| status | [README](docs/README.status.md) | Show detailed state of tracked launcher sessions |
| whereis | [README](docs/README.whereis.md) | Print the workspace installation directory |
| version | [README](docs/README.version.md) | Print the workspace version |

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
  commands/
    launch.rb                     # Launch orchestration
    kill.rb                       # Session teardown
    focus.rb                      # Window focusing
    start.rb                      # Worktree creation flow
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
