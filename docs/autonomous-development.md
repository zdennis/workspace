# Autonomous feature development with workspace

## Verdict

`workspace` handles the middle of an autonomous run well: each agent gets its own worktree and tmux pane, agents share edits and one dev server safely through locks, and `sessions` shows who is working. Starting work still needs an iTerm2 desktop and can stop at an interactive prompt. Finishing work is better than it was: `workspace finish` checks a worktree is clean and pushed (optionally opening a PR) before cleanup, and `kill`/`prune` now refuse to discard unsaved work — but merging a PR is still entirely up to the agent. Stall detection has improved: `sessions` now shows a `waiting` state (Claude Code only) when a pane asks for permission or input, and `alerts.notify` can run a command when a pane waits or stays idle too long. The remaining gap is that an agent that finished and an agent that hung both still show `idle` with no distinction, and non-Claude-Code agents never leave `working`/`idle`.

## Top recommendations

Ordered by value. Effort: S (a day or less), M (a few days), L (a week or more).

1. **Detect and announce "needs a human"**: add a `waiting` session state from the agent's notification hook, plus a notify command hook when a pane waits or goes idle too long. (M) Done: see the [Fixed] waiting-state and alerts items in the gap analysis.
2. **Make `start` non-interactive**: add `--base`, `--yes` and `--json`, and send `--prompt` only after the agent is ready. (S)
3. **Add a stage timeout and reliable completion to pipelines**: a per-stage deadline that reports failure, the sentinel instruction for stage 1, and detection that still works once scrollback is full. (M) Done: see the [Fixed] items under "Coordinating agents".
4. **Add a `finish` command**: check the worktree is clean and pushed, open a PR with `gh`, then remove the worktree; make `kill` and `prune` refuse unpushed or dirty work. (M) Done: see the [Fixed] cleanup items under "Finishing work".
5. **Add a way to request and record human input**: `workspace ask` writes a question with the default taken, shows it in `sessions`, and notifies. (M)
6. **Pull the task in from its source**: `start PROJ-123` and GitHub issue URLs should fetch the ticket text and acceptance criteria into the initial prompt. (M)
7. **Add a reliable "send to agent" command** that submits multi-line text and reports whether it landed. (S)
8. **Record agent activity in one log**: dispatches, stage completions, lock waits and failures, with session history that survives a daemon restart. (M)
9. **Offer a headless launch**: plain tmux without iTerm2 control mode, for remote machines and CI. (L)
10. **Support more than one dev environment per repo**: per-worktree ports and databases, or several named dev services. (L)

## A worked example: from ticket to merged change

We follow one ticket from intake to cleanup and mark where `workspace` helps and where it has no support.

```text
PROJ-482  Export invoices as CSV
As an account admin, I want to download my invoices as CSV,
so that I can reconcile them in my spreadsheet.

Acceptance criteria
- An "Export CSV" button on /invoices downloads all invoices in the current filter.
- Columns: number, date, customer, total, status.
- Exports over 10,000 rows run in the background and email a link.
```

A goal ("Admins can export invoices by Friday") or a bare user story works the same way. The only difference is how much the planning step must fill in.

| Step | What happens | Commands | Support today |
|---|---|---|---|
| 1. Intake | Read the ticket text and criteria | none | **None.** `start` uses the key only as a branch name (`lib/workspace/commands/start.rb:110`). The orchestrator reads JIRA itself. |
| 2. Plan | Orchestrator turns criteria into tasks and a plan file | none | **None.** No plan or question file convention. Human approval happens outside `workspace`. |
| 3. Worktrees | One worktree per independent task | `workspace start PROJ-482 --prompt "…"` | **Partial.** Works from an iTerm2 desktop. Stops to ask for a base branch when you are not on the default branch (`lib/workspace/git.rb:215-238`). |
| 4. Agents work | Agent in each pane edits, tests, commits | `workspace sessions <proj> --watch`, `workspace capture <proj> --pane "Claude Code"` | **Good.** Working/idle per pane, sub-agents, lock state. |
| 5. Shared resources | One agent edits at a time; one dev server | `workspace lock acquire edit --wait`, `workspace dev up --wait` | **Good**, within one dev environment per repo. |
| 6. Review | Reviewer agents read the diff and run tests | pipeline stage, or orchestrator sub-agents | **Partial.** Pipelines can chain implementer → reviewer, with no timeout. |
| 7. PR and merge | Push, open PR, merge | `git`, `gh pr create` (via `workspace finish --pr`) | **Partial.** `finish` can open (or reuse) a PR before cleanup; nothing merges it. |
| 8. Acceptance | Person checks the criteria against the running app | `workspace dev up` | **None** beyond the dev environment. No record of sign-off. |
| 9. Cleanup | Remove worktree, config, session | `workspace finish`, `workspace kill <proj> --force`, `workspace prune` | **Good.** `finish` requires the branch clean and pushed before removing it; `kill`/`prune` refuse dirty or unpushed worktrees unless `--force`. |

