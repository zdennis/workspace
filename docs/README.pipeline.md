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

## Options

| Option | Description |
|--------|-------------|
| `--work-item REF` | Work item reference, e.g. `WC-42` (required by `start` and `advance`) |
| `--body TEXT` | Message body to send (`start` and `advance`) |
| `--json` | Print `status` as a JSON array instead of a table |

## Details

**Everything that touches a pane goes through the agent that owns it.** `start` and `advance` talk to the agent over its socket rather than to tmux, so a manual nudge cannot get the agent's view of the pipeline out of step with the panes.

**`start`** sends a synthetic command with a `manual-` dispatch id. The agent handles it exactly as it would one from the coordinator: the body is typed into the first stage's pane and the work item starts being tracked. Without `--body` it sends `Begin work on <REF>.`

**`advance`** interrupts the running stage and types the completion sentinel into its pane — the same line a finished stage prints. The agent's watch sees it and advances normally, capturing the handoff and starting the next stage. It does not wait for the stage to actually be done: an advance marks it complete whether it is or not. The body is escaped before it reaches the pane's shell.

**`status`** reads the persisted state file at `~/.local/state/workspace/<project>/pipeline.json`, so it works whether or not the agent is running. It prints one line per in-flight work item with its pane index and phase. Because it reads the file rather than asking the agent, a poll landing mid-transition can show a stage the agent has just moved past.

**`--json`** prints the in-flight entries as a JSON array, including the `dispatch_id` the table leaves out, for scripts that need to correlate their own dispatches. An idle project prints `[]`.

**`reset`** deletes the state file. It refuses while the agent is running, because the agent holds that state in memory and clearing the file under it would only put the two out of step. Stop the agent first.

## Examples

```sh
# What is myapp working on?
workspace pipeline status myapp
# WORK ITEM  PANE  STAGE
# WC-42  pane 1  implementer

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
