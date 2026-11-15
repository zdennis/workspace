# Architecture reference

Per-file detail for `lib/`, `spec/support/` and `script/`, split by subsystem. `.claude/CLAUDE.md` keeps a one-line index per file; these files are not loaded automatically, so read the one for the subsystem you are changing. Put new per-file detail here, not in `CLAUDE.md`.

- [Workflow](workflow.md): Workflow definitions, the run store, the engine and its phase classes, review rounds, sweeps, and status readers.
- [Agent daemon](agentd.md): The per-workspace agent daemon: its socket and router, the recovery desk, restart and prompt-queue desks, handoff and pipeline traffic.
- [Templates](template.md): Tmuxinator template sets, rendering, status, apply, adopt and the backup batches behind them.
- [CLI](cli.md): CLI dispatch, the verb-family parsers under `lib/workspace/cli/`, the `build_cli` composition root and the CLI spec tooling.
- [Locks, plan, spine, inbox](locks-plan-spine-inbox.md): Locks and dev sessions, plan and spine files and commands, the inbox, asks, tasks and alerts.
- [Panes and session monitor](panes.md): Tmux panes, the session monitor and its pane_* helpers, typing safety and screen reading.
- [Other](other.md): Everything else: config, git, library, skills, rename, ticket and pull-request commands, the core layer, and spec tooling.