## Where a person belongs in the loop

A person should decide scope, outward-facing actions, and acceptance; agents should decide everything else and log what they assumed. The author's working pattern (from the locks project handoff) is: never block on the user, write each question with the default taken to a questions file, and keep going. `workspace` has no mechanism for any of these hand-offs today, so every row below relies on files and conventions outside the tool.

| Point | Their task | What they see | Trigger | If they don't respond | Mechanism in workspace |
|---|---|---|---|---|---|
| Plan from the ticket | Confirm scope and how each criterion is read | Plan file with open questions | Plan written | Proceed with the stated defaults; questions stay logged | None |
| Contested design decision | Pick between options | Question, options, the default taken, `file:line` | A reviewer disagrees, or the spec is silent | Reviewer agent rules; proceed with its ruling; logged | None |
| Push, merge, PR, deleting branches | Approve outward or destructive actions | Test and lint results, diff summary, target branch | Work ready to leave the machine | Block, unless a written policy pre-approves it (for example "push when tests pass and it is a fast-forward"; never force-push; never delete branches) | `kill` confirms and refuses dirty/unpushed work unless `--force`; `finish` refuses unconditionally until pushed (no override) — but nothing merges a PR or deletes branches |
| Lock or dev conflict needing a person | Stop a process group this user cannot signal | `lock clear devenv` output naming the owner and pgid | `lock clear devenv` exits 1 with "Kept devenv lock" | The lock stays held and waiters stay queued: the run blocks | Message only (`docs/README.lock.md:164`); no alert |
| Agent waiting on input | Answer the question or permission prompt | The pane | Agent asks | The pane shows `waiting` in `sessions` | `alerts.notify` runs, if set (Claude Code only; other agents still sit `idle`) |
| Review sign-off | Accept or send back | Reviewer verdicts (PASS / CHANGES NEEDED) | Reviews complete | Merge under the written policy if all pass; otherwise fix and re-review | None |
| Final acceptance | Check each criterion against the running app | Dev environment, PR, criteria checklist | PR ready | PR stays open; nothing merges on its own | None |

The stock worktree template starts Claude Code with permission prompts turned off (`lib/templates/workspace.project-worktree-template.yml:23`). That keeps agents moving, but it also removes the one built-in gate before destructive commands. The push/merge row above then depends entirely on the agent's written instructions.

## Playbooks

Each playbook says when to use it, the commands, and what still needs a person watching. Reference material lives in the per-command docs (`docs/README.<command>.md`) and the locks walkthrough, [docs/GUIDE.locks-and-dev.md](GUIDE.locks-and-dev.md).

### 1. One agent per worktree, in parallel

Use this when tasks are independent: different files, different branches, separate PRs.

```sh
cd ~/src/myapp
workspace init                                    # once: templates and agent hooks
workspace start PROJ-482-export --prompt "Implement PROJ-482. Criteria: … Commit as you go; push the branch when tests pass."
workspace start PROJ-483-filters --prompt "…"
workspace list --json                             # what is running
workspace sessions myapp-PROJ-482-export --watch  # one worktree's agents
```

`start` creates `.worktrees/<branch>`, installs agent hooks there, launches the tmuxinator session in iTerm2, and types the prompt into the Claude pane (`lib/workspace/commands/start.rb:83-99`). `launch` also starts a session-monitor daemon per project (`lib/workspace/commands/launch.rb:151-162`).

What needs babysitting:

