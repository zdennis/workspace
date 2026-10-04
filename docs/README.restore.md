# workspace restore

Bring back the coding-agent panes a reboot or a tmux restart took: recreate them and resume their sessions.

## Usage

```sh
workspace restore [WORKSPACE...] [--dry-run] [--json]
```

With no workspace named, restore acts on every active workspace (the ones `workspace list` shows).

## Details

Every `SessionStart` and `SessionEnd` of a Claude Code session in a workspace pane is written to the session ledger (see [`session-event`](README.session-event.md)), with the pane's slot (`session:window.pane`), its pane id, the tmux server's process id, its session id, its directory and the layout of its window. `restore` reads the ledger and, for each workspace:

1. Launches the workspace if its tmux session is not running, the way it was last launched (a headless one stays headless).
2. Recreates each recorded agent pane that is gone. It does not matter how the pane was made: a pane you split by hand comes back too.
3. Types `cd <directory> && claude --resume <session id>` into the pane.
4. Moves the pane's [binding](README.binding.md) to the new pane, so the resumed agent is told what it was working on.

A session that was already running gets its agent daemon started if it has none, as `launch` does, so the resumed sessions show up in `workspace sessions`.

Run `workspace restore --dry-run` first. It prints what would happen and changes nothing.

### What restore leaves alone

- A pane the workspace's config gives a command, in a session restore has just launched. The config's own command runs there; the standard template's `claude --continue` picks up the most recent conversation in that directory. A config pane with no command (a plain shell) is not left alone: a session recorded there is resumed in it.
- A pane that already runs a coding agent. Running `restore` twice does not type twice.
- A pane running another program (an editor, a server). It is reported as not matched (`pane_busy`), and nothing is typed.
- A session whose transcript file is gone (`transcript_missing`). Claude Code no longer has the conversation, so no pane is made for it.
- A session you ended yourself. A `SessionEnd` with any reason other than `other` (`prompt_input_exit`, `logout`, `clear`) means the session is over. `other` is what a closed terminal, a killed tmux server and a shutdown record, so those sessions are restored.

### Which session belongs to which pane

The ledger is read from start to end and never rewritten. For each slot, the latest `SessionStart` wins, so `/clear` or a new session in the same pane replaces the earlier one. A session counts once, in the slot it started in last: when a neighbouring pane closes, tmux renumbers the panes after it, and the next entry for the session (a resume or a compaction) records its new slot. A `SessionEnd` closes the session it names, whichever slot it is in by then.

### Which pane is the session's now

In a session that was already running, the answer depends on whether tmux has restarted since the entry was written, which the recorded server process id tells:

