# workspace doctor

Check that all required dependencies are installed and configured.

## Usage

```sh
workspace doctor [--headless | --no-headless] [--fix] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--headless` / `--no-headless` | Check for a headless setup, which skips the iTerm2 and window-tool checks, or for an iTerm2 one. The default follows the same rule as [`launch`](README.launch.md#headless) |
| `--fix` | Route Claude's `statusLine` through `workspace statusline`, backing up `settings.json` first, and install Codex's user-level hooks when Codex is on `PATH` (backing up `hooks.json` first; see [`init`](README.init.md#agent-session-hooks)). The only fixes `doctor` performs today; everything else it reports has to be fixed by hand. Restart any running Claude Code sessions afterward — Claude Code doesn't reload `statusLine` mid-session. Reports and fails (non-zero exit) when run outside a workspace project, or when no agent on `PATH` supports `statusLine` (only Claude Code does). A machine with only Codex on `PATH` reports nothing to fix instead of failing, since Codex's context usage is read by scraping its own pane — no `statusLine` to route |
| `--json` | Print one JSON document with a row per check ([below](#json-output)) instead of the text report. The exit code is the same: 1 when a check failed |

## Details

Checks for all required tools (ruby, tmux, tmuxinator, iTerm2, window-tool, git) and optional tools (gh, ascii-banner). Reports version information and provides install instructions for anything missing.

The first line says which mode it checked for and why, e.g. `mode: headless (not macOS)`. A [headless](README.launch.md#headless) setup doesn't need iTerm2 or window-tool, so those two checks are skipped and shown as `⊘  iTerm2 (not needed headless, skipped)`.

Also verifies that tmuxinator templates are installed and checks the state file for health issues such as duplicate window IDs (which can cause commands like `focus` to target the wrong project).

**Session monitoring** — when run from inside a workspace project, also checks that project's session monitoring: whether a hook-capable coding agent (e.g. Claude Code) has its hooks installed for the project, and whether the [`sessions`](README.sessions.md) agent daemon is currently running for it. Skipped when not run from inside a workspace project, or when no hook-capable agent is detected on `PATH`.

**Codex hooks** — Codex's hooks are user-level (`$CODEX_HOME/hooks.json`, default `~/.codex/hooks.json`), so they get their own row, `hooks-codex`, rather than counting toward the project's `hooks` row. Installed, it is `✓  Codex hooks installed in ~/.codex/hooks.json`, with a hint that Codex runs them only once they are trusted with `/hooks` in Codex (workspace can't read that from outside). Missing, it warns (`⚠`, doesn't fail the check), since a Codex pane then falls back to pane activity; `workspace doctor --fix` installs them. A `hooks.json` that can't be parsed is a warning too, and leaves the file alone. With `codex.hooks.install` set to `false` the row is `✓  Codex hooks turned off by config (codex.hooks.install is false; ...)` with no fix: it is a choice, not a failure. If hooks from an earlier install are still in the file it says so and hints `workspace hooks uninstall --agent codex`. The key is global only; it cannot be set for one project.

**statusLine** — also warns (`⚠`, doesn't fail the check) when Claude Code's `statusLine` isn't routed through `workspace statusline`, since [context usage](README.statusline.md) then can't be read for `handoff check`/`sessions --json`. `workspace doctor --fix` installs it. Whether a pane has rendered a reading yet isn't checked here — that's read per-pane from [`sessions --json`](README.sessions.md)'s `context_error`, not from `doctor`. Only Claude Code is checked; other hook-capable agents have no `statusLine` concept. When no `statusLine`-capable agent is on `PATH` but an agent whose context is scraped from its own pane is (Codex), `doctor` reports that reading instead of the routing warning, e.g. `✓  Codex context usage read from its own pane (no statusLine to route)`.

**Scraped panes** — when the session monitor agent is running for the project, `doctor` also asks it for its panes and reports, per pane whose agent workspace reads by scraping the pane itself (Codex), whether that pane's context usage was readable — e.g. `✓  Codex context usage read from pane 2 (37% used)`, or `⚠  Codex context usage unreadable on pane 2 (pattern didn't match (scrape mode))` with the fix that takes effect for Codex (the `context.patterns` mapping in `~/.config/workspace/config.yml`, not `statusLine` routing). A daemon that can't be asked is already reported by the session monitoring check above.

`.claude/settings.local.json`, when present, wins over `settings.json` at runtime (Claude Code deep-merges the two, local keys last). `doctor` reads it read-only: if it has its own `statusLine` command, `doctor` reports the shadow instead of a false `✓` — e.g. `statusLine shadowed by .claude/settings.local.json (routes through "..." there)` — and the fix is to remove that entry from `settings.local.json` by hand, since workspace never edits that file. `--fix` still installs into `settings.json` underneath, preserving whatever command it displaces (local settings' command taking precedence over a user-level one) into the global `statusline.command` config, and prints the same shadow warning afterward as a reminder.

**Workspace names** — warns (`⚠`, doesn't fail the check) about any workspace still written with capitals, or whose rename to lowercase did not finish: a mixed-case tmuxinator config, project settings file, state directory, run file, inbox file or state-file key. The row (`mixed-case-workspaces`) names each one with the parts still to rename, and says the next agentd start (or `launch`) of that workspace renames it; nothing needs fixing by hand. Names are compared from directory listings, since macOS disks ignore case. A live `workspace-Notes` window still matches after the rename, because window titles are matched ignoring case.

**Pipeline config** — also validates the current project's [pipeline config](README.pipeline.md), if it has one, reporting an invalid `timeout:` the same way `launch` does. It also warns, without failing the check, on a `pipeline:` block with no panes (it won't start a pipeline) and on a stage whose own text names the bare completion sentinel (workspace appends that itself with a per-dispatch token, so a stage repeating it verbatim can be confusing, though the tokened instruction still wins).

**Plans** — also warns (`⚠`, doesn't fail the check, and prints nothing when all is well) about the current project's [plans](README.plan.md): a plan whose `status:` is `paused` while its owner pane is still working, and a plan with a `[~]` task in a workspace that has no tmux session (the plan reads `stopped`). The fix line names `workspace plan start --name <workspace>`. A plan that can't be read is skipped.

A `--fix` that cannot do anything is reported as a failed check (`✗  --fix: ...`) among the others.

Exits with a non-zero status if any issues are found, so it can be used in scripts.

## JSON output

`doctor --json` runs the same checks and prints one document on stdout. Anything `--fix` prints goes to stderr.

```json
{"schema_version":1,"ok":true,"healthy":false,
 "mode":{"headless":false,"reason":"iTerm2"},
 "checks":[
  {"id":"tmux","ok":true,"status":"ok","message":"tmux (3+)","fix":null,"fix_command":null,"project":null},
  {"id":"window-tool","ok":false,"status":"fail","message":"window-tool (not found)",
   "fix":"https://github.com/zdennis/window-tool","fix_command":null,"project":null},
  {"id":"hooks","ok":false,"status":"fail","message":"session monitoring hooks not installed for myapp",
   "fix":"run 'workspace init' from the project directory","fix_command":"workspace init","project":"myapp"}],
 "summary":{"ok":1,"warn":0,"fail":2,"skipped":0,"issues":2}}
```

- `ok` at the top is `true` whenever the checks ran, as for the other report documents; read `healthy` for the verdict. `healthy` is true when no check failed and `--fix` did not fail. The exit code is 0 when healthy and 1 otherwise, with the document still printed.
- Each check has `id` (stable), `ok` (false only for `status` `fail`), `status`, `message` (the text report's line without its symbol), `fix`, `fix_command` and `project`.
- `status` is `ok`, `warn` (worth a look, not counted as an issue), `fail` (counted in `summary.issues`) or `skipped` (not needed here, e.g. iTerm2 headless, or no project to check).
- `fix` is the text after the report's `↳` (an install hint, or a sentence naming the command). `fix_command` is the same fix as a command to run when it is one, else `null`. Both are `null` when there is nothing to do.
- `project` names the project a check is about, and is `null` for machine-wide checks.
- Ids so far: `ruby`, `tmux`, `tmuxinator`, `iterm2`, `window-tool`, `git`, `gh`, `ascii-banner`, `templates`, `state-window-ids`, `mixed-case-workspaces`, `session-monitoring` (not inside a project), `hooks`, `hooks-codex`, `agent`, `edit-lock-hooks`, `statusline`, `context-<agent>`, `pipeline-config`, `pipeline-deprecated`, `pipeline-sentinel`, `plan`. A few ids can appear more than once (one row per pane, plan or warning). Treat an unknown id as a check this version of your tool does not know, and show its `message`.
- `--fix` with `--json` still performs the fix; when it cannot (outside a project, no statusLine-capable agent) there is a row with id `fix` and `status` `fail`. Its progress text goes to stderr. `summary.issues` equals `summary.fail`.
- `id` is not unique in a document: key a row by `id`, `project` and `message`.
- The capability is `doctor_json` 1 in [`capabilities --json`](README.capabilities.md).

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