- `start` asks for a base branch when you are not on the default branch, and asks you to choose when several remote branches match (`lib/workspace/git.rb:198-238`). A script calling it hangs.
- The prompt goes in after a fixed `sleep 5` with no check that the agent is ready (`lib/workspace/commands/launch.rb:227-246`). A slow start loses the prompt; you only get a warning on stderr.
- Each worktree is its own project with its own daemon, so `sessions` shows one worktree at a time (`lib/workspace/commands/sessions.rb:88-103`).
- When the agent finishes, nothing opens the PR or cleans up. You run `workspace kill <proj>` after checking the branch was pushed.

### 2. Orchestrator with sub-agents and handoffs

Use this for a long feature with many small steps, where one session holds the plan and delegates. This is how the author ran the locks project.

The pattern, independent of any feature:

- **The main session only orchestrates.** It holds the plan, launches sub-agents with a model chosen per task, relays results and records decisions. Sub-agents implement, review and verify.
- **Every sub-agent prompt is self-contained**: where to work, which files it owns and which it must not touch, the goal with `file:line`, test rules, verify commands, commit rules, and a terse report format.
- **Parallel only on disjoint files.** Concurrent committers share one git index, so they stage by explicit path and retry on `index.lock`.
- **A cycle per change**: implement, adversarial "skeptic" agents that write failing specs, fixers, a verifier, five persona reviewers, review fixes, merge, bookkeeping.
- **A handoff file is the memory.** After every commit the orchestrator updates `HANDOFF.md` with state, decisions and next steps, so a fresh session resumes from it alone.
- **Context check at every boundary.** An external `agent-context check` measures the pane's context use; over the threshold, it has the agent finish the handoff and restart itself with the "Start here" prompt.
- **Autonomous mode.** Never wait on the user. Questions go to a questions file with the default taken; a written policy says when pushing is allowed.

Where `workspace` fits: it provides the worktree and pane (`start`), the context check reaches the pane through `workspace agent-run`, and `sessions` shows the sub-agents under the orchestrator's pane. Everything else is convention.

What needs babysitting:

- Context handoff is an external tool. `workspace` has no notion of an agent's context use or of restarting an agent with a handoff prompt.
- Sub-agents share the orchestrator's worktree, so the `edit` lock does not separate them. A committer once swept another agent's staged files into its commit.
- Background sub-agent reports arrive through the agent's own tooling, not `workspace`. There is no record of which sub-agent changed what.
- The questions file, the handoff file and the push policy are all hand-maintained.

### 3. Pipeline stages driven by the sentinel

Use this when each work item passes through fixed roles, such as researcher → implementer → reviewer, and an external coordinator dispatches work.

```yaml
# ~/.config/workspace/projects/myapp.yml
pipeline:
  panes:
    - role: researcher
      timeout: 30m
    - role: implementer
    - role: reviewer
```

```sh
workspace agent myapp                                    # the daemon (launch starts one too)
workspace pipeline start myapp --work-item PROJ-482 --body "Research PROJ-482: …"
workspace pipeline status myapp --json
workspace pipeline advance myapp --work-item PROJ-482    # force a stage complete
```

The daemon types the body into stage 1's pane, followed by the line to print when done: `WORKSPACE_DONE:<token> <one-line summary>`, with a random token new to each stage (`lib/workspace/commands/agent.rb:336-370`, `lib/workspace/sentinel_poller.rb:32-34`). It then polls the pane every 2s for a line starting with that token (`lib/workspace/sentinel_poller.rb:116-130`), saves the pane's output as a handoff file, and tells the next stage its role, the file, and its own token (`lib/workspace/commands/agent.rb:502-505`). A stage with `timeout:` that is still running at its deadline fails the work item (`lib/workspace/commands/agent.rb:420-433`). State, including each stage's token and deadline, survives a daemon restart (`lib/workspace/pipeline_state.rb:110-116`).

What needs babysitting:

- Stage N runs in pane N of window 0 (`lib/workspace/pipeline_config.rb:27-29`). The stock worktree template puts a banner in pane 0 and Claude in pane 1 (`lib/templates/workspace.project-worktree-template.yml:17-25`), so pipelines need a custom layout.
- A stage without `timeout:` still waits forever for its sentinel.

### 4. Sharing one dev environment through locks

