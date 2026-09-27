# workspace sessions

Show which panes in a workspace are running a coding agent, whether each is working or idle, and any sub-agents they have started.

## Usage

```sh
workspace sessions [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--json` | Emit the raw payload instead of a table |
| `--watch` | Redraw until interrupted |
| `--interval SECONDS` | Seconds between redraws when watching (default 2) |

## Details

Requires a running agent daemon for the project (`workspace agent <project>`, or launched automatically by [`workspace launch`](README.launch.md)). If no daemon is listening, the command fails with a message telling you how to start one. `workspace doctor` also reports whether the daemon is running for the current project.

`project` defaults to the project detected from the current directory, same as other commands.

The daemon holds the session state; this command only asks for it, over the agent's Unix socket. That keeps `--json` and the table behind one code path, so scripting against `--json` sees exactly what the table shows.

`--json` output starts with `"schema_version": 1`, matching [`workspace lock status --json`](README.lock.md) and [`workspace dev status --json`](README.dev.md). If no agent daemon is listening, `--json` writes `{"schema_version":1,"error":"..."}` to stdout and exits 1, instead of the plain-text error the table view prints to stderr.

Each pane shows its index, kind, title, state (`working`/`idle`), how long it's been idle, and a LOCK column. Sub-agents started within a pane (Claude Code's `Task` tool invocations) are listed indented underneath their parent pane.

**LOCK column** — shows this pane's relationship to every lock in the project's namespace ([`workspace lock`](README.lock.md)), not just `edit`: a pane holding or queued for more than one lock (e.g. `edit` plus a `devenv` process lock) shows all of them, space-joined, `edit` first and any others alphabetical after it — `edit ✓ devenv #2`. A pane with no lock relationship shows blank, including one with no agent at all. A dead holder or waiter (its process no longer alive) never shows `✓`, and is skipped when numbering each lock's queue, so `#1` always refers to the next live waiter. The namespace is resolved from the *rendered workspace's* project root (its tmuxinator config), not the command's own working directory, so `workspace sessions other-project` always shows `other-project`'s lock state, never whatever project happens to be in front of it. If that project's root can't be resolved, the column is hidden rather than guessed. The lock store is loaded once per render (never once per pane), so the column costs one extra file read, not a `git`/`ps` call per row.

**`--json` lock fields** — alongside the human `"lock"` string described above, each pane in `--json` carries structured fields for scripting:

| Field | Values | Meaning |
|-------|--------|---------|
| `lock_state` | `"held"`, `"queued"`, or `null` | This pane's relationship to the `edit` lock, or to its first lock if it doesn't hold or queue for `edit` |
| `lock_position` | integer (1-based) or `null` | Live-queue position when `lock_state` is `"queued"`; `null` otherwise |
| `lock_name` | lock name or `null` | The lock these three fields describe; `null` if the pane holds or queues for no lock |
| `locks` | array | Every lock the pane holds or queues for, each `{"name", "state", "position"}` with the same meanings as above, in the same `edit`-first order as the `lock` label |

`lock_state`/`lock_position`/`lock_name` are kept for scripts written before multi-lock support: they always describe the `edit` lock when the pane has one, falling back to the pane's first lock (by the label's ordering) otherwise. A script that needs every lock a pane holds should read `locks` instead.

When the LOCK column is hidden (project root unresolved), all five fields (`lock`, `lock_state`, `lock_position`, `lock_name`, `locks`) are absent from each pane's JSON, not merely `null` — a consumer should treat a missing `lock_state` key the same as a `null` one.

## Examples

```sh
# Show sessions for the current directory's project
workspace sessions

# Show sessions for a named project
workspace sessions my-project

# Watch and redraw every 2 seconds
workspace sessions --watch

# Watch with a custom interval
workspace sessions --watch --interval 5

# Emit raw JSON for scripting
workspace sessions --json
```
