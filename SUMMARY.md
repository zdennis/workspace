# Session Monitoring for Workspace

## What we're building

A way for `workspace` to answer "what coding-agent sessions are running here, and
are they active?" — the capability that makes Orca's left sidebar useful, but built
on tmux so it works with workspace's tmuxinator-based sessions.

The long-term goal is a daemon per workspace that holds live state, with richer
functionality layered on over time. A real UI is a separate project; this work
builds the state and the socket a UI would read.

## Why it isn't just process inspection

Two sources feed the monitor, and neither is sufficient alone:

- **tmux and the process table** say *which pane hosts an agent* and whether its
  output is still moving. This works for every agent, including ones with no hook
  system at all.
- **Hook events** say *what the agent is doing*. Claude Code runs sub-agents
  in-process, so `pgrep` shows one `claude` PID whether it is running zero
  sub-agents or five. Only the agent can report them.

## Design decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Pane identity | tmux `pane_id` (`%23`) | Indices shift on split/close; an index-keyed entry silently follows the wrong pane |
| Scope | Current workspace only | Matches the existing per-workspace daemon; no cross-socket aggregation |
| Hook transport | Unix socket, fail silently | Reuses the agent protocol; a hook must never fail an agent's turn |
| No daemon running | Error, exit 1 | One code path, and the message says how to start one |
| Activity signal | Pane output changed | Agents block on the network most of a turn, so CPU is not usable |

## What exists now

Both pieces are committed on `feat/session-monitor`.

### Hook installation (`aa7c6dc`)

`workspace init` detects installed agents, prints the exact settings fragment it
wants to add, and asks before writing. `--install-hooks` / `--no-install-hooks`
keep it scriptable.

- `lib/workspace/agent_provider.rb` — the registry. Claude Code, Codex, OpenCode
  and Pi are entries; adding another agent is one more entry, not a conditional.
  An agent with no hook system still appears, marked "monitored by pane activity
  only", so the gap is visible rather than silent.
- `lib/workspace/file_backup.rb` — every edit is copied aside first, to
  `<file>.workspace-backup-<timestamp>`, and the path is printed. Backups sit next
  to the original so someone who finds an unexpected `settings.json` finds the
  restore in the same listing.
- `lib/workspace/hook_installer.rb` — merges rather than overwrites. The user's own
  hooks and unrelated settings survive, a re-run is a no-op, and an unparseable
  settings file raises instead of being replaced.

### Session monitoring (`7af816f`)

- `lib/workspace/process_tree.rb` — one `ps` call per scan, then a tree walk.
- `lib/workspace/session_monitor.rb` — holds the state; runs inside the existing
  `workspace agent` daemon alongside `SentinelPoller`.
- `lib/workspace/commands/session_event.rb` — receives one hook event and forwards
  it. Never blocks, never fails.
- `lib/workspace/commands/sessions.rb` — `workspace sessions`, `--json`, `--watch`.
- `lib/workspace/tmux.rb` — added `pane_details` and `session_name_for_pane`.

```
$ workspace sessions

workspace: context-engineering

PANE  KIND      TITLE                   STATE     IDLE
0.0   shell     zsh                     idle      6s
0.1   claude    Claude Code             working   0s
                └─ eval-baseline        done
                └─ eval-baseline-2      running
```

## Two things real data changed

Both were found by running against live tmux and real `ps` output, not by reading
documentation:

- **`ps comm=` truncates at 16 characters**, which mangles every absolute path
  (`/private/tmp/cla`). Matching had to move to argv[0].
- **Claude Code leaves background helpers in the process tree** (`daemon run`,
  `bg-pty-host`, `bg-spare`). Matching one would report a pane as running an
  interactive session long after that session exited, so providers carry a list of
  argument markers that disqualify a match.

## Verification approach

`workspace sessions --watch` is the throwaway harness — a reprint loop, no gems.
It was chosen over an HTTP server or an Electron/TUI app because the bugs here are
stale entries, duplicate agents, and idle detection that never flips back: obvious
in a table, invisible in a log. `--json` is the real contract and `--watch` renders
from it, so the display cannot drift from what a consumer sees.