Use this when parallel worktrees need the same database, ports or server, and only one can run at a time.

```sh
# once, in the main checkout
workspace config set dev.up "bin/dev"
workspace config set dev.ready "port:3000"

# in each agent's instructions
workspace lock instructions            # prints the edit-lock block to paste into the prompt

# from a worktree
workspace dev up --wait                 # queue for the dev env, start it when it's our turn
workspace dev status --json
workspace dev down
```

Locks are per repository, so every worktree of `myapp` shares one queue (`lib/workspace/lock_store.rb:9-11`). The `edit` lock is enforced for Claude Code's Edit/Write tools through hooks (`lib/workspace/lock_enforcer.rb:15-17`). A holder that stops mid-task loses its lock to the next waiter after `locks.idle_grace` (default 300s, `lib/workspace/lock_store.rb:34`). The walkthrough in [docs/GUIDE.locks-and-dev.md](GUIDE.locks-and-dev.md) covers setup, contention and recovery.

What needs babysitting:

- Only one dev environment per repo (`docs/README.dev.md:114`). Two agents that each need a running app take turns.
- Edits made through shell commands (`sed`, `git apply`, code generators) bypass the `edit` lock (`lib/workspace/lock_enforcer.rb:15-16`).
- A dev server started by another OS user cannot be stopped; the lock stays held until that user stops it (`docs/README.lock.md:164`). Waiters wait with no alert.
- Enforcement only exists for agents with hooks, which today means Claude Code (`lib/workspace/agent_provider.rb:113-115`).

### 5. Watching many agents

Use this while any of the above runs.

```sh
workspace sessions myapp --watch         # table: pane, agent, working/idle, sub-agents, locks
workspace sessions myapp --json          # for a script
workspace capture myapp --pane "Claude Code" --lines 200
workspace lock status --json
workspace doctor                         # hooks installed, daemon running
```

`sessions` asks the project's daemon for pane state. A pane is `working` while its output changes, `idle` after 30s without change, and `waiting` from the agent's `Notification` hook until its next hook event (`lib/workspace/session_monitor.rb`). Set `alerts.notify` to be told when a pane waits or stays idle past `alerts.idle_after`.

What needs babysitting:

- `idle` covers finished, waiting for an answer, and hung. You open the pane to tell which.
- Nothing notifies you. `--watch` is a screen someone has to look at.
- Sub-agent rows come from Claude Code hooks only; other agents show just the pane (`lib/workspace/agent_provider.rb:113-115`).
- Session history is in the daemon's memory and disappears with the pane or a restart (`lib/workspace/session_monitor.rb:98-100`).

## Gap analysis

Tags: **[Missing]** is a feature that does not exist. **[Improve]** is a change to an existing feature.

### Starting work: the run needs a person at a desktop to begin

`start` is the only entry point, and it assumes an interactive iTerm2 session.

- **[Missing] Task intake.** A JIRA key or issue URL becomes a branch name and nothing else (`lib/workspace/commands/start.rb:110`, `lib/workspace/git.rb:151-168`). The agent never sees the ticket text or criteria unless someone pastes them into `--prompt`. Fix: fetch the ticket (JIRA API, `gh issue view`) and prepend it to the prompt, or accept `--prompt-file`.
- **[Improve] Interactive branch prompts.** A missing branch or several matching remote branches trigger a numbered menu read from stdin (`lib/workspace/git.rb:198-238`). A scripted `start` hangs. Fix: `--base <branch>`, `--yes`, and an error instead of a prompt when stdin is not a terminal.
- **[Fixed] Blind prompt delivery.** `--prompt` now waits, up to 60 seconds, until an agent process is running in the session and its screen has stopped changing. It then sends the prompt, checks it landed, retries a paste that never showed up, and exits 1 with the reason if the prompt couldn't be sent (`lib/workspace/agent_readiness.rb`, `lib/workspace/commands/launch.rb`). It doesn't use the `SessionStart` hook, so it works for agents without hooks.
- **[Missing] Machine-readable start.** `start`, `launch`, `kill` and `prune` have no `--json` (`lib/workspace/cli.rb:313-339`). An orchestrator must parse prose to learn the project name and worktree path. Fix: `--json` returning project, worktree, branch, session.
- **[Missing] Headless launch.** Templates use iTerm2 control mode (`lib/templates/workspace.project-worktree-template.yml:5`) and `launch` always drives iTerm2 through AppleScript (`lib/workspace/commands/launch.rb:36-77`). Runs cannot happen on a remote box or in CI. Fix: a plain-tmux launch path that skips window management.

