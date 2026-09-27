# workspace doctor

Check that all required dependencies are installed and configured.

## Usage

```sh
workspace doctor
```

## Details

Checks for all required tools (ruby, tmux, tmuxinator, iTerm2, window-tool, git) and optional tools (gh, ascii-banner). Reports version information and provides install instructions for anything missing.

Also verifies that tmuxinator templates are installed and checks the state file for health issues such as duplicate window IDs (which can cause commands like `focus` to target the wrong project).

**Session monitoring** — when run from inside a workspace project, also checks that project's session monitoring: whether a hook-capable coding agent (e.g. Claude Code) has its hooks installed for the project, and whether the [`sessions`](README.sessions.md) agent daemon is currently running for it. Skipped when not run from inside a workspace project, or when no hook-capable agent is detected on `PATH`.

**Pipeline config** — also validates the current project's [pipeline config](README.pipeline.md), if it has one, reporting an invalid `timeout:` the same way `launch` does, or a stage whose own text names the bare completion sentinel (workspace appends that itself with a per-dispatch token, so a stage repeating it verbatim can never match). Also warns when a `pipeline:` block has no panes, since it won't start a pipeline.

Exits with a non-zero status if any issues are found, so it can be used in scripts.

## Example

```sh
$ workspace doctor
workspace doctor

  ✓  ruby (3+)
  ✓  tmux (3+)
  ✓  tmuxinator (3+)
  ✓  iTerm2
  ✓  window-tool
  ✓  git (2+)
  ✓  gh (2+)
  ✓  ascii-banner
  ✓  templates installed
  ✓  state: no duplicate window IDs
  ✓  session monitoring hooks installed for myapp
  ✓  session monitor agent running for myapp

Everything looks good!
```
