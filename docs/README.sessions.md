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

Each pane shows its index, kind, title, state (`working`/`idle`), how long it's been idle, and a LOCK column. Sub-agents started within a pane (Claude Code's `Task` tool invocations) are listed indented underneath their parent pane.

**LOCK column** — shows this pane's relationship to the `edit` lock ([`workspace lock`](README.lock.md)): `edit ✓` for the pane currently holding it, `edit #N` for a pane queued at position `N`, or blank for every other pane, including one with no agent at all. The lock store for the current directory's namespace is loaded once per render (never once per pane), so the column costs one extra file read, not a `git`/`ps` call per row.

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