### Coordinating agents: dispatch works, completion is fragile

Work reaches a pane reliably; knowing it finished, or failed, does not.

- **[Fixed] Stage timeout.** A stage can set `timeout:` in the pipeline config (`lib/workspace/pipeline_config.rb:40-45`). A stage still running at its deadline fails the work item through the existing failure path, which reports an `error` to the coordinator and prints it on the agent's stderr (`lib/workspace/commands/agent.rb:420-433`). Stages without `timeout:` still wait forever.
- **[Fixed] Missed completions once scrollback is full.** The poller matches the stage's token anywhere in the pane's history instead of counting lines (`lib/workspace/sentinel_poller.rb:116-130`), so a full history no longer hides a new sentinel.
- **[Fixed] Stage 1 is not told the sentinel.** Stage 1's body now ends with the same completion instruction later stages get (`lib/workspace/commands/agent.rb:343-347`).
- **[Fixed] Sentinel after a daemon restart.** Each stage's token and deadline are persisted, and recovery watches for the saved token (`lib/workspace/commands/agent.rb:217-234`), so a sentinel printed while the daemon was down is seen at once. Items saved by an older agent have no token and keep the old behavior.
- **[Fixed] Anything can end a stage.** Each stage dispatch gets a random token, and only `WORKSPACE_DONE:<token>` ends that stage (`lib/workspace/sentinel_poller.rb:52`). `pipeline advance` reads the running stage's token from the state file.
- **[Improve] Fixed pane mapping.** Stage N is pane N of window 0 (`lib/workspace/pipeline_config.rb:27-29`), which does not match the stock template's layout. Fix: an optional `pane:` per stage, or match by pane title the way `run --pane` does.
- **[Improve] Reliable send-to-agent.** `Tmux#deliver` now pastes text as one bracketed paste, reads the pane back to check it landed, presses Enter once the screen settles, and presses it again only if the screen didn't change. `run`, `launch --prompt` and pipeline dispatch act on the outcome (`lib/workspace/tmux.rb`, `lib/workspace/commands/agent.rb`). Still missing: a `workspace send` command, and a guard against repeated sends piling up (open feature request).
- **[Improve] Reports dropped quietly.** Past 500 buffered status reports the oldest are dropped with only a debug log (`lib/workspace/commands/agent.rb:17`). Fix: warn on stderr and report the count once the coordinator is back.

### Sharing resources: safe for one dev server, advisory elsewhere

Locks serialize editing and the dev environment; anything outside those two stays on the honor system.

- **[Improve] Shell edits bypass the edit lock.** Only Edit/Write/MultiEdit/NotebookEdit are checked (`lib/workspace/lock_enforcer.rb:15-17`). An agent running `sed -i` or a generator edits while another holds the lock. Fix: document it in `lock instructions`, and optionally check Bash commands that write into the worktree.
- **[Missing] Per-worktree dev environments.** One `devenv` lock per repo (`docs/README.dev.md:114`) and no port or database allocation. Parallel agents that each need a running app wait in line. Fix: named dev services, or per-worktree `PORT`/`DATABASE_URL` offsets passed to `dev.up`.
- **[Improve] Hooks only for Claude Code.** Codex, OpenCode and Pi have no hook support (`lib/workspace/agent_provider.rb:113-115`), so their edits are never checked and their idle turns never hand a lock on. Fix: add hook tables for agents that offer hooks.
- **[Improve] One lock per agent per repo.** Holding `edit` while waiting for `devenv` exits 5 (`lib/workspace/lock_store.rb:87-89`). An agent that needs both must release and requeue. Fix: document the ordering in `lock instructions`, or allow a declared lock order.

### Observing: state is visible, stalls are not

`sessions` answers "who is working"; it cannot answer "who needs me".

