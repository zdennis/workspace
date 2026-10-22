# workspace agent

Umbrella for driving a workspace's agent: send it work with `workspace agent run "prompt"`, or start the daemon with [`workspace agentd`](README.agentd.md).

## Usage

```sh
workspace agent run PROMPT [options]
workspace agent status request --pane PANE [--name NAME] [--json]
workspace agent status post --summary TEXT [--task ID] [--progress N/M] [--reply-to ID] [--json]
workspace agent executables [--kind KIND] [--name WS] [--json]
```

`agent status` is described under [Status](#status). `agent executables` is described under [Agent executables](#agent-executables).

The prompt is the positional arguments joined with a space, so a multi-word prompt does not need quoting:

```sh
workspace agent run Add OAuth support
```

## Options

| Option | Description |
|--------|-------------|
| `--name NAME` | Workspace name (default: detected from current directory) |
| `--work-item REF` | Work item reference, e.g. `WC-42` (default: random UUID) |
| `--dry-run` | Print the message without sending it |
| `--json` | Print one JSON document with the reply (see [JSON output](#json-output)) instead of text |

## Details

`agent run` builds and sends a `command` message to the workspace agent's socket — the same message [`workspace agent-run command`](README.agent-run.md) sends, minus the default body: the prompt positional is required. The message is printed before it is sent, so a generated `work_item_ref` (see the notes in [README.agent-run.md](README.agent-run.md)) is visible for later `inject` or `pipeline status` use.

**One agent per workspace** — on startup the agent probes its own socket at `~/.local/workspace/run/workspace-<name>.sock`. With a very long workspace name the filename is truncated with a short hash suffix (derived deterministically from the name) so the path stays within the OS's 104-byte socket path limit. If something answers, it refuses to start rather than stealing the socket from a running agent. A socket left behind by an unclean shutdown does not answer, so it is removed and the agent starts normally.

Sending work requires the daemon to be listening. Start one with [`workspace agentd <project>`](README.agentd.md) (`workspace launch` starts one automatically).

### Deprecation window

Before `agent` became this umbrella, `workspace agent` *was* the daemon. Daemon-era invocations — `workspace agent --name myproject --force`, or bare `workspace agent` — still start the daemon during the deprecation window (installed templates launch it that way), with a warning on stderr pointing at `workspace agentd`. A future release will drop the fallback.

## Examples

```sh
# Send a prompt to the current workspace's pipeline
workspace agent run "Add OAuth support"

# Send it to a named workspace with a known work-item ref, without sending
workspace agent run --name myapp --work-item WC-42 "Add OAuth support" --dry-run

# A prompt that starts with a dash needs --
workspace agent run -- "--verbose logging"

# Start the daemon for myapp
workspace agentd myapp
```

## Status

Ask an agent pane what it is doing, and get the answer back as an event linked to the question. Capability `agent_status` 1.

```sh
workspace agent status request --pane PANE [--name NAME] [--json]
workspace agent status post --summary TEXT [--task ID] [--progress N/M] [--reply-to ID] [--json]
```

| Option | Verb | Description |
|--------|------|-------------|
| `--pane PANE` | request | Pane id (`%19`) or `window.pane` (`0.1`) of the workspace's own tmux session (required) |
| `--name NAME` | request | Workspace name (default: detected from current directory) |
| `--summary TEXT` | post | One line on what the agent is doing (required). Runs of whitespace and control characters become one space, and it is cut to 500 characters |
| `--task ID` | post | The task being worked on (cut to 128 characters) |
| `--progress N/M` | post | Steps done out of the total, whole numbers with `0 <= N <= M` and `M >= 1` |
| `--reply-to ID` | post | The status request this answers |
| `--json` | both | Print one JSON document (below) |

Every option also takes the `--option=value` form.

**request** is run by a person or an app. The workspace's agent daemon types this one line into the pane, and never any caller text:

```text
Status request <ID>: run workspace agent status post --reply-to <ID> --summary "<one line: what you are doing and what is next>" (add --task ID and --progress N/M if you have them), then carry on.
```

Nothing is typed unless the pane can take text safely. The test is run when the request arrives, again just before typing (under the daemon's delivery lock, with a fresh screen), and once more after the line is pasted and before Enter is pressed:

1. A known coding agent whose input prompt workspace can recognize runs in the pane: today that is Claude Code. A shell is `not_an_agent`; a pane the daemon hasn't scanned or identified yet is `pane_not_ready` with `reason` `unknown`; another agent (Codex, for one) is `reason` `unsupported_agent`, since an open dialog can't be ruled out from its screen.
2. No wait is open: the daemon's state for the pane is `idle` or `working`, not `waiting` (a permission prompt or a question raised by the main agent or a sub-agent). Otherwise `reason` `waiting`.
3. The main agent isn't running `AskUserQuestion` or `ExitPlanMode`, whose menu a typed Enter would answer. Otherwise `reason` `question_open`.
4. The pane's screen shows the agent's input prompt (Claude Code: a rule line with `❯` under it, as `launch --prompt` waits for). A dialog replaces Claude Code's input box, so this also catches a permission prompt the daemon hasn't heard about yet. Otherwise `reason` `no_input_prompt`.
5. The input line (after the last prompt on screen) is empty or shows only the placeholder, so the line isn't added to a person's draft. Otherwise `reason` `input_not_empty`. For the check after pasting, the line must instead start with the request: a menu row or a draft there means Enter would answer or send something else (`reason` `input_changed`).

If the check after pasting fails, Enter is not pressed: the result is `not_submitted` with the `reason`, and the line sits unsent in the input box.

A `working` pane passes: Claude Code queues text typed during a turn and reads it when the turn ends.

One request is open per pane at a time. Asking again while one is open is refused with `status_request_open`, which names the open request; nothing is typed. A request is tied to the pane's id and to the pid tmux started in the pane, and expires 10 minutes after it opens. Requests live in the agent daemon's memory, so a daemon restart drops them.

**post** is run by the agent, in its own pane: the pane is `$TMUX_PANE` and the workspace is the one whose tmux session the pane is in (a worktree's session name differs from its workspace name, and is looked up). The daemon writes an `agent_status` line to its hook event file, so it shows in [`events --follow`](README.events.md) with `boot_id` and `seq`. The summary is stored as text and never typed anywhere. With `--reply-to`, the post is accepted only while the request is open, from the pane that was asked, and while that pane's pid is the one recorded (a new tmux server reuses pane ids, but not pids). A refused post logs nothing; a post from the wrong pane leaves the request open for the right one. A post without `--reply-to` is an unprompted status.

### Status JSON output

`agent status request --json`:

```json
{"schema_version":1,"ok":true,"workspace":"api","request_id":"sr-0a1b2c3d4e5f","expires_at":"2026-10-17T22:10:00Z","delivery":"submitted","pane":"0.1","pane_id":"%19"}
```

`agent status post --json` is the line as logged, plus `truncated` (whether the summary was cut):

```json
{"schema_version":1,"ok":true,"truncated":false,"at":"2026-10-17T22:01:12.345Z","workspace":"api","pane_id":"%19","boot_id":"01J...","seq":42,"summary":"Writing specs for the parser","task":"T3","progress":{"done":3,"total":7},"reply_to":"sr-0a1b2c3d4e5f"}
```

Failures are the usual envelope (see [JSON output](README.json.md)), with the daemon's other reply fields in `details`:

| Code | Verb | Meaning |
|------|------|---------|
| `pane_not_ready` | request | Not safe to type now; `details.reason` is `unknown`, `unsupported_agent`, `waiting`, `question_open`, `no_input_prompt` or `input_not_empty` (after pasting, `input_changed`, as `not_submitted`) |
| `not_an_agent` | request | The pane runs a shell |
| `status_request_open` | request | A request is already open on the pane; `details.request_id`, `details.expires_at` |
| `not_delivered` | request | The line never reached the pane; the request was dropped, so asking again is safe |
| `not_submitted` | request | The line reached the pane but Enter wasn't pressed (the check after pasting failed, `details.reason`) or wasn't confirmed; exit 2. The request stays open (`details.request_id`) and a reply is still accepted |
| `bad_pane`, `no_session`, `wrong_session`, `no_such_pane` | request | The pane isn't one of the workspace's own |
| `no_pane` | post | Not run from a tmux pane |
| `status_request_unknown` | post | No open request has that id (answered, never made, or the daemon restarted) |
| `status_request_expired` | post | The request expired |
| `status_reply_wrong_pane` | post | Another pane was asked |
| `status_request_stale` | post | The pane id was reused since the request |
| `status_not_logged` | post | The daemon couldn't write the line |
| `no_daemon`, `connection_failed`, `unreadable_reply` | both | The agent daemon couldn't be asked. `connection_failed` on `request` can also mean the daemon took longer than 30 seconds, in which case the line may have been typed; a second `request` then answers `status_request_open` with the id |
| `unknown_type` | both | The agent daemon predates `agent status`; restart it with `workspace agentd restart NAME` |

Exit codes: 0 done; 1 refused or failed; 2 from `request` when the line landed but wasn't confirmed submitted.

```sh
# Ask pane %19 of api for its status
workspace agent status request --name api --pane %19 --json

# Answer it (run by the agent in pane %19)
workspace agent status post --reply-to sr-0a1b2c3d4e5f --summary "Writing specs for the parser" --progress 3/7

# Watch the replies
workspace events --follow --json --types agent_status
```

## Agent executables

`workspace agent executables` lists the programs on `PATH` that belong to each coding agent family (`claude`, `codex`, `opencode`, `pi`) and marks the one each family runs, so you can pick a value for `agent.commands.<kind>`. It only reads directory listings and file modes; it never runs or opens a program.

| Option | Description |
|--------|-------------|
| `--kind KIND` | List one family only (`claude`, `codex`, `opencode` or `pi`) |
| `--name WS` | Read the settings of this workspace (default: the workspace of the current directory, else the global settings alone) |
| `--json` | Print one document (below) |

A file counts for a family whose executable is `E` when it is a regular, executable file in an absolute `PATH` directory and its name matches `\A<E>(-[A-Za-z0-9._+-]+)?\z`: `E` itself, or `E-` and a suffix. `claude`, `claude-dev` and `claude-opus` match `claude`. A bare prefix is not used because short names collide with unrelated programs: `pi*` would match `pick`, `pip3` and `pinentry`. When a name appears in several `PATH` directories, the first one is the row and the others are listed in `shadowed`.

Text output groups rows by family. The first lines name the workspace and its `agent.kind`; each family shows the program it runs and which layer set that, and `*` marks the row it runs:

```
Workspace: workspace
Main agent kind: claude

claude (runs claude, from the default)
  * claude  /Users/me/.local/bin/claude
    claude-opus  /Users/me/bin/claude-opus

opencode (runs opencode, from the default)
  none found

* marks what the family runs. Set it with `workspace config set agent.commands.<kind> VALUE`.
```

`--json` prints:

```json
{"schema_version":1,"ok":true,"workspace":"workspace","path_dirs":["/Users/me/bin","/opt/homebrew/bin"],
 "executables":[{"kind":"claude","name":"claude-opus","path":"/Users/me/bin/claude-opus","source":"path","found":true,"builtin":false,"shadowed":[]}],
 "effective":{"claude":{"program":"claude","path":"/Users/me/.local/bin/claude","layer":"default","found":true},
              "opencode":{"program":"opencode","path":null,"layer":"default","found":false}},
 "kind":"claude"}
```

- `workspace` is null when none is named or detected; the global settings are read then.
- `path_dirs`: the absolute, existing `PATH` directories scanned, without duplicates.
- `executables`: one row (its `kind` is the family; the top-level `kind` is the effective `agent.kind`) per name and family, the family's own program first, then by name. `source` is `path` for a program found on `PATH`, or `configured` for one an `agent.commands.<kind>` value names that is not on `PATH` (`found` false; `path` set only for an absolute path; such a row means the program is missing or not executable, since one that resolves is listed from `PATH` or not at all, and for an absolute path `name` is the full path). `builtin` is true for the family's own program. `shadowed` lists the paths of same-named files later on `PATH`.
- `effective`: every family (the example shows two), even with `--kind`: the `program` it runs (a base name), its resolved `path` (null when not found), `layer` (`global`, `project`, `worktree` or `default`) and `found`.
- `kind`: the effective `agent.kind`.
- `truncated`: true, present only when more than 200 rows matched and the list was cut; narrow it with `--kind`.

Errors: `unknown_agent_kind` for a `--kind` that is not a family (`details.kind`, `details.known`), and `unknown_workspace` for a `--name` with no config. See [JSON output](README.json.md) for the failure envelope. To act on the list, see [Agent commands](README.config.md#agent-commands).

## Related

- [`workspace agentd`](README.agentd.md) — the long-lived agent daemon
- [`workspace agent-run`](README.agent-run.md) — the low-level form of `agent run`, plus `inject` and `restart`

## JSON output

`agent run --json` prints one document with the agent's reply instead of the text (which goes to stderr): `{"schema_version":1,"ok":true,"workspace":"api","work_item_ref":"wi_12","dispatch_id":"agent-run-ab12cd34","dry_run":false,"reply":{"ok":true,"work_item_ref":"wi_12"}}`. `reply` is the agent's reply as is; the exit code is 0 whatever `reply.ok` says. With `--dry-run` there is `message` and no `reply`. A missing daemon is the failure envelope with `code` `no_daemon`.
