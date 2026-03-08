# Workspace CLI

A macOS CLI (Ruby) for managing tmuxinator-based development workspaces in iTerm2.

## Project Structure

- `bin/workspace` — Entry point (4 lines), calls `Workspace.build_cli.run(ARGV)`
- `lib/workspace.rb` — Module root, `build_cli` factory, error classes
- `lib/workspace/cli.rb` — CLI dispatch, OptionParser definitions, simple command methods
- `lib/workspace/config.rb` — Path constants and configuration
- `lib/workspace/state.rb` — JSON-persisted session state
- `lib/workspace/git.rb` — Git and worktree operations
- `lib/workspace/doctor.rb` — Dependency checking
- `lib/workspace/tmux.rb` — Tmux session management
- `lib/workspace/project_config.rb` — Tmuxinator config generation
- `lib/workspace/iterm.rb` — iTerm2 session/pane lifecycle (AppleScript)
- `lib/workspace/window_manager.rb` — iTerm2 window operations: find, focus, position, close
- `lib/workspace/window_layout.rb` — Window positioning math
- `lib/workspace/commands/` — Complex command objects (launch, kill, focus, start)
- `lib/templates/workspace.project-template.yml` — Tmuxinator template for standard projects
- `lib/templates/workspace.project-worktree-template.yml` — Tmuxinator template for git worktree projects
- State tracked in `~/.workspace-state.json`
- Configs installed to `~/.config/tmuxinator/`

## Key Details

- No runtime gems/dependencies beyond Ruby stdlib (`optparse`, `open3`, `json`, `fileutils`)
- Constructor injection throughout: `Workspace.build_cli` assembles the dependency graph
- Uses AppleScript for iTerm2 automation
- Uses `window-tool` binary for window positioning
- Templates use `{{PLACEHOLDER}}` syntax for variable substitution

## Subcommands

init, doctor, launch, start, add, kill, relaunch, focus, list, status, whereis

## Adding a Subcommand

1. Create `lib/workspace/commands/foo.rb` with a `call` method (or keep it inline in CLI for simple commands)
2. Add `cmd_foo` method in CLI that parses options with OptionParser and delegates
3. Add case branch in `CLI#run`
4. Wire dependencies in `Workspace.build_cli` if using a command object
5. Add `require_relative` in `workspace.rb`
6. Add help text to `main_help` in CLI

## State File (~/.workspace-state.json)

```json
{
  "project-name": {
    "unique_id": "iTerm session UUID (written by Launch after pane creation)",
    "iterm_window_id": 123
  }
}
```

- Written by: Launch (after pane creation and window discovery)
- Consumed by: Launch (reattach), Kill, Focus, List, Status
- Loaded explicitly via `@state.load`; saved via `@state.save`
- Silently resets to `{}` on corrupt JSON

## External Dependencies

- **tmux / tmuxinator**: Session management (required)
- **window-tool**: Screen geometry and window positioning (required) — https://github.com/zdennis/window-tool
- **gh**: GitHub CLI for PR branch resolution in `start` (optional)
- **ascii-banner**: Cosmetic banner in launcher pane (optional)
- **git**: Version control operations (required)
- **iTerm2**: Terminal emulator, controlled via AppleScript (required)

## Conventions

- Follow existing code style (methods, snake_case, minimal abstraction)
- Composition over inheritance, no modules for private method grouping
- Command objects receive parsed values, never ARGV
- Only `CLI#run` calls `exit`; everything else raises `Workspace::Error` or `Workspace::UsageError`
- IO injection: classes accept `output:`, `error_output:`, `input:` for testability
- YARD docs on all public classes and methods
- Tests use RSpec, run with `bundle exec rspec`
- Lint with `bundle exec standardrb lib/ spec/`

## Pre-commit Requirements

Before every commit, run all 5 review agents in parallel using the Agent tool. Each agent should only review files changed in the current commit (or on the topic branch vs main). Pass this context when launching each agent.

1. `.claude/agents/staff-engineer.md` — Architecture and complexity review
2. `.claude/agents/new-user.md` — UX and discoverability review
3. `.claude/agents/ai-agent-operator.md` — Automation and scriptability review
4. `.claude/agents/testing-craftsperson.md` — Test coverage, `bundle exec rspec`, and `bundle exec standardrb lib/ spec/`
5. `.claude/agents/power-user.md` — Edge cases and extensibility review

All 5 must pass before committing. Address any concerns raised before proceeding.
