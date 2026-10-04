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
 "projects":[{"id":"/src/api/.git","name":"api","members":[
   {"workspace":"api.worktree-fix-login","kind":"worktree","path":"/src/api-fix-login",
    "tmux_session":"api-wt-fix-login","running":true,"headless":false,"iterm_window_id":31337,
    "daemon":{"up":true,"pid":null,"log_path":"/Users/me/.local/state/workspace/api.worktree-fix-login/agent.log"},
    "git":{"available":true,"branch":"fix-login","base":"origin/main","changed_files":0,"ahead":2,"upstream":"origin/fix-login",
           "unpushed_commits":0,"unsaved":"no",
           "pr":{"available":true,"found":true,"number":812,"url":"https://github.com/o/api/pull/812","state":"open","draft":false,
                 "review_decision":null,"checks":"failing"}},
    "panes":[{"pane_id":"%19","index":1,"kind":"claude","title":"Claude Code","display_label":"Fix login","state":"waiting",
              "state_since":"2026-10-02T20:00:00Z","stop_reason":null,"waiting_message":"Allow Bash(rm -rf tmp)?","context_pct":71,
              "agents":[],"lock":"edit","lock_state":"held","open_questions":1}],
    "task":{"id":"t1","title":"Fix login"},
    "questions":[{"id":"q_7","question":"Use Postgres 16?","default":"yes","pane":"%19","asked_at":"2026-10-02T19:58:00Z","status":"open"}],
    "pipeline":{"entries":0}}],
   "locks":[{"name":"edit","holder":{"workspace":"api.worktree-fix-login","path":"/src/api-fix-login","pid":4411,"stale":false},"queue":[]}],
   "dev":{"running":true,"ready":true,"holder_workspace":"api"}}],
 "daemons_unavailable":[{"workspace":"api","code":"no_daemon"}],
 "warnings":[]}
```

- `cursor` is `ev:<inode>:<byte offset>` of the event log, read before anything else, so an event written while the snapshot is gathered lies after it. A log that doesn't exist yet is `ev:0:0`; one that can't be read gives a null `cursor` and a `cursor_unavailable` warning.
- Members are configured workspaces whose checkout exists. A configured workspace whose checkout is gone gives a `checkout_missing` warning instead of a member; worktrees with no workspace config are not listed (see [`projects show`](README.projects.md)).
- `daemon.pid` is always null for now: the daemon doesn't record it. `daemon.log_path` is where its log is written when started in the background.
- `git` is null only when the project has no usable git repository (no git, a broken checkout, or an unknown one); git failing or timing out for a checkout is `git.available: false`, never null. `git.base` is the base branch `review` compares against, null when it can't be found. `git.pr` is present only with `--pr`: `{"available":false,"reason":"gh_missing"|"timeout"|"error"|"git_unavailable"}`, `{"available":true,"found":false}`, or the pull request, with `state` lowercased and `checks` one of `failing`, `pending`, `passing` or `none`.
- Panes are as in [`sessions --json`](README.sessions.md), reduced to the fields a UI shows. `lock` is the name of the lock the pane holds or queues for, `lock_state` is `held` or `queued`, and `open_questions` is the pane's open `ask` questions (null when the store can't be read). `task` is the active task, present with `panes`.
- `pipeline.entries` is the number of in-flight work items.
- `locks` is the project's repo-wide lock list; a holder's `workspace` is null when its worktree belongs to no member. A holder or waiter that is a workflow run has `"pid": null` and a `run_id`.
- `daemons_unavailable[].code` is `no_daemon`, `timeout` or `unreadable_reply` (any other failure reading or stamping the reply). These are row codes, not error envelope codes.
- There is no per-target `actions` map; the command doesn't say what each workspace may do.
- `warnings` entries are `{"code","message"}` (and `workspace` for `checkout_missing` and `questions_unavailable`).

A failure is the error envelope (see [`--json` output](README.json.md)) with exit status 1.
