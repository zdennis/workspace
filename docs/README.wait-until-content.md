# workspace wait-until-content

Poll a tmux pane's scrollback until it contains a target string, then exec a command in this process. The command replaces the `workspace` process, so it owns the terminal: direct Ctrl-C and untouched STDIN/STDOUT/STDERR. Auto-detects the project from the current directory when the project name is omitted.

Port of the standalone `wait-until-content` script. It is the blocking sibling of `workspace run`: `run` sends a command to a pane and returns immediately; `wait-until-content` blocks until a pane shows expected content, then runs a command locally.

## Usage

```sh
workspace wait-until-content [project] "content" [options] [-- command...]
```

## Options

| Option | Description |
|--------|-------------|
| `--pane N` | Target pane by zero-based index, `window.pane` (e.g. `0.1`), a tmux pane id (e.g. `%19`, from `workspace sessions --json`), `bottom` for the last pane, or a title substring (e.g. `Claude Code`) (default: `bottom`) |
| `--lines N` | Match against the last N lines of scrollback (default: 100, must be positive) |
| `--interval SECONDS` | Seconds between polls (default: 0.5, must be positive) |
| `--max-wait-time SECONDS` | Give up after this many seconds and exit 1 (default: wait forever) |
| `--since-start` | Only match content written after this command starts |
| `-e CMD`, `--exec CMD` | Shell command to exec on match; a command after `--` takes precedence |
| `-- command...` | Command to exec on match, passed as an argv array with no shell re-quoting |

## Details

**Match window** — by default, each poll captures the last `--lines` lines (default 100) of the pane's scrollback and matches the whole blob with a substring `include?`, so content that was already on screen matches immediately. Multi-line content strings match across the blob. With `--since-start`, a baseline of the full scrollback is recorded when the command starts and only content written after that point is considered (still bounded to the last `--lines` lines of it), so stale scrollback from an earlier run cannot trigger a premature match. The baseline is anchored on the baseline content itself, not a line offset: each poll finds the longest suffix of the baseline that still survives at the top of the capture and matches only what follows it, so post-start content still matches once the scrollback hits tmux's history limit (old lines evicted from the top as new ones arrive) and pre-start content cannot match after a mid-wait `clear-history` (the visible screen survives, so the surviving baseline still anchors the window). When the baseline has been fully evicted, everything in the capture is post-start content. Known limitation: if the pane is reflowed mid-wait (e.g. a resize rewraps lines), the baseline anchor can be lost and pre-start content may be treated as post-start — content alone cannot distinguish reflow from full history eviction. Previously a truncated or cleared history errored out mid-wait; that raise is gone because the content anchor handles eviction and clearing directly. If the baseline capture itself fails at start, the command errors out rather than silently baselining at zero (which could match pre-existing content); a genuinely empty (zero-line) pane still baselines at 0 legitimately. A transient capture failure, by contrast, reads as no-match and polling continues.

**Exec semantics** — the command after `--` is passed straight to `exec` as an argv array with no shell re-quoting; `-e/--exec` is a shell string (metacharacters like `&&` work) validated for balanced quoting at parse time. If both are given, the `--` command wins. The exec'd process replaces the `workspace` process, which matters for long-running follow-ups: interrupts go directly to the exec'd process and the terminal is handed over cleanly.

**Flush before exec** — status output is flushed to stdout and stderr immediately before the exec hand-off, so the banner and `✓ Matched` / `▶ Executing` lines survive when stdout is piped or redirected.

**Exit codes** — 0 on match (with a successful exec hand-off); 1 on timeout, exec failure, usage error, or a mid-wait failure (the pane or session disappearing), including a failed `--since-start` baseline capture at start.

**Pane anchoring** — the pane spec is resolved once, at start, to the pane's tmux pane id, and every poll re-resolves by that id, so if the target pane closes and tmux renumbers the window, the wait errors out instead of silently switching to whatever pane a `bottom`/index/title selector would pick up next — a closed pane is a real failure, not a pane switch. If the pane or session no longer exists, the id no longer resolves and the command errors out immediately instead of polling forever. A transient capture failure against a pane that still exists reads as no-match and polling continues; `--max-wait-time` governs giving up.

**Deadline** — sleeps are bounded to the time remaining, so `--max-wait-time` is honored even when `--interval` exceeds it: `--interval 30 --max-wait-time 10` gives up after 10 seconds, not 30.

**Auto-detection** — when only the content positional is given, the project is detected from the current working directory the same way `workspace capture` and `workspace run` do. With two positionals, the first is the project and the second is the content.

## Examples

```sh
# Wait for a dev server to boot, then open a browser (project auto-detected)
workspace wait-until-content "Listening on" -- open http://localhost:3000

# Explicit project, specific pane, give up after 2 minutes
workspace wait-until-content scooter "Ready to accept connections" \
  --pane 0 --max-wait-time 120 -- bin/console

# Attach a console once a test suite prints its sentinel
workspace wait-until-content scooter "WORKSPACE_DONE" --pane "Claude Code" -- irb

# Ignore stale scrollback: only match output written from now on
workspace wait-until-content scooter "namespace is running" \
  --since-start --max-wait-time 60 -- ./scripts/attach.sh

# Shell-string form (metacharacters work)
workspace wait-until-content scooter "READY" -e 'echo matched && osascript -e "display notification \"ready\""'
```
