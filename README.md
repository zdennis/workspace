# workspace

A macOS CLI for managing tmuxinator-based development workspaces in iTerm2. Launch, focus, kill, and relaunch projects with automatic window positioning across multiple displays. On a remote machine or in CI, [`launch --headless`](docs/README.launch.md#headless) runs the same workspaces in plain tmux.

## Features

- **Launch** multiple tmuxinator projects with automatic window arrangement
- **Start** worktree-based workflows from JIRA keys, PR URLs, or branch names
- **Focus** a project's window and shake it to draw attention
- **Kill** and **relaunch** workspace projects with session state preservation
- **Add** new projects from any directory
- **Agent** — run a long-lived daemon that registers with [work-coordinator](https://github.com/zdennis/work-coordinator), routes commands to the right pane, and drives multi-step pipelines
- **Workflow** — run ordered steps (the `rpiv` preset: research, plan, implement, verify) in a workspace's agent pane, with gates, checks, locks the run holds, and a reason whenever a run is stuck
- **Pipeline** (deprecated, use Workflow) — sequence panes as a staged pipeline (researcher → implementer → reviewer) with automatic handoff and sentinel-based completion detection
- Reuses existing launcher panes instead of creating new windows
- Tracks iTerm window IDs for reliable window management across tab switches
- Positions windows left-to-right on the active display

## Requirements

A [headless](docs/README.launch.md#headless) launch needs only Ruby, tmux, tmuxinator and git: no macOS, iTerm2 or window-tool.

- **macOS** (uses AppleScript and Accessibility APIs)
- **Ruby** (tested with 3.x)
- **[iTerm2](https://iterm2.com/)** — terminal emulator
- **[tmux](https://github.com/tmux/tmux)** — terminal multiplexer
- **[tmuxinator](https://github.com/tmuxinator/tmuxinator)** — tmux session manager
- **[window-tool](https://github.com/zdennis/window-tool)** — fast window management via Accessibility API (must be on PATH)
- **[gh](https://cli.github.com/)** — GitHub CLI (for `workspace start` with PR URLs and `#n` refs; needs a version with `gh pr checkout --worktree`)
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
| agent | [README](docs/README.agent.md) | Umbrella for driving a workspace agent: `agent run "prompt"`, `agent status request\|post`, `agent executables` (the agent programs on PATH by family) |
| agentd | [README](docs/README.agentd.md) | Run the long-lived workspace agent daemon for a project, or replace it (`agentd restart`) |
| agent-run | [README](docs/README.agent-run.md) | Send a message to a running agent, or type into a pane (command, inject, restart, send, queue) |
| alfred | [README](docs/README.alfred.md) | Manage the Alfred workflow for workspace focus |
| ask | [README](docs/README.ask.md) | Record a question an unattended agent hit, with its default; list/answer/withdraw them |
| binding | [README](docs/README.binding.md) | Bind a pane to a workflow run, PR review or play, so it, and the packs it was sent, survive `/clear` and compaction |
| capabilities | [README](docs/README.capabilities.md) | Print what this CLI supports, as feature revisions (for scripts and the UI) |
| capture | [README](docs/README.capture.md) | Print a tmux pane's scrollback buffer to stdout |
| cleanup | [README](docs/README.cleanup.md) | Detect and remove zombie sessions from state |
| config | [README](docs/README.config.md) | Show, validate, set, get, unset, edit or describe (keys) project or global configuration |
| current | [README](docs/README.current.md) | Print the workspace project name for the current directory |
| daemon | [README](docs/README.daemon.md) | List, show, restart (one or all) or read the log of agent daemons |
| deactivate | [README](docs/README.deactivate.md) | Deactivate Claude in a project's tmux pane (sends Ctrl-C) |
| dev | [README](docs/README.dev.md) | Start, stop, or inspect the repo's single dev environment (devenv lock); `up --queue`, `wait` and `leave` get in line, wait for a turn and give it up without holding a shell open |
| dir | [README](docs/README.dir.md) | Print the root directory of a workspace project |
| doctor | [README](docs/README.doctor.md) | Check that all required dependencies are installed |
| event-log | [README](docs/README.event-log.md) | Show or compact the append-only event log of state changes and agent activity |
| events | [README](docs/README.events.md) | Read or follow the event log and every agent's hook events (tool, sub-agent, session, prompt) as one stream, resumable by cursor |
| finish | [README](docs/README.finish.md) | Verify a worktree is clean and pushed, then remove it (optionally opens a PR) |
| focus | [README](docs/README.focus.md) | Bring a project's iTerm window to the front |
| handoff | [README](docs/README.handoff.md) | Check context usage and hand off to a fresh conversation |
| init | [README](docs/README.init.md) | Install tmuxinator templates and create workspace config directory |
| inbox | [README](docs/README.inbox.md) | A durable list of things that need a person, per workspace, project or globally: `add` (also `--from-json`, `--dedupe-key`), `list`, `show`, `edit`, `done`, `dismiss`, `reopen`, `snooze`, `ack` (derived rows), `list --include-derived` |
| instructions | [README](docs/README.instructions.md) | Print the instructions built from library packs (`binding`, `orchestrator`, `commits`, `review`, `notes`, `handoff`, `dev`, `implementation-plan`, `research`, `spine`) |
| kill | [README](docs/README.kill.md) | Kill a worktree project and remove its worktree |
| launch | [README](docs/README.launch.md) | Launch tmuxinator projects in iTerm2 windows, or headless in plain tmux |
| layout | [README](docs/README.layout.md) | Save/restore tmux pane layouts (auto-saved before resize) |
| library | [README](docs/README.library.md) | Store named plays, prompts, agents, skills and spine templates, globally or per project, beside the built-in packs (alias: `lib`) |
| list | [README](docs/README.list.md) | List active projects (`--all` for all available) |
| list-projects | [README](docs/README.list-projects.md) | Alias for `list --all` |
| lock | [README](docs/README.lock.md) | Acquire, release, inspect, or clear a shared repo-wide lock; print agent instructions |
| lookup | [README](docs/README.lookup.md) | Find a workspace project by worktree path, branch, or project name |
| notes | [README](docs/README.notes.md) | Print where a workspace's notes are kept (`dir`; `--create` makes the directory and keeps it out of git) |
| parent | [README](docs/README.parent.md) | Print the parent workspace of the current (or given) workspace |
| pipeline | [README](docs/README.pipeline.md) | Deprecated (use `workflow`): inspect and drive a project's agent pipeline |
| plan | [README](docs/README.plan.md) | Read a workspace's plan (`IMPLEMENTATION_PLAN.md` in its notes directory): `status` counts it and works out its state (`status --group` merges a group of repositories), `path`, `show`, `init` to write one, `start`, `pause` and `delete` to run it, and `start --task` to send one task to one pane |
| pr | [README](docs/README.pr.md) | Open a pull request for a workspace's branch without finishing it (`create`): pushes the branch if needed, returns an existing pull request |
| promote | [README](docs/README.promote.md) | Move a main checkout's work (changes and branch commits) into a new worktree workspace, carry its plan, spine and chosen notes, and leave the checkout clean; `--dry-run` previews, a failed move is undone or kept under a recovery ref |
| projects | [README](docs/README.projects.md) | Group workspaces by repository: main checkout plus worktrees (`list` for running counts, `list --git` for unsaved work, `show` for one project's agents, git state, asks, pipeline, locks and dev env, `members` for a script-friendly list of its workspaces, `stop` to stop them all, `kill` to remove all its worktrees, `group create/add/list/show` to name several repositories as a group) |
| prune | [README](docs/README.prune.md) | Remove worktree projects whose PR is closed or merged |
| push | [README](docs/README.rebase.md) | Push a workspace's branch to origin; forces with a lease only when a rebase replaced commits the upstream has |
| reactivate | [README](docs/README.reactivate.md) | Reactivate Claude in a project's tmux pane |
| rebase | [README](docs/README.rebase.md) | Rebase a workspace's branch onto the default branch (`--onto local\|update\|remote\|upstream`); a conflict is aborted and reported |
| relaunch | [README](docs/README.relaunch.md) | Stop and relaunch all active workspace projects |
| remove | [README](docs/README.remove.md) | Delete a stopped project's tmuxinator config, project settings and state entry (never its directory or notes) |
| restore | [README](docs/README.restore.md) | Bring back agent panes after a reboot: launch the workspace you are in (`--all`: every active one), recreate recorded agent panes (hand-split ones too) and resume their sessions with `claude --resume`; `--dry-run` shows the plan and what can't be matched |
| report-run-status | [README](docs/README.report-run-status.md) | Internal: write run result for --wait (called by shell wrapper) |
| run | [README](docs/README.run.md) | Send a shell command to a pane in a project's tmux session |
| run-and-report | [README](docs/README.run-and-report.md) | Run a command as a subprocess and capture stdout/stderr/exit status |
| set-command | [README](docs/README.set-command.md) | Set the shell command for a pane in a project config |
| repair | [README](docs/README.repair.md) | Rebuild state from live iTerm windows |
| resize | [README](docs/README.resize.md) | Resize tmux panes for a running project |
| hooks | [README](docs/README.hooks.md) | Remove workspace's hooks from a coding agent's settings (`hooks uninstall --agent codex`) |
| session-event | [README](docs/README.session-event.md) | Forward one coding-agent hook event to a workspace's agent daemon |
| review | [README](docs/README.review.md) | Show a workspace's finished work for review, or list the workspaces that are ready |
| snapshot | [README](docs/README.snapshot.md) | Print everything a UI polls (projects, panes, git, questions, locks, dev) as one JSON document |
| sessions | [README](docs/README.sessions.md) | Show coding-agent sessions and sub-agents running in a project's panes |
| spine | [README](docs/README.spine.md) | Read a workspace's stages (the stage files in `spine/` of its notes directory): `show` lists the stages with canonical statuses, a revision per file, roll-ups and warnings; `init` creates the folder from a template; `set` changes one stage's status (and optionally its sub-stages') in the stage file's frontmatter; `verify` records a separate check of a completed stage that opted in with `check:` (`--pass` or `--fail`, and a note); `start` sets a stage in progress, sends an agent its brief and binds the pane |
| start | [README](docs/README.start.md) | Create a git worktree and launch it (from JIRA key, PR/issue URL, or branch) |
| status | [README](docs/README.status.md) | Show detailed state of tracked launcher sessions |
| statusline | [README](docs/README.statusline.md) | Render Claude Code's status line (install as its statusLine command) |
| step | [README](docs/README.workflow.md) | For the agent on a workflow step: report on it (`done`) or see what it is (`status`) |
| stop | [README](docs/README.stop.md) | Stop a workspace and its tmux session (default: the one you are in; `--all` for every active one) |
| tile | [README](docs/README.tile.md) | Tile windows across the screen (`--all` for all projects) |
| ticket | [README](docs/README.ticket.md) | Look up a ticket the way `start` reads it (`show`): a JIRA key, pull request, issue or branch, with its title and body from `gh` or `jira` and whether a workspace for it already exists; or list the tickets assigned to you or changed lately (`list`) |
| tmux | [README](docs/README.tmux.md) | Show a workspace's tmuxinator file as windows and panes |
| ui | [README](docs/README.ui.md) | Open a `workspace-ui://` link: a task, a review, notes or the inbox |
| version | [README](docs/README.version.md) | Print the workspace version |
| wait-until-content | [README](docs/README.wait-until-content.md) | Block until a pane shows content, then exec a command |
| whereis | [README](docs/README.whereis.md) | Print the workspace installation directory |
| workflow | [README](docs/README.workflow.md) | Run a workflow (ordered steps, e.g. `rpiv`) in a workspace's agent pane: `show`, `run`, `status`, `resume`, `cancel`, `approve`, `reject` |

Run `workspace <subcommand> --help` for subcommand-specific help. Scripts and agents: every `--json` result is one object with `schema_version` and `ok`, and failures carry a stable `code`; see [`--json` output](docs/README.json.md).

New to locks and the dev environment? Start with the [walkthrough](docs/GUIDE.locks-and-dev.md). For autonomous workflows, see [autonomous development](docs/autonomous-development.md) (how to run autonomous feature development with workspace, and its current gaps).

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

## Text encoding

Workspace reads its files (state, config, templates, library entries) and the output of the commands it runs as UTF-8, whatever the locale of the process. A caller with no UTF-8 locale (cron, an app started by launchd, `env -i`) gets the same results as a terminal. Two things this does not cover: command-line arguments and environment values keep the locale's encoding (`workflow` and `step` read their own arguments as UTF-8; other commands given non-ASCII text with no UTF-8 locale may still fail), and a file whose bytes are not UTF-8 still fails where it is parsed.

## State

Workspace tracks launcher pane UUIDs and iTerm window IDs in `~/.workspace-state.json`. This file is managed automatically.

## Tmuxinator Templates

The repo includes two templates in `lib/templates/` that are installed to `~/.config/tmuxinator/` by `workspace init`:

- **`workspace.project-template.yml`** — standard project layout with 3 panes (banner, claude, shell)
- **`workspace.project-worktree-template.yml`** — worktree variant, roots into the worktree directory

Templates use placeholders like `{{PROJECT_NAME}}` and `{{PROJECT_ROOT}}` that are filled in automatically by `workspace add` and `workspace start`.

## License

MIT
