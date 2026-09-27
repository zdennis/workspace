# workspace pipeline

Inspect and drive a project's agent pipeline by hand. These are operator tools for watching a pipeline and nudging it when something needs a push — the day-to-day driving is done by work-coordinator through [`workspace agent`](README.agent.md).

## Usage

```sh
workspace pipeline <subcommand> [options]
```

| Subcommand | Description |
|------------|-------------|
| `start <project> --work-item REF` | Send a work item into the project's pipeline |
| `advance <project> --work-item REF` | Mark the running stage complete and move on |
| `status <project>` | Show what the project has in flight |
| `reset <project>` | Clear a stopped project's pipeline state |
| `help` | Print the subcommand and option summary |

## Options

| Option | Description |
|--------|-------------|
| `--work-item REF` | Work item reference, e.g. `WC-42` (required by `start` and `advance`) |
| `--body TEXT` | Message body to send (`start` and `advance`) |
| `--json` | Print `status` as a JSON array instead of a table |

## Details

**Everything that touches a pane goes through the agent that owns it.** `start` and `advance` talk to the agent over its socket rather than to tmux, so a manual nudge cannot get the agent's view of the pipeline out of step with the panes.

**`start`** sends a synthetic command with a `manual-` dispatch id. The agent handles it exactly as it would one from the coordinator: the body is typed into the first stage's pane and the work item starts being tracked. Without `--body` it sends `Begin work on <REF>.`

**`advance`** interrupts the running stage and types the completion sentinel into its pane — the same line a finished stage prints, including the stage's token, which it reads from the state file. The agent's watch sees it and advances normally, capturing the handoff and starting the next stage. It does not wait for the stage to actually be done: an advance marks it complete whether it is or not. `--body` becomes the one-line summary after the sentinel, and defaults to `manual advance`; it is escaped before it reaches the pane's shell. The request also carries the token as `expected_token`; if the stage has already moved on by the time the agent handles it, the agent leaves the pane alone and replies with a `stale_token` error, and the CLI exits 1 with "The stage moved on before the advance landed; run 'workspace pipeline advance' again" rather than reporting a success that did nothing. Run it again to advance the new stage.

**`status`** reads the persisted state file at `$XDG_STATE_HOME/workspace/<project>/pipeline.json` (`~/.local/state/...` by default), so it works whether or not the agent is running. It prints one line per in-flight work item with its pane index, phase, and a DEADLINE column (the stage's `deadline_at`, or `-` when the stage has no `timeout:` or was started by an older agent). Because it reads the file rather than asking the agent, a poll landing mid-transition can show a stage the agent has just moved past.

**`--json`** prints the in-flight entries as a JSON array, including fields the table leaves out: `dispatch_id`, for scripts that need to correlate their own dispatches; `sentinel_token`, the token the running stage must print; and `deadline_at`, when the stage times out (ISO 8601 UTC, or `null` when its stage has no `timeout:`). Entries written by an older agent have neither of the last two. An idle project prints `[]`.

**`reset`** deletes the state file. It refuses while the agent is running, because the agent holds that state in memory and clearing the file under it would only put the two out of step. Stop the agent first.

## Limits

**A sentinel buried under a lot of output is seen late.** Most polls read only the last 500 lines of the pane; about once a minute, and once more before a stage times out, the agent reads the whole history. A sentinel followed by more than 500 lines of output within one poll is still found, up to a minute later.

## Examples

```sh
# What is myapp working on?
workspace pipeline status myapp
# WORK ITEM  PANE  STAGE  DEADLINE
# WC-42  pane 1  implementer  2026-09-27T12:30:00.000Z

# Same, for a script
workspace pipeline status myapp --json

# Push a work item through by hand
workspace pipeline start myapp --work-item WC-42 --body "/build add OAuth support"
workspace pipeline advance myapp --work-item WC-42

# Clear leftover state after stopping the agent
workspace pipeline reset myapp
```

## Exit status

Exits 1 when no agent is running for the project, when the agent refuses a `start` or an `advance` (for instance, no active pipeline for that work item), or when `reset` is run against a project whose agent is still up.

An unreadable state file is not an error: `status` warns on stderr and treats it as empty, the same way the agent does.