- Same tmux server: the recorded pane id is the pane, wherever its index is now. Closing a neighbouring pane renumbers the panes after it without any hook firing, so the recorded slot can be out of date; the pane id is not. If that pane runs an agent, nothing is done. If it sits at a shell prompt, the session is resumed in it. If the pane is gone, a new one is made, and the pane now at the old index is never used.
- Another tmux server: pane ids started over, so the slot is matched by its index. An agent already running there (the config's own `claude` pane, usually) is left alone and gets the slot's binding.
- No server recorded: entries written before `restore` shipped carry no server id and no layout. They are matched by index, with one guard. If an agent runs in the pane at that index, or in a pane that has the recorded pane id, restore can't tell whether it is this session, so it types nothing, moves no binding and reports the slot as not matched (`pane_ambiguous`). The next `SessionStart` of that agent writes a full entry and settles it.

### Where a recreated pane goes

Ledger entries written since this command shipped carry the window's layout. When the layout has more panes than the window does now, restore splits the window until the counts match, applies the layout, and resumes each session in the pane at its recorded index (`placement: exact`). Panes that held no agent come back as empty shells, so the indexes line up.

Older entries have no layout. Their panes are added after the window's last pane (`placement: appended`), and the row's `restored_slot` says where each went.

A new pane is made by splitting the window's last pane. When tmux has no space for a new pane there, restore applies the `tiled` layout to the window once and splits again, with a warning; if that fails too, the slot is a `failed` row (`split_failed`).

### Bindings

A binding follows its slot: it moves from the recorded pane id to the pane the session is resumed in, and to an agent the config started at the same slot after a tmux restart. All moves are written at once. Pane ids start over when tmux restarts, so a new pane can have the id another workspace's bound pane had; that binding is not dropped. It is kept in `bindings.json` under `slot:<its slot>` until a restore of its own workspace moves it to its new pane.

### Flags

A resumed session is started with `--dangerously-skip-permissions` when the workspace config's own `claude` pane uses it, because Claude Code does not bring back the permission mode of a session that ran with it. No other flag is carried over. `--continue` is never used: with two agents in one directory it could attach both panes to one conversation.

### Limits

- A slot in a window the session no longer has is reported as not matched (`no_window`); restore does not create windows.
- The dry run of a workspace whose session is not running assumes its windows and panes are numbered from 0. With `base-index` or `pane-base-index` set to 1 in tmux, that preview can report `no_window` or the wrong pane. The real run reads the live indexes and pairs the config's panes with them by order, so it is not affected.
- A pane closed long ago without a recorded end (or with reason `other`) is still in the ledger and is recreated until another session uses its slot. Check the dry run.
- A session whose directory is gone (a removed worktree) is not matched (`cwd_missing`).
- If Claude Code no longer has the conversation, `claude --resume` prints `No conversation found with session ID` in the pane and exits; the row still says `restored`, because the command was typed.
- Claude Code may ask a question before a resumed session is usable (the folder trust prompt, or "resume from summary" for a long idle session). Answer it in the pane.
- In a session restore has just launched, the config's `claude --continue` may pick up the same conversation a hand-split pane had. Check `--dry-run` when two agents shared a directory.
- Only Claude Code sessions are recorded in the ledger.

## Example

```sh
$ workspace restore --dry-run
api: would launch - The tmux session is not running; restore launches it first.
  api:0.1: skipped (config pane) - The workspace's config starts this pane.
  api:0.4: would restore - Would resume session 6f1c2a9e-0d5b-4e0e-9a55-2f4d3c1b7a10 in a new pane at this slot.
  api:1.0: unmatched (no window) - Window 1 is not in the session.
1 recorded pane could not be matched.

$ workspace restore
api: launched
  api:0.1: skipped (config pane) - The workspace's config starts this pane.
  api:0.4: restored - Resumed session 6f1c2a9e-0d5b-4e0e-9a55-2f4d3c1b7a10 in a new pane at this slot. Its binding moved with it.
  api:1.0: unmatched (no window) - Window 1 is not in the session.
1 recorded pane could not be matched.
```

## JSON output

`--json` prints one action document (see [README.json.md](README.json.md#actions)); the text goes to stderr.

```json
{"schema_version":1,"ok":true,"action":"restore","status":"dry_run","dry_run":true,
 "unmatched":[{"workspace":"api","slot":"api:1.0","reason":"no_window"}],
 "results":[
  {"workspace":"api","kind":"workspace","outcome":"would_launch","reason":null,
   "message":"The tmux session is not running; restore launches it first.","slot":null,"session_id":null,
   "cwd":null,"pane":null,"restored_slot":null,"placement":null,"rebound":false},
  {"workspace":"api","kind":"pane","outcome":"would_restore","reason":null,
   "message":"Would resume session 6f1c2a9e-0d5b-4e0e-9a55-2f4d3c1b7a10 in a new pane at this slot.",
   "slot":"api:0.4","session_id":"6f1c2a9e-0d5b-4e0e-9a55-2f4d3c1b7a10","cwd":"/code/api",
   "pane":null,"restored_slot":"api:0.4","placement":"exact","rebound":false},
  {"workspace":"api","kind":"pane","outcome":"unmatched","reason":"no_window",
   "message":"Window 1 is not in the session.","slot":"api:1.0",
   "session_id":"0b0e7c52-8a0f-4b7e-8a3b-5d1f0c9e2a44","cwd":"/code/api",
   "pane":null,"restored_slot":null,"placement":null,"rebound":false}],
 "warnings":[],"summary":{"would_launch":1,"would_restore":1,"unmatched":1}}
```

`warnings` is a list of strings (a window that was tiled, a layout that could not be applied, bindings that could not be moved, an agent daemon that did not start, an unreadable process table, a command that may not have arrived).

Every row has the same keys. `kind` is `workspace` for a launch row (its `slot` is null) and `pane` for a recorded slot.

| Key | Meaning |
|---|---|
| `slot` | The slot the ledger recorded, `session:window.pane` |
| `session_id`, `cwd` | The session and the directory it is resumed from |
| `pane` | The tmux pane id the row is about; always null in a dry run |
| `restored_slot` | Where the session is resumed; null when nothing is resumed. It differs from `slot` when `placement` is `appended`, and when it is `existing` for a pane whose index changed since the entry was written |
| `placement` | `existing` (the session's own pane, or the pane at its slot, at a shell prompt), `exact` (a new pane at the recorded index), `appended` (a new pane after the last one), or null when nothing is resumed |
| `rebound` | Whether a pane binding was moved to `pane` |

| `outcome` | `reason` | Meaning |
|---|---|---|
| `restored` | | The resume command was typed into the pane |
| `would_restore`, `would_launch` | | Dry run only |
| `launched` | | The workspace's session was started |
| `skipped` | `config_pane`, `agent_running`, `ended` | Nothing to do; see "What restore leaves alone" |
| `unmatched` | `no_window`, `pane_busy`, `pane_unknown`, `pane_ambiguous`, `no_session_id`, `cwd_missing`, `transcript_missing`, `not_launched`, `no_config` | The recorded pane could not be matched to a pane restore can use. `pane_unknown`: the process table could not be read. `pane_ambiguous`: an agent runs where an entry with no server id points. `no_session_id`: the ledger has no valid session id. `not_launched`: the workspace's session could not be launched (see its workspace row). `no_config` (dry run, workspace row): the session is not running and the workspace has no tmuxinator config |
| `failed` | `launch_failed`, `no_config`, `split_failed`, `pane_not_found`, `not_delivered` | The workspace could not be launched, tmux could not make the pane, or the command did not reach it |

`unmatched` at the top level lists the unmatched rows again as `{workspace, slot, reason}`, in a dry run and in a real one. `dry_run` says which this was.

`status` is `dry_run` for a dry run. Otherwise it is `ok` (exit 0) when no row failed, `partial` (exit 3) when some did and `failed` (exit 1) when all did. `unmatched` and `skipped` rows are not failures. Without `--json` the exit status is 1 when any row failed and 0 otherwise. An unknown workspace name is the failure envelope with code `unknown_workspace`; so is running with no workspace named and none active.

The `restore` feature in [`capabilities --json`](README.capabilities.md) is 1 when this command exists.
