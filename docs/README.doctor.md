# workspace doctor

Check that all required dependencies are installed and configured.

## Usage

```sh
workspace doctor [--headless | --no-headless] [--fix]
```

## Options

| Option | Description |
|--------|-------------|
| `--headless` / `--no-headless` | Check for a headless setup, which skips the iTerm2 and window-tool checks, or for an iTerm2 one. The default follows the same rule as [`launch`](README.launch.md#headless) |
| `--fix` | Route Claude's `statusLine` through `workspace statusline`, backing up `settings.json` first. The only fix `doctor` performs today; everything else it reports has to be fixed by hand. Restart any running Claude Code sessions afterward — Claude Code doesn't reload `statusLine` mid-session. Reports and fails (non-zero exit) when run outside a workspace project, when no hook-capable agent is on `PATH`, or when none of the detected agents support `statusLine` (only Claude Code does) |

## Details

Checks for all required tools (ruby, tmux, tmuxinator, iTerm2, window-tool, git) and optional tools (gh, ascii-banner). Reports version information and provides install instructions for anything missing.

The first line says which mode it checked for and why, e.g. `mode: headless (not macOS)`. A [headless](README.launch.md#headless) setup doesn't need iTerm2 or window-tool, so those two checks are skipped and shown as `⊘  iTerm2 (not needed headless, skipped)`.

Also verifies that tmuxinator templates are installed and checks the state file for health issues such as duplicate window IDs (which can cause commands like `focus` to target the wrong project).

**Session monitoring** — when run from inside a workspace project, also checks that project's session monitoring: whether a hook-capable coding agent (e.g. Claude Code) has its hooks installed for the project, and whether the [`sessions`](README.sessions.md) agent daemon is currently running for it. Skipped when not run from inside a workspace project, or when no hook-capable agent is detected on `PATH`.

**statusLine** — also warns (`⚠`, doesn't fail the check) when Claude Code's `statusLine` isn't routed through `workspace statusline`, since [context usage](README.statusline.md) then can't be read for `handoff check`/`sessions --json`. `workspace doctor --fix` installs it. Whether a pane has rendered a reading yet isn't checked here — that's read per-pane from [`sessions --json`](README.sessions.md)'s `context_error`, not from `doctor`. Only Claude Code is checked; other hook-capable agents have no `statusLine` concept.

`.claude/settings.local.json`, when present, wins over `settings.json` at runtime (Claude Code deep-merges the two, local keys last). `doctor` reads it read-only: if it has its own `statusLine` command, `doctor` reports the shadow instead of a false `✓` — e.g. `statusLine shadowed by .claude/settings.local.json (routes through "..." there)` — and the fix is to remove that entry from `settings.local.json` by hand, since workspace never edits that file. `--fix` still installs into `settings.json` underneath, preserving whatever command it displaces (local settings' command taking precedence over a user-level one) into the global `statusline.command` config, and prints the same shadow warning afterward as a reminder.

**Pipeline config** — also validates the current project's [pipeline config](README.pipeline.md), if it has one, reporting an invalid `timeout:` the same way `launch` does. It also warns, without failing the check, on a `pipeline:` block with no panes (it won't start a pipeline) and on a stage whose own text names the bare completion sentinel (workspace appends that itself with a per-dispatch token, so a stage repeating it verbatim can be confusing, though the tokened instruction still wins).

Exits with a non-zero status if any issues are found, so it can be used in scripts.

## Example

```sh
$ workspace doctor
workspace doctor

  mode: iTerm2 (iTerm2)
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
  ✓  statusLine routed through workspace

Everything looks good!
```
