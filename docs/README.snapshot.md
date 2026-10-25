# workspace snapshot

Print everything a UI polls for in one JSON document: each project's workspaces with their running state, git facts, agent panes, open questions and pipeline entries, plus the repo-wide locks and the dev environment.

## Usage

```sh
workspace snapshot --json [--name WORKSPACE]... [--pr]
```

| Option | Description |
|---|---|
| `--json` | Required. `snapshot` has no text output; without it the command is a usage error |
| `--name WORKSPACE` | Only this workspace; repeat for more. Each one's project is included with just the named members, plus the project's locks and dev environment. An unknown name is an `unknown_workspace` error |
| `--pr` | Also read each readable branch's pull request with `gh pr view` (adds `git.pr`; one `gh` call per workspace, in parallel, each limited to 10 seconds) |

## Reads only

`snapshot` writes nothing. It reads the tmux session list, `.git` files, state and ask files, the lock store, each running workspace's agent daemon and git. A source that can't answer is reported as unavailable, never as clean or empty:

- tmux not answering makes `running` null on every member, with a `tmux_unavailable` warning.
- A daemon that is down, slow or unreadable makes that member's `panes` null (not `[]`), `daemon.up` false, and adds a `daemons_unavailable` row. A workspace that isn't running has no daemon to ask: its `panes` is null and `daemon.up` false, with no `daemons_unavailable` row.
- git failing or running over its time limit gives `git.available: false`, a `reason` and `unsaved: "unknown"`.
- An unreadable lock store or dev status makes `locks` or `dev` null, with a `<source>_unavailable` warning. An unreadable ask store makes `questions` null.

The daemons are read in parallel, one second each: a daemon serves one connection at a time, so reading them in turn would cost a second per workspace.

## JSON

```json
{"schema_version":1,"ok":true,"generated_at":"2026-10-02T20:30:01.120Z","cursor":"ev:9100811:184233",
 "projects":[{"id":"/src/api/.git","name":"api","group":{"id":"group:billing","name":"Billing"},"members":[
   {"workspace":"api.worktree-fix-login","kind":"worktree","path":"/src/api-fix-login",
    "tmux_session":"api-wt-fix-login","running":true,"headless":false,"iterm_window_id":31337,
    "daemon":{"up":true,"pid":null,"log_path":"/Users/me/.local/state/workspace/api.worktree-fix-login/agent.log"},
    "git":{"available":true,"branch":"fix-login","base":"origin/main","ahead_of_base":2,"changed_files":0,"ahead":2,"upstream":"origin/fix-login",
           "unpushed_commits":0,"unsaved":"no",
           "pr":{"available":true,"found":true,"number":812,"url":"https://github.com/o/api/pull/812","state":"open","draft":false,
                 "review_decision":null,"checks":"failing"}},
    "panes":[{"pane_id":"%19","index":1,"kind":"claude","title":"Claude Code","display_label":"Fix login","state":"waiting",
              "state_since":"2026-10-02T20:00:00Z","stop_reason":null,"waiting_message":"Allow Bash(rm -rf tmp)?","context_pct":71,
              "agents":[],"lock":"edit","lock_state":"held","open_questions":1}],
    "task":{"id":"t1","title":"Fix login"},
    "questions":[{"id":"q_7","question":"Use Postgres 16?","default":"yes","pane":"%19","asked_at":"2026-10-02T19:58:00Z","status":"open"}],
    "pipeline":{"entries":0},
    "spine":{"exists":true,"current":"verify","title":"Verify","state":"disputed","status":"completed","owner":"%6","owner_state":"idle",
             "stages":6,"counts":{"completed":3,"in_progress":0,"not_started":2,"blocked":0,"skipped":0,"unknown":0,"disputed":1,"checking":0,"check_failed":0},
             "signature":"5c0d2e71","partial":false},
    "plan":{"state":"working","status":"active","signature":"1791850994123456789:8841",
            "counts":{"total":10,"done":4,"in_progress":1,"todo":5,"blocked":0,"skipped":0,"left":6},"percent":40,
            "current":{"id":"T9","phase":null,"title":"Wire the poller"},"updated_at":"2026-10-02T19:40:00Z"}}],
   "locks":[{"name":"edit","holder":{"workspace":"api.worktree-fix-login","path":"/src/api-fix-login","pid":4411,"stale":false},"queue":[]}],
   "dev":{"running":true,"ready":true,"holder_workspace":"api"}}],
 "daemons_unavailable":[{"workspace":"api","code":"no_daemon"}],
 "warnings":[]}
```

