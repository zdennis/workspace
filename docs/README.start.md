# workspace start

Create a git worktree and launch it as a workspace project.

## Usage

```sh
workspace start [options] <jira-key|jira-url|pr-url|pr-ref|issue-url|branch>
```

## Options

| Option | Description |
|--------|-------------|
| `--prompt PROMPT` | Send an initial prompt to the coding agent once it is ready (up to 60s); exits 1 if it can't be sent. See [`launch`](README.launch.md#details) |
| `--prompt-timeout DURATION` | How long to wait for the coding agent to be ready for `--prompt` (e.g. `90s`, `2m`, or a plain number of seconds); default 60s |
| `--play NAME[,NAME...]` | Send the agent a line pointing at a [library](README.library.md) play, then any `--prompt` text. Repeat the flag or separate names with commas to send several. See [Plays](#plays) |
| `--pack NAME` | Also send the agent a library pack's text with the first prompt; repeatable. See [Packs](#packs) |
| `--no-packs` | Send no automatic packs; cannot be combined with `--pack` or `--handoff` |
| `--handoff` / `--no-handoff` | Send, or never send, the `handoff` pack for this run, whatever the `handoff.auto` key says. See [Packs](#packs) |
| `--agent NAME` | Copy a [library](README.library.md) agent into the worktree's `.claude/agents/` (or `library.install.agents_dir`); repeatable. See [Agents and skills](#agents-and-skills) |
| `--skill NAME` | Copy a library skill directory into the worktree's `.claude/skills/` (or `library.install.skills_dir`); repeatable |
| `--agent-kind KIND` | The coding agent the main agent pane runs: `claude` (the default), `codex`, `opencode` or `pi`; with no flag, `agent.kind`, and the pane runs the command `agent.commands.<kind>` sets (see [Agent commands](README.config.md#agent-commands)). Named `-kind` because `--agent` copies a library agent. See [Agent kind and `--no-launch`](#agent-kind-and---no-launch) |
| `--recipe NAME` | Apply a library recipe: its plays, packs, agents, skills, agent kind and prompt fill in whatever the matching flags did not give. See [Recipes](#recipes) |
| `--no-launch` | Create the worktree, config and task and start nothing. See [Agent kind and `--no-launch`](#agent-kind-and---no-launch) |
| `--plan[=TITLE]` | Run [`plan init`](README.plan.md) for the new workspace and send the agent the `implementation-plan` play so it drafts the plan's tasks. `TITLE` is the plan's title (default: the task's title). Not with `--play`. See [Plan](#plan) |
| `--spine[=NAME]` / `--no-spine` | Run, or never run, [`spine init`](README.spine.md#spine-init) for the new workspace, whatever `spine.auto` says. `NAME` is the template (default: `spine.template`). See [Spine](#spine) |
| `--base REF` | Branch/ref a new branch is created from, instead of prompting |
| `--yes` | Accept every default instead of prompting (e.g. the default base branch) |
| `--title TITLE` | A human title for the workspace's task; it is the first `display_label` of its panes in [`sessions --json`](README.sessions.md). See [Tasks](#tasks) |
| `--title-from-ticket` | Fill the task title from the ticket (`gh` for an issue or pull request, `jira` for a JIRA key) when `--title` is not given. A ticket that cannot be read is a warning, not an error. See [Ticket titles and `--slug`](#ticket-titles-and---slug) |
| `--slug` | Add the title's words to the branch of a JIRA or issue ref: `PROJ-123-fix-the-login-bug`, `issue-42-fix-the-login-bug`. Takes the words from `--title`, else from the ticket (it implies `--title-from-ticket`) |
| `--headless` / `--no-headless` | Start the session in the background with plain tmux instead of iTerm2; the default follows [`launch`](README.launch.md#headless) |
| `--json` | Emit the JSON schema below instead of plain text; never prompts. Only the JSON document goes to stdout — progress and warnings go to stderr or the `warnings` field (see [`--json` output](#--json-output)) |

## Accepted Inputs

| Input | Example | Behavior |
|-------|---------|----------|
| JIRA issue key | `PROJ-123` | Used as branch name |
| JIRA URL | `https://mycompany.atlassian.net/browse/PROJ-123` | Extracts issue key |
| GitHub PR URL | `https://github.com/owner/repo/pull/471` | Checks the PR out with `gh pr checkout --worktree` as branch `pr-471` in `.worktrees/pr-471`; works for PRs from forks, and the agent then starts in the fork's code |
| GitHub PR ref | `#471` or `owner/repo#471` | Same as the PR URL; `#471` means a PR of the current repo. Quote `#n` (`'#471'`), or your shell treats it as a comment. Run it from a checkout of the repo the PR belongs to |
| GitHub issue URL | `https://github.com/owner/repo/issues/123` | Creates branch `issue-123` |
| Branch name | `user/PROJ-123` | Used as-is |

## Details

A pull request is always checked out by `gh pr checkout <n> --worktree <path> --branch pr-<n>`, never by its head branch name, so a PR from a fork can't be mistaken for a branch of your repo. A fork's pull request is checked out like any other: the workspace's agent starts in the fork's code and loads its `CLAUDE.md` and `.claude/settings.json` hooks, so start one only for code you trust (`workflow start` refuses it, see [README.workflow.md](README.workflow.md#starting-from-a-ticket-or-a-prompt)). When the ref names the repository (`owner/repo#n` or a URL), the branch's config records it as `branch.pr-<n>.workspace-pr`, which `workflow start` compares before it reuses the branch. The local branch is `pr-<n>`; `--base` is ignored (with a note). Re-running `start` for the same PR reuses its worktree. Needs a `gh` recent enough to have `--worktree` (the error says so if not).

A PR checkout keeps the upstream `gh` sets only when git can resolve it: a same-repo PR keeps `origin/<head>`. A fork PR (its branch is not on `origin`), or any upstream git can't resolve, is left with no upstream or push remote; the first `workspace push` or `workspace pr create` pushes to `origin/pr-<n>` and sets it.

Must be run from within a git repository. Creates a worktree in `.worktrees/` under the project root, generates a tmuxinator config, and launches it. When run from inside a linked worktree, `start` resolves the parent repo first — the worktree is created under the parent repo's `.worktrees/` and named after the parent project, so an existing session is reused rather than a nested workspace created (this applies when the worktree belongs to the surrounding repo; a standalone repo nested inside a worktree, and worktrees of a bare clone, keep the cwd repo's own root).

If the branch already exists (locally or remotely), it checks it out. A branch that exists only on `origin` is created locally with `origin/<branch>` as its upstream, so `git pull` and `git push` work in the new worktree without further setup. If not, it prompts you to choose a base branch for creation. A branch `start` creates is marked with `branch.<name>.workspace-created` in the repository's git config; [`kill`](README.kill.md#branches) deletes only branches carrying that mark.

If multiple remote branches match your input, you'll be prompted to select one or create a new branch.

If a worktree for the branch already exists at a non-standard location (created outside of workspace via `git worktree add`), it is automatically adopted — a tmuxinator config and project marker are created, and the worktree is launched without being recreated.

Before launching, `start` installs each detected coding agent's hooks (session monitoring, edit lock enforcement) and — for Claude Code — `statusLine` routing through `workspace statusline` into the worktree's `.claude/settings.json`, so `workspace handoff check` and `sessions --json` can read the agent's context usage from the worktree right away. This is idempotent and backs the settings file up first; an existing statusLine command is preserved into the global `statusline.command` config (see [workspace statusline](README.statusline.md)). Codex's hooks live in its user-level `$CODEX_HOME/hooks.json`, shared by every project; `workspace config set codex.hooks.install false` makes `start` leave that file alone (default `true`). `start` then prints `Note: Codex hooks not installed: codex.hooks.install is false` once (a `warnings` entry in `--json`), `doctor` reports the `hooks-codex` row as turned off by config, and Codex panes read as `hook_mode: "scrape"`. `init`, `doctor --fix` and `workspace hooks uninstall` are not affected by the key.

### Notes directory

`start` fixes the new workspace's notes directory (see [`notes`](README.notes.md)). It works out the path the way `workspace notes dir` does (the project's `notes.default_dir` rule, else the main checkout workspace's notes directory plus the branch, e.g. `/tmp/my-notes/research-dx` when the project's `notes.dir` is `/tmp/my-notes`, with `tmp/workspace-notes` in the main checkout as that directory when it has no `notes.dir`), writes it as `notes.dir` in the worktree's own config file, makes the directory, and, when it is inside the worktree, lists it in the repository's `info/exclude` so `git status` stays clean. The path is fixed at that moment, so changing the project's rule later does not move this worktree's notes.

A `notes.dir` already in the worktree's config is never overwritten; `start` makes the directory that value names. This runs for a reused or adopted worktree too, so it fills in a worktree started before this existed. If the directory can't be made or the config can't be written, `start` carries on and says so on stderr (a `warnings` line under `--json`); it never fails because of notes.

### Non-interactive use (scripts, agents)

`start` never blocks on stdin when stdin isn't a TTY. Whenever it would otherwise
prompt, it instead:

- uses `--base` if given, for the base-branch choice;
- uses `--yes`'s default if given (the default branch, for the base-branch choice;
  "create a new branch" for an ambiguous match);
- otherwise raises a usage error naming `--base`/`--yes` rather than guessing.

`--json` never prompts either, regardless of whether stdin is a TTY — pass `--base`
and/or `--yes` alongside it when the branch might need to be created.

### Packs

`start` also sends the agent the instruction packs that apply, in one send: the `--play` line, then the packs (one `## From pack <name>` heading each), then the `--prompt` text. The automatic packs are `notes` (where working notes go; `start` has already set the notes directory up), unless the project's `notes.instructions` key is `false`. `--pack NAME` adds a pack (repeatable; any library play can be named, see [`instructions`](README.instructions.md)), and `--no-packs` drops the automatic ones for this run; the two together are a usage error. An automatic `spine` pack is sent after `notes` when the workspace's notes directory already has a `spine/` folder (it is looked for after the [spine step](#spine), so a new worktree has one when `--spine` or `spine.auto` made it; a link named `spine` does not count; `--no-packs` drops it; see [`spine`](README.spine.md#telling-agents-the-convention)). Another automatic pack, `handoff`, is sent only when the project's `handoff.auto` key is `true` (it is `false` unless set) or `--handoff` is given, and only to a project whose main agent is Claude Code or Codex; `--no-handoff` leaves it out for this run, and `--handoff` with `--no-packs` is a usage error. With `handoff.auto` and another agent it is skipped with `Warning: the handoff pack was not sent to <project>: ...`, its `packs` row reads `delivered: false`, `pane: null`, `reason: "handoff_unsupported_agent"`, and the run goes on; with `--handoff` the same case fails with `handoff_unsupported_agent` (`details.kind`) before anything is created. A `--handoff` pack is required like `--pack`: a failed delivery is `prompt_not_sent`. See [Automatic handoff](README.handoff.md#automatic-handoff). Another, `dev`, is sent when the project sets `dev.up` and its `dev.instructions` key is not `false`: it tells the agent to run `workspace dev up --queue` and `workspace dev wait` before it implements, tests or verifies, and `workspace dev down` when it is done (see [`dev`](README.dev.md#instructions-for-agents)). `--no-packs` drops it for one run; a project with no `dev.up` gets nothing new. A prompt of automatic packs alone is optional: if the agent is missing or never ready, `start` still exits 0, prints `Warning: the notes pack was not sent to <workspace>: <reason>`, reports `delivered: false` with `pane: null`, and adds the same sentence to `warnings` in `--json`. With `--prompt`, `--play` or `--pack` a failed delivery is `prompt_not_sent` and exit 1, as before. Packs are composed before the worktree is created, so an unknown name fails with `unknown_library_entry` and changes nothing. `workspace instructions compose --start` prints the same text and sends nothing. Once the prompt is delivered, the pane is [bound](README.binding.md#packs) to the packs it was sent (with the play's binding when there is a play, else as kind `play` with id `play/<first pack>`, which leaves a live binding the pane already has alone), so the SessionStart hook repeats them after `/clear` or compaction. Nothing is bound when the prompt was not delivered.

### Spine

With `--spine[=NAME]`, or `spine.auto` true in the config and no `--no-spine`, `start` runs [`spine init`](README.spine.md#spine-init) for the new workspace once its worktree, config and notes directory exist and before it composes the first prompt, so the automatic `spine` pack is sent to the new agent. `--spine=NAME` uses that template; `--spine` alone and `spine.auto` use the resolved `spine.template`. The two flags together are a usage error. An existing `spine/` is left alone (`outcome: exists`), also in a worktree that `start` reuses. A failed init (an unknown template, an unwritable notes directory) is a warning, never a failure of `start`. With `--no-launch` init still runs and no prompt is sent.


### Plan

With `--plan[=TITLE]`, `start` runs [`plan init`](README.plan.md) for the new workspace once its notes directory exists, and sends the agent the built-in `implementation-plan` play (found built-in first, as `plan start` finds it) with the first prompt, so the agent's first job is to fill `## Tasks`. The title is `TITLE`, else the task title (`--title`, `--title-from-ticket`). Give it with an `=`: `--plan "Add SSO"` would take `Add SSO` as the ref; `start` refuses a ref with a space when `--plan` is set. How it combines:

- `--prompt`: the first prompt is the play, the packs, the line "The plan has no tasks yet. Draft them as the play's "Draft the tasks" section says, then end your turn. Do not start any task.", then `The goal: <prompt>`. Without `--prompt` the agent takes the goal from the plan's title.
- `--play`: refused with a usage error, because the first prompt carries the plan play alone. Add other text with `--prompt` or `--pack`.
- `--no-launch`: the plan is still made, nothing is sent, and `plan.drafting` is `false`. Run `plan start` later to send the draft request.
- `--spine` and `spine.auto`: independent. Both run; the spine pack rides along with the play.
- A plan already in the notes directory (a reused worktree) is kept, never replaced (`plan.outcome` `exists`). The draft line is sent only if it has no tasks; with tasks the agent gets the play and the `--prompt` text alone.
- A plan that cannot be written (`notes_dir_unwritable`) is a warning, never a failure of `start`: no play is sent, and the other prompt text goes as usual.

The pane is bound to the play, as `plan start` binds it. After the agent has drafted the tasks, `workspace plan start` has it work them.
`--play NAME` sends the coding agent one line, then any `--prompt` text after a blank line:

```
Read "/Users/me/.config/workspace/library/global/play/kickoff.md" and follow it.

Start at step 2.
```

`--play` may be given more than once, and each value may list plays separated by commas: `--play kickoff,review --play ship` sends three. Whitespace around a name is dropped, empty items are ignored, and a play named twice (also as `NAME` and `play/NAME`) is sent once, at the place it first appeared. The agent gets one `Read ... and follow it.` line per play, in the order given, as one block before the packs and the `--prompt` text:

```
Read "/Users/me/.config/workspace/library/global/play/kickoff.md" and follow it.
Read "/Users/me/.config/workspace/library/global/play/review.md" and follow it.

Start at step 2.
```

A `--play` value that names no play (`--play ""`, `--play ,`) is a usage error, as are more than 20 plays; both are refused before anything is created. Every play is looked up and read before the worktree is created, so one unknown or unreadable play among several fails the whole run with nothing changed.

The play is looked up the way [`library`](README.library.md#scopes) reads are: the parent project's library first, then the global one, then the [built-in plays](README.library.md#built-in-plays). `NAME` is a bare name or `play/NAME`; a prompt of the same name doesn't get in the way, and `--play prompt/NAME` is a usage error. The play is found and read before the worktree is created, so an unknown name (`unknown_library_entry`) or a file that can't be read (`library_source_missing`, e.g. a link to a note iCloud has evicted) fails with nothing changed.

The agent gets the path rather than the text, so it can read the play again after `/clear`. Once the plays are delivered, the pane they went to is [bound](README.binding.md#plays) to them (the first play is the binding's `id`), replacing any earlier run, review or play binding of that pane, so the SessionStart hook reminds the agent of the play after `/clear` or compaction. The play is sent the way `--prompt` is, with the same wait and `--prompt-timeout`, and one that isn't sent fails the same way (`prompt_failures`, exit 1). If the workspace's session is already running, the play is typed into its agent, which may be in the middle of a task.

The file lives outside the worktree. An agent started without `--dangerously-skip-permissions` (the stock template passes it) asks before reading it.

### Agents and skills

`--agent NAME` and `--skill NAME` copy [library](README.library.md) entries into the worktree, where Claude Code loads them when the agent starts:

| Kind | Copied to |
|---|---|
| agent | `.claude/agents/<name>.md` |
| skill | `.claude/skills/<name>/`, every file in the skill's directory |

Those are the defaults. The project's [`library.install.agents_dir` and `skills_dir`](README.library.md#install-directories) (else the global value) replace `.claude/agents` and `.claude/skills`, for example `.agents/skills`; the same keys serve `library install`. Everything below that names `.claude` applies to the configured directory instead.

Both flags repeat, and a name given twice is copied once. `NAME` is a bare name, or `agent/NAME` and `skill/NAME`; an entry of another kind is a usage error. Entries are looked up in the parent project's library first, then global, and checked before the worktree is created, so an unknown name (`unknown_library_entry`) or an unreadable one (`library_source_missing`) fails with nothing changed.

A linked entry is copied too, from the file it points to: change the library entry and run `start` again to refresh the copy. An untracked file or directory already at that path is replaced. One the repo tracks, compared ignoring case as macOS volumes do, is never touched: `start` notes that it kept it, on stderr or in `warnings` under `--json`, and does not fail. Nothing is copied when the install directory, or a directory above it such as `.claude`, is a symlink, since git can not see tracked files through it and the copy would land outside the worktree; that is noted the same way. If git can not say whether a path is tracked, `start` stops with an error after the worktree and its config are made, before launching; run it again once git works. Each path copied is added to the repo's `info/exclude` so `git status` stays clean. For a worktree that is the main checkout's `.git/info/exclude`, which every worktree of the repo shares. An existing or adopted worktree gets the same copies. The exclude lines stay after the worktree is removed, so a file of the same name that you later create in the main checkout is hidden from `git status` until you delete its line. Symlinks inside a skill directory are copied as symlinks, so a relative one may not resolve in the worktree.

### Agent kind and `--no-launch`

`--agent-kind KIND` picks the coding agent the new workspace's main agent pane runs. `KIND` is a coding-agent key, in any case: `claude`, `codex`, `opencode` or `pi`. It swaps the Claude Code pane of the worktree template for the agent's command: `agent.commands.<kind>` when set, else the executable (`codex`). With no flag the kind is `agent.kind` (`claude` unless set), read for the parent project. For `claude` each half of the pane's `||` chain keeps its own flags and only the program changes (no flag is added), so `agent.commands.claude` set to `claude-dev` gives `claude-dev --dangerously-skip-permissions --continue || claude-dev --dangerously-skip-permissions`. `workspace` appends its own flags after the configured command, so make it a single program (a wrapper script that passes its arguments through), not a pipeline or `sh -c '...'`. The command is written into the YAML config and run by the shell; `workspace` quotes it as needed so the file stays valid. An unknown kind fails with `unknown_agent_kind` (`details.kind`, `details.known`) before anything is created. It only shapes a config this run writes: a workspace whose config already exists keeps its panes, and `start` notes `--agent-kind <kind> was not applied` (a `warnings` line under `--json`). A kind whose command's program is not on `PATH` is noted too, and the pane starts nothing. The `handoff` pack is judged against the chosen kind, not the project's.

`--no-launch` does everything `start` does but launch: the worktree, its config, the task, hooks, notes directory and library copies. It starts no session and touches none that is running, and exits 0 with `Not launching <workspace>; start it with `workspace launch <workspace>``. Start it later with [`launch`](README.launch.md). Because there is no agent to send to, `--no-launch` with `--prompt`, `--prompt-timeout`, `--play`, `--pack` or `--handoff` is a usage error before anything is created, and the automatic packs (`notes`, `dev`, `handoff`) are not sent: `packs` is `[]`. `launch --prompt` and `launch --pack` send them afterwards. `--no-packs` and `--no-handoff` are accepted and change nothing. `--headless` has no effect.

### Recipes

`--recipe NAME` (or `recipe/NAME`) applies a [library](README.library.md#recipes) recipe: a saved set of `plays`, `packs`, `agents`, `skills`, `agent_kind` and `prompt`. It is looked up from the parent project, then global, like plays. A flag you pass wins: `--play`, `--pack`, `--agent`, `--skill` replace the recipe's list of that name (they are not added to it), and `--agent-kind` and `--prompt` replace its value. An unknown recipe is `unknown_library_entry`, an invalid one `invalid_recipe`, and either fails before anything is created. A flag can replace a recipe field but not empty it, and a list is never extended; to drop or add to a field, copy the recipe. With `--no-launch` the recipe's plays, packs and prompt are left out, with `--plan` its plays are (`--plan` sends its own play; the prompt becomes the plan's goal), and with `--no-packs` its packs are; a warning says so. Its agents, skills and agent kind still apply.

### Ticket titles and `--slug`

By default a JIRA ref gives the branch `PROJ-123`, an issue `issue-42`, and the task has no title. `--title-from-ticket` reads the title with the same lookup as [`ticket show`](README.ticket.md) (10 seconds, no prompt, no credential handled by `workspace`) and uses it as the task title, unless `--title` is given. `--slug` adds the title's words to the branch, which is also the worktree directory and the workspace name: `PROJ-123-fix-the-login-bug`, `issue-42-fix-the-login-bug`.

- The slug is lowercase ASCII letters and digits joined by single hyphens (accents are dropped), cut at a word boundary to 40 characters, so the branch is always a valid ref. A JIRA key keeps its case in the branch; the workspace name is lowercase as usual.
- `--slug` takes the words from `--title` when given, else from the ticket, and so implies `--title-from-ticket`.
- A pull request (`pr-<n>`) and a plain branch are never changed; `--slug` on them, or on a ref whose ticket has no usable title, leaves the branch as it is and adds a warning.
- A ticket that cannot be read (`gh` or `jira` missing, signed out, slow) is a warning in `warnings` (stderr without `--json`); `start` carries on with the plain branch and no title.
- A worktree already made for the ticket is reused, not duplicated: the one on the slugged branch, else on the plain branch (`PROJ-123`), else on any branch that starts `PROJ-123-` (an earlier `--slug` run under an older title, or when the ticket cannot be read now). A `start` without `--slug` after a slugged one looks only for the plain branch, so pass `--slug` each time.
- The ticket's title has control characters and runs of whitespace replaced by single spaces before it is used.

### Tasks

`start` records a task for the new workspace: its title (`--title`, optional), the input it started from (`ref`), its branch and worktree path. The record is one JSON file, `<id>.json`, under `~/.local/state/workspace/.tasks/` (`$XDG_STATE_HOME/workspace/.tasks/`), mode 0600, written under a lock so concurrent `start`s never clobber each other. It lives there rather than in the worktree because removing a worktree deletes its untracked files.

The task id is exported as `WORKSPACE_TASK` in every pane of the workspace, through a `pre_window:` line the worktree template writes into the workspace's tmuxinator config. Run `workspace init --force` once to refresh an installed template that predates it; a workspace whose config already exists keeps the config it has, so its panes get no `WORKSPACE_TASK`. Starting a workspace that already has an active task keeps that task, and a `--title` replaces its title.

[`finish`](README.finish.md) and [`kill`](README.kill.md) archive the task, moving it to `.tasks/archive/` with an `outcome` (`merged` or `pushed` for `finish`, `abandoned` for `kill`, `discarded` for `kill --force`) and `archived_at`. The newest 200 archived tasks are kept. [`sessions --json`](README.sessions.md) reports the active task and a status derived from the panes' states.

### `--json` output

On success, one line of JSON on stdout (nothing else is written to stdout under
`--json`):

```json
{"schema_version":1,"ok":true,"project":"myproject","workspace":"myproject.worktree-proj-123","path":"/path/to/.worktrees/PROJ-123","branch":"PROJ-123","base":null,"created":true,"headless":false,"launched":true,"agent_kind":"claude"}
```

- `ok` — `true` for the success doc, even one carrying `error`/`prompt_failures`
- `project` — the parent project name
- `workspace` — the generated tmuxinator config name, in lowercase (`myproject.worktree-proj-123`) unless a config for the same worktree already exists under mixed case; one that differs only in case from another worktree's config is refused with `workspace_name_case_conflict`
- `path` — the worktree's filesystem path
- `branch` — the branch checked out in the worktree
- `base` — the ref the branch was created from, or `null` when the branch (or
  worktree) already existed
- `created` — whether the worktree was created by this run, as opposed to reused
  or adopted
- `notes_dir` — the workspace's notes directory (absolute); absent when no path could be worked out (a `warnings` line says why)
- `task` — the workspace's task, `{"id", "title"}` (see [Tasks](#tasks))
- `play` — present only with `--play`: `{"ref", "scope", "path", "sha256", "delivered", "pane"}`. `ref` is
  `play/<name>`, `scope` is `project` or `global`, `path` is the file the agent was
  told to read, `sha256` is the hash of its body when `start` read it (so a caller
  can tell which version of a linked play the agent was pointed at), and
  `delivered` is whether the prompt carrying it was sent, and `pane` is the tmux
  pane id (`%5`) bound to the play, or `null` when it was not delivered or the
  pane could not be bound
- `recipe` — present only with `--recipe`: `{"ref", "scope"}` of the recipe applied. What it filled in shows in the fields below (`play`, `plays`, `packs`, `agents`, `skills`, `agent_kind`)
- `plays` — present only with `--play` or a recipe with plays: an array with one object of the same shape as `play` for each play, in the order sent. `play` is the first of them. Both are absent when no play was given
- `spine` — present only when `spine init` ran: `{"outcome", "template"}`. `outcome` is `created`, `exists` or `failed`; `template` is `{"name", "scope", "source"}` as in [`spine init`](README.spine.md#spine-init) (on `failed`, `{"name", "source"}` when known, plus `error`, the error code). A failure is also in `warnings`
- `plan` — present only with `--plan`: `{"path", "outcome", "title", "drafting"}`. `outcome` is `created`, `exists` or `failed` (then `path` is `null` and `error` is the error code). `title` is left out when the plan has none. `drafting` is whether the draft request was sent with the first prompt (`false` with `--no-launch`, a plan that has tasks, or a failed init). The play it sent is the `play` object. A failure is also in `warnings`
- `packs` — always present: one `{"name", "source", "delivered", "pane"}` object per pack sent, in order, `[]` when none applied. `source` is `config` (automatic) or `flag` (`--pack`); `delivered` is whether the prompt carrying it was sent, and `pane` the tmux pane id it went to (`null` when not delivered). With an explicit prompt, play or pack, an undelivered pack rides the same `prompt_not_sent` failure as the prompt; automatic packs alone only warn (see Packs). A config-driven pack that was left out has `delivered: false`, `pane: null` and a `reason` (`handoff_unsupported_agent`); only such rows carry `reason`
- `agents`, `skills` — present only with `--agent` or `--skill`: one object per entry,
  `{"ref", "scope", "source", "path", "outcome"}`. `source` is the library path
  (a skill's directory), `path` is where it was copied in the worktree, and `outcome` is
  `copied`, `replaced` (an untracked copy was there), `unchanged`, `skipped_tracked`
  (the repo tracks that path, so it was kept), or `skipped_linked` (`.claude` or the
  directory under it is a symlink); each skip also adds a `warnings` line. They sit beside
  `play`, not inside it (see [Agents and skills](#agents-and-skills))
- `launched` — whether the session was started: `false` with `--no-launch`, or when the session could not be started
- `agent_kind` — the agent the workspace's main pane runs, read from its config after it is written (`claude`, `codex`, ...; `none` when the config runs no known agent), so it follows `agent.kind` when there is no flag. For a workspace whose config already existed this is what that config runs, which may differ from `--agent-kind`
- `headless` — whether the session was started headless (see
  [`launch`](README.launch.md#headless))
- `session_reused` — present only when the workspace's tmux session was
  already running (headless or windowed), in which case it was attached to as
  it is instead of started again. Running `start` again for the same
  workspace is safe this way
- `warnings` — present only when non-empty; notes about a flag that was silently
  adjusted, e.g. `--base` ignored because the branch already existed, a
  statusLine command displaced during worktree settings installation (see
  [`workspace statusline`](README.statusline.md)), or run from inside a
  worktree ("run from inside a linked worktree; using parent repo …")

On a hard error (bad input, `--base`/`--yes` needed, git failure), exits 1 with
the error on stdout instead of the success doc:

```json
{"schema_version":1,"ok":false,"error":"...","code":"..."}
```

The worktree can also be created successfully but the `--prompt` fail to reach
the coding agent. In that case the success doc above is still emitted, but with
`error` and `prompt_failures` added and exit code 1:

```json
{"schema_version":1,"ok":true,"project":"myproject","workspace":"myproject.worktree-proj-123","path":"/path/to/.worktrees/PROJ-123","branch":"PROJ-123","base":null,"created":true,"headless":false,"error":"Prompt was not sent to every workspace.","prompt_failures":{"myproject.worktree-proj-123":"agent never became ready"}}
```

Headless, when tmuxinator can't start the session (it fails, times out after 60
seconds, or its session never appears), the success doc is emitted
with `error` set to `Could not start the workspace session: <reason>` (and no
`prompt_failures`), and the exit code is 1.

If a flag was silently adjusted — e.g. `--base` passed for a branch/worktree that
already existed — the success doc includes a `warnings` array instead of printing
to stderr:

```json
{"schema_version":1,"ok":true,"project":"myproject","workspace":"myproject.worktree-proj-123","path":"/path/to/.worktrees/PROJ-123","branch":"PROJ-123","base":null,"created":false,"headless":false,"warnings":["Note: --base ignored; branch 'PROJ-123' already exists."]}
```

## Examples

```sh
# Start from a JIRA key
workspace start PROJ-123

# Start from a GitHub PR
workspace start https://github.com/org/repo/pull/471

# Start from a PR ref of the current repo, or of another repo
workspace start '#471'
workspace start org/repo#471

# Start from a GitHub issue
workspace start https://github.com/org/repo/issues/42

# Start from a branch name
workspace start feature/my-feature

# Start with an initial prompt for Claude
workspace start PROJ-123 --prompt "Fix the login bug"

# Point the agent at a library play, with a note after it
workspace start PROJ-123 --play kickoff --prompt "Start at step 2."

# Point the agent at two plays
workspace start PROJ-123 --play kickoff,review

# Copy a library agent and skill into the worktree
workspace start PROJ-123 --agent reviewer --skill write-tests

# Start in the background with plain tmux, e.g. from CI
workspace start PROJ-123 --headless --yes --json

# Non-interactive, from a script or agent
workspace start PROJ-123 --base main --yes --json
```

## See also

To make a workspace and run a workflow in it in one command, use [`workflow start`](README.workflow.md#starting-from-a-ticket-or-a-prompt).

To move work already in a main checkout into a new workspace, use [`promote`](README.promote.md). It makes the worktree a workspace through `start` and marks the `worktree_started` event `promoted: true`.
