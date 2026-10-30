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
| `--fix` | Link the workspace skills that are missing or dangling ([skill links](#skill-links); this part works outside a project too), route Claude's `statusLine` through `workspace statusline`, backing up `settings.json` first, and install Codex's user-level hooks when Codex is on `PATH` (backing up `hooks.json` first; see [`init`](README.init.md#agent-session-hooks)). It also rewrites stale agent panes (see [agent pane commands](#agent-pane-commands)). Everything else it reports has to be fixed by hand. Restart any running Claude Code sessions afterward — Claude Code doesn't reload `statusLine` mid-session. Reports and fails (non-zero exit) when run outside a workspace project, or when no agent on `PATH` supports `statusLine` (only Claude Code does). A machine with only Codex on `PATH` reports nothing to fix instead of failing, since Codex's context usage is read by scraping its own pane — no `statusLine` to route |
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

**Promote snapshots** — warns (`⚠`, doesn't fail the check) when a known project's repository holds a `refs/workspace/promote/*` ref. `workspace promote` saves the changes it moves under that private ref, which `git stash list` does not show, and deletes it once the work is safe in the new worktree. A leftover ref means a promote stopped part way and may hold the only copy of that work. The row (`promote-snapshot`, one per project) lists each ref with its date, then the commands that recover it, the same ones `move_incomplete`'s `details.recover` gives: `git -C <path> stash apply --index <sha>`, then `git -C <path> update-ref -d <ref> <sha>` once the work is back. `doctor` only reads; it never deletes a ref. With none left there is one `✓  promote snapshots: none left behind` row.

**Pipeline config** — also validates the current project's [pipeline config](README.pipeline.md), if it has one, reporting an invalid `timeout:` the same way `launch` does. It also warns, without failing the check, on a `pipeline:` block with no panes (it won't start a pipeline) and on a stage whose own text names the bare completion sentinel (workspace appends that itself with a per-dispatch token, so a stage repeating it verbatim can be confusing, though the tokened instruction still wins).

**Plans** — also warns (`⚠`, doesn't fail the check, and prints nothing when all is well) about the current project's [plans](README.plan.md): a plan whose `status:` is `paused` while its owner pane is still working, and a plan with a `[~]` task in a workspace that has no tmux session (the plan reads `stopped`). The fix line names `workspace plan start --name <workspace>`. A plan that can't be read is skipped.

<a id="agent-pane-commands"></a>**Agent pane commands** — warns (`⚠`, doesn't fail the check) about each tmuxinator config (`~/.config/tmuxinator/workspace.<name>.yml`) whose agent pane runs a different command than [`agent.commands.<kind>`](README.config.md#agent-commands) gives for that workspace, e.g. `myapp: agent pane runs claude, but agent.commands.claude is claude-dev`. A config is made once, so changing the key does not touch configs written earlier, and `launch` rewrites one only when it starts a session from it (see [`launch`](README.launch.md#agent-pane-refresh)). The row is `agent-pane-command` (one per config, `project` is the workspace) with fix command `workspace doctor --fix`. A config whose pane already runs the program the configured command starts (which is every config when no `agent.commands.*` key is set) and one with no agent pane `doctor` can find produce no row. `--fix` rewrites each reported pane line (keeping the pane's flags) through a temp file and rename, after copying the file to `workspace.<name>.yml.workspace-backup-<timestamp>`; it leaves alone any config whose pane it cannot find, and works outside a workspace project too. A session already running keeps the old program until you relaunch it. Each rewritten config adds an `ok` row with the same id, `agent-pane-command`, whose message names the new program and the backup (`myapp: agent pane now runs claude-dev (backup: ...)`), so `doctor --fix --json` says what changed; the warning row is gone for it. A file that cannot be backed up or written is a `fix` row with status `fail`, and the next config is still tried. The PATH checks above: they look for the program of the configured command (`claude-dev`), not the bare agent name.

<a id="skill-links"></a>**Skill links** — checks the four [workspace skills](README.skills.md) in each coding agent found on this machine (Claude Code, Codex, Pi, OpenCode) that you have not declined in `workspace skills install`, one row per agent with the id `skills-<key>` (`skills-claude`, `skills-codex`, `skills-pi`, `skills-opencode`). It reads only, and runs with or without a project. When one agent has several bad links, a blocked path wins over a dangling link, and a dangling link over a missing one, so the row shows the worst. `✓` when all four links resolve, whichever install they point at. `⚠` when they are not installed, with fix command `workspace skills install` (or `workspace doctor --fix`). `✗` (counted as an issue) when a link of ours points at a checkout or install that no longer exists, with fix command `workspace doctor --fix`. `⚠` when a file, directory or someone else's link sits where a skill belongs; it is left alone, and the fix text says to run `workspace skills install` for the `mv` that moves it aside. `doctor --fix` links the skills that are missing or dangling, including a first install, in each such agent and in `~/.agents/skills` when that exists, and prints `--fix: <agent> skills linked`; the row then reads `linked now`. It never replaces a link that resolves, a real directory or a foreign link, and writes nothing in a directory where one of these blocks it. A repair counts like a pane fix, so `doctor --fix` does not exit 1 for the missing skills it just linked. When `--fix` cannot link, it adds a `skills` warning row (`--fix: ...`): from a linked git worktree (links into it would dangle once it is removed) or an install without the skills it links nothing (`skills not linked: ...`), and a directory it refused names the harness and the `mv`. In either case the missing and dangling rows then have `fix_command` null and a fix text that says to run `workspace skills install` from the main checkout or a Homebrew install.

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
- Ids so far: `ruby`, `tmux`, `tmuxinator`, `iterm2`, `window-tool`, `git`, `gh`, `ascii-banner`, `templates`, `state-window-ids`, `mixed-case-workspaces`, `promote-snapshot`, `session-monitoring` (not inside a project), `hooks`, `hooks-codex`, `agent`, `edit-lock-hooks`, `statusline`, `context-<agent>`, `pipeline-config`, `pipeline-deprecated`, `pipeline-sentinel`, `plan`, `agent-pane-command`, `skills-<harness>` (`skills-claude`, `skills-codex`, `skills-pi`, `skills-opencode`), `skills`. A few ids can appear more than once (one row per pane, plan or warning). Treat an unknown id as a check this version of your tool does not know, and show its `message`.
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
