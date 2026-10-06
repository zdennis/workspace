# workspace daemon

Inspect and control agent daemons from outside them: which are running, whether one answers, its process, the tail of its log, and a restart (of one workspace's daemon, or of all of them) that doesn't hold the terminal. The daemon itself is `workspace agentd` (see [README.agentd.md](README.agentd.md)).

## Usage

```sh
workspace daemon status [WORKSPACE] [--json]
workspace daemon restart [WORKSPACE] [--wc-socket PATH] [--json]
workspace daemon restart --all [--json]
workspace daemon list [--json]
workspace daemon log [WORKSPACE] [--lines N] [--json]
```

`list` and `restart --all` cover every running daemon and take no workspace. For the others, `WORKSPACE` (or `--name WORKSPACE`) defaults to the project detected from the current directory. A workspace with no tmuxinator config is an `unknown_workspace` error (exit 1) for every subcommand.

| Option | Description |
|--------|-------------|
| `--name NAME` | Same as the positional workspace |
| `--lines N` | `log` only: how many trailing lines, 1 to 10000 (default 40) |
| `--wc-socket PATH` | `restart` only: work-coordinator socket for the new daemon (default: the one the old daemon was started with). A relative path is made absolute from the current directory |
| `--all` | `restart` only: restart every running daemon. Can't be combined with a workspace or `--wc-socket` |
| `--json` | Print one JSON document |

## list

Lists every running agent daemon, so you can see what is still running old code after installing a new version. Only workspaces that still have a tmuxinator config are found (a daemon left running for a workspace whose config was deleted is not listed), and each one's daemon is found from its socket (`~/.local/workspace/run/workspace-<name>.sock`), not from the process list. A daemon is listed when it answers on its socket, or when it holds the socket without answering (hung) and its command line is a `workspace agentd`. A hung daemon whose socket more than one process has open is listed too, with `pid: null`, so it isn't hidden. A socket file with no process behind it is stale and is left out. With none running it prints `No agentd processes are running.` and exits 0.

```
WORKSPACE  PID   STARTED               ANSWERING  SOCKET
api        4242  2026-09-24T09:12:03Z  yes        /Users/me/.local/workspace/run/workspace-api.sock
```

`list --json` is a read-only document like `status --json`: `schema_version`, `ok`, then `daemons` and `warnings`, with no `action` or `status`.

```json
{"schema_version":1,"ok":true,"daemons":[{"workspace":"api","pid":4242,"started_at":"2026-09-24T09:12:03Z","answering":true,
 "socket":"/Users/me/.local/workspace/run/workspace-api.sock","log":"/Users/me/.local/workspace/run/workspace-api.log","wc_socket":null}],
 "warnings":[]}
```

`pid` and `started_at` (UTC, from the process table) are `null` when they can't be read: more than one process has the socket open, `lsof` doesn't answer within 2 seconds, or the process table can't be read. `answering` is `false` for a hung daemon. `wc_socket` is the `--wc-socket` the daemon was started with, read from its command line; `null` when it has none or the path can't be read back. The version a daemon runs isn't recorded anywhere, so it isn't shown: compare `started_at` with when you installed.

## status

Reports whether a daemon answers on the workspace's socket, its pid (when exactly one process has the socket open, found with `lsof`), and the socket and log paths. A daemon that isn't running is an answer, not an error: exit 0 with `running: false`.

```json
{"schema_version":1,"ok":true,"workspace":"api","running":true,"pid":4242,
 "socket":"/Users/me/.local/workspace/run/workspace-api.sock",
 "log":"/Users/me/.local/workspace/run/workspace-api.log"}
```

`pid` is nullable: `null` when the daemon isn't running, `lsof` is missing or doesn't answer within 2 seconds (it is then killed), or more than one process has the socket open.

## restart

`workspace agentd restart [PROJECT]` is the same command under another name (see [README.agentd.md](README.agentd.md#restart)).

Stops the daemon that holds the workspace's socket with `SIGTERM`, waits up to 5 seconds for it to exit and let go of the socket, then starts a new one in the background the way `agentd --ensure` does (output is appended to the daemon log, so the old daemon's last lines are still there). A daemon that holds the socket but no longer answers (hung) is stopped too. A daemon run in a terminal is replaced by a detached one, and the terminal's `workspace agentd` ends. With nothing holding the socket it just starts one, and reports `started` instead of `restarted`; a stale socket file with no process behind it counts as nothing. In-flight pipeline state is on disk, so the new daemon picks it up as after any restart.

Nothing is signalled unless exactly one process other than `workspace` itself has the socket open (found with `lsof`) and its command line is a `workspace agentd`. Otherwise the row is `failed` and nothing is stopped: `not_agentd` when the holder is some other process or isn't in the process table, `not_stopped` when the holder can't be identified or confirmed (which includes `lsof` not answering within 2 seconds), when there are several, or when the process is still running 5 seconds after `SIGTERM` (it may still exit; check `daemon status`, then run `restart` again; there is no `SIGKILL`). `invalid_config` and `start_failed` mean the old daemon was stopped but no new one started. A failure exits 1.

The new daemon keeps the old one's work-coordinator socket. Without `--wc-socket`, `restart` reads the `--wc-socket PATH` the old daemon was started with from its command line and starts the new one with it; a daemon started without one gets a new daemon on the default socket. With `--wc-socket PATH` the new daemon uses that path instead; to move a daemon back to the default socket, name it (`~/.local/run/work-coordinator/work-coordinator.sock`). When the old path can't be read back (it is relative, or has a space in it), the row is `failed` with reason `wc_socket_unknown` and nothing is stopped: run `restart` again with `--wc-socket PATH`. When nothing was running there is no old socket to keep, and the new daemon uses the default unless `--wc-socket` is given.

The command line is read the way the daemon's own option parser read it: an abbreviated flag (`--wc PATH`) and `--wc-socket=PATH` count, and when the flag was given twice the last one is used. `ps` prints the arguments joined by spaces, so two shapes of a path with a space are misread instead of refused: a path whose last word is the workspace's name when the name wasn't given with `--name` (`agentd api --wc-socket "/tmp/wc api"` is read as `/tmp/wc`), and a path whose next word starts with a dash (`"/a -b/wc.sock"` is read as `/a`). Pass `--wc-socket PATH` for a daemon started with such a path.

Once the old daemon has stopped, its command line is gone. So when a restart fails after signalling it (`not_stopped` at the deadline, `invalid_config`, `start_failed`), the message names the socket to pass on the next run (`workspace daemon restart NAME --wc-socket PATH`) and the row carries it in `wc_socket`; running `restart` again without it would start the new daemon on the default socket. If another caller (a `launch`, an `agentd --ensure`) starts a daemon between the stop and the start, that daemon is the one running, with whatever socket its caller chose: the row is `restarted` with `wc_socket: null`.

`restart` writes no event itself: the old daemon records `daemon_stopped` when it exits on `SIGTERM` and the new one records `daemon_started` (see [README.event-log.md](README.event-log.md)). A daemon that has to be killed with `SIGKILL` records no stop.

`--json` prints the action document (see [README.json.md](README.json.md)); text goes to stderr:

```json
{"schema_version":1,"ok":true,"action":"restart","status":"ok",
 "results":[{"workspace":"api","outcome":"restarted","reason":null,"message":null,"old_pid":4242,"pid":4311,"wc_socket":null}],
 "warnings":[],"summary":{"restarted":1}}
```

`outcome` is `restarted`, `started` or `failed`. `reason` on a failure is `not_agentd`, `not_stopped`, `wc_socket_unknown`, `invalid_config` or `start_failed`. `old_pid` is `null` when none was running; `pid` is `null` when the new daemon's process can't be identified, which can be the case right after it starts. `wc_socket` is the work-coordinator socket the new daemon was started with, whether `--wc-socket` named it or the old daemon had it; `null` means the default socket, or that another caller started the daemon. On a `failed` row it is the socket to pass with `--wc-socket` when running `restart` again, and `null` when there is none to pass (none was named, the old daemon had none, or it couldn't be read: `wc_socket_unknown`, `not_agentd`, an unidentified holder).

### restart --all

Restarts every daemon `list` finds, one after another, each the way a single `restart` does: stopped with `SIGTERM` only after its command line is confirmed to be an `agentd`, waited for (up to 5 seconds) until it lets go of its socket, then started again by the currently installed `workspace` with the same work-coordinator socket. Run it after installing a new version, so every daemon runs the new code. One workspace failing doesn't stop the rest (an error raised for one, such as the process table being unreadable, is its row too, with the error's code as `reason`, or `restart_failed` when it has none): each gets its own row, with the failure `reason` and `message` as for a single restart. The exit status is 1 if any row failed (with `--json`, 3 when only some did and 1 when all did, as for other actions). With none running it says so and exits 0. `restart --all` takes no workspace and no `--wc-socket`; each daemon keeps its own.

With `--json` it prints the same action document with one row per workspace; `status` is `partial` when some rows failed.

## log

Prints the last lines of the daemon log, `~/.local/workspace/run/workspace-<name>.log` (the path is computed by workspace, including the truncation applied to long names, so use `path` rather than rebuilding it). Only a daemon started in the background (`agentd --ensure`, `daemon restart`, `launch`) writes this file; one run in a terminal writes to that terminal. Only the last megabyte is read, and invalid UTF-8 is replaced with `?`.

```json
{"schema_version":1,"ok":true,"workspace":"api","path":"/Users/me/.local/workspace/run/workspace-api.log",
 "exists":true,"lines":["workspace agent 'api' ready"]}
```

`exists` is `false` (with `lines: []`) when no background daemon has written a log yet.

## Errors

With `--json`, failures are the usual error envelope (see [README.json.md](README.json.md)): `usage` for a bad option, a missing subcommand or workspace, a `--lines` out of range, a workspace given to `list` or `restart --all`, or `--all` where it doesn't apply; `unknown_workspace` from all three subcommands when the workspace has no tmuxinator config (a typo is never reported as a stopped daemon).