- `cursor` is `ev:<inode>:<byte offset>` of the event log, read before anything else, so an event written while the snapshot is gathered lies after it. A log that doesn't exist yet is `ev:0:0`; one that can't be read gives a null `cursor` and a `cursor_unavailable` warning.
- `group` on each project is `{"id","name"}` of the [group](README.projects.md#groups) its repository is in, or `null`.
- Members are configured workspaces whose checkout exists. A configured workspace whose checkout is gone gives a `checkout_missing` warning instead of a member; worktrees with no workspace config are not listed (see [`projects show`](README.projects.md)).
- `daemon.pid` is always null for now: the daemon doesn't record it. `daemon.log_path` is where its log is written when started in the background.
- `git` is null only when the project has no usable git repository (no git, a broken checkout, or an unknown one); git failing or timing out for a checkout is `git.available: false`, never null. `git.base` is the base branch `review` compares against, null when it can't be found. `git.ahead_of_base` is the number of commits the branch has that `git.base` lacks (capability `ahead_of_base`); `ahead` counts against the upstream, so a fully pushed branch that is not merged keeps `ahead_of_base` above 0. It is null when `base` is null or the count can't be read, never a default 0, and costs one `rev-list --count` per member. `git.pr` is present only with `--pr`: `{"available":false,"reason":"gh_missing"|"timeout"|"error"|"git_unavailable"}`, `{"available":true,"found":false}`, or the pull request, with `state` lowercased and `checks` one of `failing`, `pending`, `passing` or `none`.
- Panes are as in [`sessions --json`](README.sessions.md), reduced to the fields a UI shows. `lock` is the name of the lock the pane holds or queues for, `lock_state` is `held` or `queued`, and `open_questions` is the pane's open `ask` questions (null when the store can't be read). `task` is the active task, present with `panes`.
- `task` is the task `start` recorded for the workspace: `id`, `title`, `ref`, `branch`, `status` and `outcome`. With a daemon it is the active task as above (`status` is `blocked`, `working`, `done` or `idle`). A stopped or ended workspace has no daemon, so it comes from the task store, read once per run: `status` is `stopped` for an active task, or `archived` with the `outcome` (`merged`, `pushed`, `discarded`, `abandoned`) once `finish` or `kill` ended it; the newest archived task answers when none is active. It is null when no task was recorded or the store can't be read (then with a `task_store_unavailable` warning). Capability `snapshot` 4.
- `pipeline.entries` is the number of in-flight work items.
- `plan` is the member's `IMPLEMENTATION_PLAN.md` as [`plan status --json`](README.plan.md) reports it, without `tasks`: `state`, `status`, `signature`, `counts`, `percent`, `current`, `updated_at`. It is null when the workspace has no plan file. `signature` is the file's `mtime_ns:size`, the value `plan status` reports, and the one value an app compares to learn that a plan changed; it then asks `plan status --name WS --json` for the task list. The state is worked out from the reads the snapshot already made (running state, panes, open questions) and the project's `plan.stall_seconds`, so a plan costs one file read per member (plus the notes-directory lookup, which runs `git` only when `notes.default_dir` uses the branch) and no second look at tmux or the daemon. A file that can't be read gives a block with `state: "empty"`, not a failure. A notes directory that can't be worked out, or any other error reading the plan, makes `plan` null and adds a `plan_unavailable` warning.
- `spine` summarises the member's [`spine/`](README.spine.md) folder, judged by the same rules as `spine show --evaluate`. `{"exists":false}` means there is no folder (unlike `plan`, which is null without a file, so an app can tell "no folder" from "could not look"); null, with a `spine_unavailable` warning, means the notes directory could not be worked out. `current` is the path of the first top-level stage not `completed` or `skipped`, `state` its evaluated state and `status` the status in its file; with no such stage `current`, `title`, `state`, `status`, `owner` and `owner_state` are null. `owner_state` is `working`, `waiting`, `idle`, `gone` or `unknown` (the daemon gave no panes) for a stage whose `owner` is a pane id, else null. `stages` is the number of top-level stages and `counts` how many of them are in each evaluated state. Inferred stages are not included.
- `spine.signature` is 8 hex of the SHA-256 over the revision of `goal.md` and of every stage file, in tree order, so it changes exactly when any of those files does. When it changes, ask `spine show --evaluate`.
- `spine` is worked out from reads the snapshot already made, through the same facts mapping as `spine show --evaluate`: the plan file, the git block (plus one `git config` read for a branch with no upstream, to tell a deleted remote branch, which is `unchecked`, from a branch never pushed), the daemon panes (which give the review agent's state too) and, with `--pr`, the pull request. It runs no `gh` and asks no daemon of its own; a `review` gate costs one local commit count. Without `--pr` the `pr`, `ci` and `merged` gates are `unchecked` and `review` is decided on the agent alone, with no review decision. Unchecked gates never dispute, so the snapshot can show `completed` where `show --evaluate` shows `disputed`; `partial: true` says a declared gate on any stage, sub-stages included, was left unchecked (or the review decision unread) that way, so an app should take the card from `spine show --evaluate`. A completed stage whose check has no passing verdict is `checking` (or `check_failed`) in `state` and `counts`, as in `spine show --evaluate`. Capability `snapshot` 6.
- `locks` is the project's repo-wide lock list; a holder's `workspace` is null when its worktree belongs to no member. A holder or waiter that is a workflow run has `"pid": null` and a `run_id`.
- `daemons_unavailable[].code` is `no_daemon`, `timeout` or `unreadable_reply` (any other failure reading or stamping the reply). These are row codes, not error envelope codes.
- There is no per-target `actions` map; the command doesn't say what each workspace may do.
- `warnings` entries are `{"code","message"}` (and `workspace` for `checkout_missing`, `questions_unavailable`, `plan_unavailable` and `spine_unavailable`).

A failure is the error envelope (see [`--json` output](README.json.md)) with exit status 1.
