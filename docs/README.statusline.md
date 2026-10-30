# workspace statusline

Render Claude Code's status line, and record its context-window usage for the pane it's running in.

## Usage

Install as Claude Code's `statusLine` command (in `~/.claude/settings.json` or a project's `.claude/settings.json`):

```json
{
  "statusLine": {
    "type": "command",
    "command": "workspace statusline"
  }
}
```

Restart any running Claude Code sessions after installing or changing this (by hand or via `workspace doctor --fix`) — Claude Code doesn't reload `statusLine` mid-session. `workspace start` also installs this routing into each new or adopted worktree's `.claude/settings.json` automatically, alongside its session-monitoring hooks.

If `.claude/settings.local.json` also has a `statusLine` entry, it wins over this one at runtime (Claude Code deep-merges settings.json and settings.local.json, with the local file's keys taking precedence). `workspace doctor` checks for this and reports the shadow; `--fix` only ever writes `settings.json`, since `settings.local.json` is the user's own file. Remove the `statusLine` entry from `settings.local.json` by hand if you want workspace's rendering to actually take effect.

Claude Code runs this on every render, piping one JSON payload on stdin (model, cwd, cost, `context_window.used_percentage`, etc.) and printing whatever it writes to stdout.

## Examples

Each run records its reading against `$TMUX_PANE` (or `$CLAUDE_PID`), which `workspace sessions --json` then reports. Run these examples outside an agent's pane so they don't overwrite its real reading.

```sh
workspace statusline <<< '{"context_window":{"used_percentage":42}}'    # see the line Claude Code would show for 42% context used
workspace statusline <<< '{}'    # empty input still prints a line and exits 0
workspace statusline < payload.json    # replay a saved Claude Code payload while debugging a delegate command
```

## What it does

1. **Records the reading.** `context_window.used_percentage` is stored keyed on `$TMUX_PANE` — the same pane identity `workspace session-event` and `workspace sessions` use — along with the session's total cost (`cost.total_cost_usd`), its total duration (`cost.total_duration_ms`) and the model's display name, the fields [`workspace sessions --json`](README.sessions.md) reports. If `$TMUX_PANE` isn't set (rare, but the environment a status-line process runs in isn't guaranteed to have it), the reading is stored under `$CLAUDE_PID` instead, so [`workspace sessions --json`](README.sessions.md) can still find it via the pane's process tree. Nothing is ever guessed: if no reading was recorded, `sessions --json` says so and gives a reason.
2. **Prints a line.** By default this is workspace's own renderer: model, directory, git branch, a context usage bar, session cost, and turn duration — no network calls, ever. Set `statusline.command` in the global config to delegate rendering to another command instead; the same stdin JSON is piped to it, and its stdout is printed as-is (capped at 64 KB). A delegate is given about 3 seconds; if it times out, exits non-zero, or fails to start, the built-in line is printed instead.

This command is designed to never break Claude's status bar: bad or empty input, or a storage failure, still prints something and exits 0.

## Configuration

Set these with [`workspace config set`](README.config.md) — they're global (one status line and one context source per machine, not per project):

| Key | Description |
|-----|-------------|
| `statusline.command` | Delegate rendering to another command instead of the built-in renderer |
| `context.source` | `statusline` (default) or `scrape` — see below |
| `context.pattern` | Regex with one capture group, used when `context.source` is `scrape` |
| `context.patterns` | Edited by hand in the config file: a mapping of agent kind to a regex with one capture group (percent used). That kind is read from its pane whatever `context.source` says; Codex has a built-in one. See [`handoff`](README.handoff.md#codex) |

```sh
workspace config set statusline.command "~/bin/my-statusline"
workspace config set context.source scrape
workspace config set context.pattern '(\d+)% ctx'
```

### Reading context another way: `context.source: scrape`

If you'd rather not route Claude's status line through `workspace statusline` (or a delegate command doesn't print `used_percentage` the way you'd like), set `context.source` to `scrape` and give a `context.pattern`: `workspace sessions` then reads the pane's own visible text and applies the regex, taking the percentage from its one capture group, instead of reading a stored reading.

## Where the reading is used

[`workspace sessions --json`](README.sessions.md) reports each coding-agent pane's `context_pct`, or `context_error` with a reason when it can't be determined:

- no reading recorded (status line not routed through workspace, or not rendered yet)
- no pane id (status-line process lacked `$TMUX_PANE`) — usually resolved automatically via `$CLAUDE_PID`
- no context.pattern configured (scrape mode)
- pattern didn't match (scrape mode)
- couldn't scrape the pane (every scan slot busy) and no fresh reading is cached — scrape mode shares the machine-wide scan slot pool, and falls back to the pane's last reading only while it's ≤30s old
- the last reading is from an earlier Claude session in this pane

Every one of these comes with the same fix: run `workspace doctor --fix` (or add a `statusLine` entry to `~/.claude/settings.json` by hand: `"statusLine": {"type": "command", "command": "workspace statusline"}`), switch to scrape mode (`workspace config set context.source scrape` and `context.pattern`), or pass `--context-pct N` to whatever command needs the number.

A stale reading is still reported, with its timestamp — Claude's status line only renders between turns, so a long-running tool call means no fresher reading exists yet. `workspace` never estimates a percentage it hasn't actually read.