- **[Fixed] A "waiting for a person" state.** Claude Code's `Notification` hook now puts the pane in a `waiting` state, shown in `sessions` with the agent's message, and the next hook event (a prompt, a finished tool, the turn ending) clears it (`lib/workspace/session_monitor.rb`, `lib/workspace/commands/session_event.rb`). Agents without hooks still show only `working`/`idle`.
- **[Fixed] Alerts.** `alerts.notify` runs a command when an agent pane starts waiting or stays idle past `alerts.idle_after`, once per episode, with the details in `WORKSPACE_ALERT_*` environment variables (`lib/workspace/notifier.rb`, `lib/workspace/session_monitor.rb`). A kept lock still sends nothing.
- **[Missing] One view across worktrees.** Each worktree is a project with its own daemon, and `sessions` reads one socket (`lib/workspace/commands/sessions.rb:88-103`). Fix: `sessions --all`, walking every active project.
- **[Fixed] Agent activity log.** The event log now records dispatches, stage completions, timeouts and failures, lock waits and takeovers, and each agent pane's state changes alongside state-file changes; a restarted daemon reads each pane's last state back (`lib/workspace/event_log.rb`, `lib/workspace/session_monitor.rb`). Read it with `workspace event-log show [--project] [--type] [--limit] [--json]`. Compaction drops activity history except each live pane's latest state, and there is no rotation yet.
- **[Improve] `capture` and `doctor` for scripts.** `capture` has no JSON or filtering (`lib/workspace/commands/capture.rb:24-37`). `doctor` checks the daemon for the current project only (`lib/workspace/doctor.rb:138-168`). Fix: `doctor --all` and `capture --since-last`.

### Asking and recording human input: no mechanism at all

Every hand-off in the human-in-the-loop table runs through files and conventions outside `workspace`.

- **[Missing] Question queue.** No command records "question, default taken, where it matters" or shows open questions. The author's questions file is maintained by hand. Fix: `workspace ask "<question>" --default "<choice>"` writing to per-project state, shown in `sessions` and sent through the notify hook.
- **[Missing] Recorded approvals and policy.** No place records "push approved when green" or "never delete branches", and no command checks it. Fix: a per-project policy block (`auto_push`, `auto_merge`) that a `finish` command obeys.

### Finishing work: the agent does it all, and cleanup can lose work

`workspace` now protects unpushed work on cleanup and can open the PR, though nothing merges one.

- **[Fixed] Commit, push, PR, merge.** `workspace finish` (`lib/workspace/commands/finish.rb`) checks the worktree is clean (tracked files only) and fully pushed, optionally opens or reuses a PR with `gh` (`--pr`; skipped with a note if `gh` is missing), then reuses `Commands::Kill` for cleanup. `--json` reports `{schema_version, project}` or `{schema_version, error}`. Still nothing merges a PR — that stays a person's call.
- **[Fixed] `kill` ignored unpushed commits.** It now refuses to remove a worktree with uncommitted changes to tracked files or commits unreachable from any remote (or, with no remote, any other local branch) before doing anything (`lib/workspace/commands/kill.rb`, `Git#unsaved_work`). `--force` skips this check along with the confirmation prompt, same as before.
- **[Fixed] `prune` always forced.** It now runs the same unsaved-work check per candidate; a dirty or unpushed candidate is skipped and reported by name rather than removed, while the rest of the run keeps going (`lib/workspace/commands/prune.rb`). `--force` removes those anyway.
- **[Fixed] Swapped class names.** CLI `stop` now runs `Commands::Stop` and CLI `kill` now runs `Commands::Kill` (`lib/workspace/cli.rb`). Previously the classes were swapped relative to the commands they backed.
- **[Improve] Run results pile up.** `run --wait` results are never cleaned up (`lib/workspace/run_result_store.rb:9`). Fix: delete results older than a day on each write.
- **[Missing] Context handoff.** Long runs depend on an external `agent-context` tool to notice a full context and restart the agent with a handoff prompt. Fix: a `sessions` field for context use, and a `workspace restart-agent --prompt-file` that clears and re-prompts a pane.

### Docs drift


## Open questions

- Should `finish` merge, or stop at opening the PR? We assumed PR only, with merge left to policy.
- Should the notify hook be a shell command in config, or a built-in integration? We assumed a shell command.
- Is headless launch worth its cost if all runs stay on the author's Mac? We ranked it low for that reason.
