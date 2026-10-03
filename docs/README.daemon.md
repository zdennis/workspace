# workspace daemon

Inspect and control a workspace's agent daemon from outside it: whether it answers, its process, the tail of its log, and a restart that doesn't hold the terminal. The daemon itself is `workspace agentd` (see [README.agentd.md](README.agentd.md)).

## Usage

```sh
workspace daemon status [WORKSPACE] [--json]
workspace daemon restart [WORKSPACE] [--wc-socket PATH] [--json]
workspace daemon log [WORKSPACE] [--lines N] [--json]
```

`WORKSPACE` (or `--name WORKSPACE`) defaults to the project detected from the current directory. A workspace with no tmuxinator config is an `unknown_workspace` error (exit 1) for every subcommand.

| Option | Description |
|--------|-------------|
| `--name NAME` | Same as the positional workspace |
| `--lines N` | `log` only: how many trailing lines, 1 to 10000 (default 40) |
| `--wc-socket PATH` | `restart` only: work-coordinator socket for the new daemon |
| `--json` | Print one JSON document |

## status

Reports whether a daemon answers on the workspace's socket, its pid (when exactly one process has the socket open, found with `lsof`), and the socket and log paths. A daemon that isn't running is an answer, not an error: exit 0 with `running: false`.

```json
{"schema_version":1,"ok":true,"workspace":"api","running":true,"pid":4242,
 "socket":"/Users/me/.local/workspace/run/workspace-api.sock",
 "log":"/Users/me/.local/workspace/run/workspace-api.log"}
```

`pid` is nullable: `null` when the daemon isn't running, `lsof` is missing, or more than one process has the socket open.

## restart

Stops the daemon that holds the workspace's socket with `SIGTERM`, waits up to 5 seconds for it to exit and let go of the socket, then starts a new one in the background the way `agentd --ensure` does (output is appended to the daemon log, so the old daemon's last lines are still there). A daemon that holds the socket but no longer answers (hung) is stopped too. A daemon run in a terminal is replaced by a detached one, and the terminal's `workspace agentd` ends. With nothing holding the socket it just starts one, and reports `started` instead of `restarted`; a stale socket file with no process behind it counts as nothing. In-flight pipeline state is on disk, so the new daemon picks it up as after any restart.

Nothing is signalled unless exactly one process other than `workspace` itself has the socket open (found with `lsof`) and its command line is a `workspace agentd`. Otherwise the row is `failed` and nothing is stopped: `not_agentd` when the holder is some other process or isn't in the process table, `not_stopped` when the holder can't be identified or confirmed, when there are several, or when the process is still running 5 seconds after `SIGTERM` (it may still exit; check `daemon status`, then run `restart` again; there is no `SIGKILL`). `invalid_config` and `start_failed` mean the old daemon was stopped but no new one started. A failure exits 1.

`restart` writes no event itself: the old daemon records `daemon_stopped` when it exits on `SIGTERM` and the new one records `daemon_started` (see [README.event-log.md](README.event-log.md)). A daemon that has to be killed with `SIGKILL` records no stop.

`--json` prints the action document (see [README.json.md](README.json.md)); text goes to stderr:

```json
{"schema_version":1,"ok":true,"action":"restart","status":"ok",
 "results":[{"workspace":"api","outcome":"restarted","reason":null,"message":null,"old_pid":4242,"pid":4311}],
 "warnings":[],"summary":{"restarted":1}}
```

`outcome` is `restarted`, `started` or `failed`. `reason` on a failure is `not_agentd`, `not_stopped`, `invalid_config` or `start_failed`. `old_pid` is `null` when none was running; `pid` is `null` when the new daemon's process can't be identified, which can be the case right after it starts.

## log

Prints the last lines of the daemon log, `~/.local/workspace/run/workspace-<name>.log` (the path is computed by workspace, including the truncation applied to long names, so use `path` rather than rebuilding it). Only a daemon started in the background (`agentd --ensure`, `daemon restart`, `launch`) writes this file; one run in a terminal writes to that terminal. Only the last megabyte is read, and invalid UTF-8 is replaced with `?`.

```json
{"schema_version":1,"ok":true,"workspace":"api","path":"/Users/me/.local/workspace/run/workspace-api.log",
 "exists":true,"lines":["workspace agent 'api' ready"]}
```

`exists` is `false` (with `lines: []`) when no background daemon has written a log yet.

## Errors

With `--json`, failures are the usual error envelope (see [README.json.md](README.json.md)): `usage` for a bad option, a missing subcommand or workspace, or a `--lines` out of range; `unknown_workspace` from all three subcommands when the workspace has no tmuxinator config (a typo is never reported as a stopped daemon).
