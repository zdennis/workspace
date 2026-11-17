# workspace binding

Bind a tmux pane to a workflow run, a PR review or a library play, so the agent in it is reminded of its subject after a restart, `/clear`, resume or compaction.

## Usage

```sh
workspace binding set [WORKSPACE] [--pane PANE] --kind run|review|play|reflection --id ID [--step STEP] [--attempt N] [--focus TEXT] [--instructions PATH] [--artifacts PATH] [--pack NAME]... [--name NAME] [--json]
workspace binding show [--pane %ID] [--json]
workspace binding clear [--pane %ID] [--json]
```

`set` takes a pane id (`%19`) or `window.pane` (`0.1`) of the workspace's own tmux session, and stores the binding under the pane id. `WORKSPACE` (or `--name`) defaults to the project detected from the current directory. `show` and `clear` take a pane id. All three default to `$TMUX_PANE`, the pane the command runs in, so an agent can bind its own pane and ask what it is bound to.

| Option | Description |
|--------|-------------|
| `--pane PANE` | The pane to bind, show or clear (default `$TMUX_PANE`) |
| `--kind KIND` | `run` (a workflow run), `review` (a PR review), `play` (a [library](README.library.md) play) or `reflection` (see [Reflections](#reflections)) |
| `--id ID` | The run id, the review id such as `acme/api#835`, or the play ref such as `play/kickoff` |
| `--step STEP` | The step the pane is working on |
| `--attempt N` | The step's attempt, 1 or more |
| `--focus TEXT` | What a review concentrates on, such as `security` |
| `--instructions PATH` | A file holding the pane's instructions; a relative path is stored as an absolute one, from the directory the command runs in; a blank value is a usage error |
| `--artifacts PATH` | A directory holding the subject's artifacts; stored as an absolute path, like `--instructions` |
| `--pack NAME` | A [library pack](README.instructions.md) the agent is told again after `/clear` or compaction (`set`; repeatable). Replaces the stored list; an unknown name fails before anything is bound |
| `--json` | Print one action document |

Every text value is one line of at most 200 characters, counted after a path is made absolute. Nothing is typed into the pane, and no prompt text is stored.

## Reflections

[`workflow learn reflect`](README.workflow.md#reflecting-on-a-finished-run) binds the new pane it makes, with kind `reflection`, the run id as `id`, the run's evidence directory as `artifacts` and `reflection.prompt.md` as `instructions`. `binding set --kind reflection` can make one by hand, but the write guard computes the allowed file from the run id, never from `artifacts`.

The binding ends by itself. It is removed when the agent's turn ends with `reflection.md` written as a regular file, and when the session ends, whatever the file's state (a `/clear` does not end it). To end it sooner, run `workspace binding clear --pane ID` or close the pane. While it lasts, a guard holds the pane's file tools to that one `reflection.md` (a tripwire, not a sandbox: shell commands are not covered), `plan start` and `spine start` do not type into the pane, and a second reflection on the same run is refused.

## Plays

[`start --play`](README.start.md#plays) and [`launch --play`](README.launch.md) bind the pane they delivered a play to, with kind `play`, the play ref as `id` and the play file as `instructions`. After `/clear` the agent is told to read the play again:

```text
This pane is following play play/kickoff in api.
Instructions: /Users/me/.config/workspace/library/global/play/kickoff.md. Read it again and keep following it if it is no longer in your context.
```

With several plays (`--play a,b`), `id` and `instructions` are the first play's, and `plays` lists every play as `{"id", "instructions"}` in the order sent (at most 20, each value one line of up to 200 characters). A play binding made by `start` or `launch` always has `plays`; a binding set by hand may leave it out, and then names just the play in `id`. The reminder names them all:

```text
This pane is following plays play/kickoff, play/review in api.
Instructions: /Users/me/.config/workspace/library/global/play/kickoff.md.
Instructions: /Users/me/.config/workspace/library/global/play/review.md.
Read them again and keep following them if they are no longer in your context.
```

The binding replaces any earlier binding of that pane, and stays until `binding clear --pane %ID` or a new binding; clear it when you give the pane other work, or the agent is pointed back at the play after its next `/clear`. Only a play that was delivered binds its pane. A pane that can't be bound, such as one whose play path is longer than 200 characters, gets a warning on stderr; the play was still sent.

## Packs

A binding lists the library packs its agent was sent, in `packs` (`[]` when none), so the reminder repeats them as well as the subject. [`start`](README.start.md#packs) and [`launch`](README.launch.md) set the list to the packs they delivered (the automatic `notes`, `spine` and `dev` packs and any `--pack`). Added to a play's binding, the packs follow its `instructions` line. A pane sent packs but no play is bound with kind `play` and `id` `play/<first pack>`, with no `instructions`; its subject line reads "This pane was started with instruction packs in api." Such a binding does not replace a live binding the pane already has (a run's, say); a play's does, as before.

On `SessionStart` the hook composes the listed packs again from the library as it is then, with the heading each pack gets in [`instructions compose`](README.instructions.md), and prints them after the subject under "Instructions you were sent when this pane started:" (cut at 12,000 characters). If a pack can no longer be read (removed, or its file unreadable), the hook prints the subject alone, as it did before. `binding show` prints a `Packs:` line, and `restore` carries the list with the binding.

## SessionStart

[`workspace session-event`](README.session-event.md) looks the pane up on every `SessionStart` (`startup`, `clear`, `resume` and `compact`) and, for a bound pane, prints Claude Code's `additionalContext` on stdout:

```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"This pane is bound to workflow run wr_01 in api.\nStep: implement (attempt 2).\nInstructions: .workflow/wr_01/steps/implement.2.prompt.md. Reread them if your context was compacted."}}
```

A binding only counts in the tmux session it was made in: a pane id from another session gets nothing. It also has to be in the pane slot (`session:window.pane`) it was made in, so a pane id reused after a tmux restart gets nothing. A binding whose pane has since moved to another slot needs a new `binding set`. `binding show` says when a binding is stale in this way: it prints a `Stale:` line after the binding, and `--json` reports `"stale": true` in the `binding` object. [`instructions compose`](README.instructions.md) leaves a stale binding out. Bindings live in `bindings.json` in workspace's state directory (`$XDG_STATE_HOME/workspace`), mode 0600, and stay until `binding clear` or a new `binding set` for the pane. A lookup that fails is skipped; it never fails the hook. If `bindings.json` can't be parsed, the next `binding set` copies it to `bindings.json.corrupt`, warns on stderr, and starts a fresh file.

## Review panes

A workflow run's binding can carry `role` and `round`. No `role` (or `author`) is the step's own agent. `reviewer` marks the pane a [step review](README.workflow.md) round runs in, with `round` (1 or more) its round number; `kind` stays `run` (`review` is the PR-review kind above), and a binding set by hand with `--kind run` has no role. Lookups by run (the pane a run's turn is read from, `workflow` commands, `restore`) find the author's pane and never a review pane, so the two bindings of one run do not replace each other. A review pane's reminder names its run, step, round and the round's prompt file (`instructions`, made relative to the checkout when the absolute path is over 200 characters, left out when still too long), never the author's instructions:

```text
This pane is a review pane for workflow run wr_01 in api.
Step: plan (attempt 2).
Round: 1.
Review prompt: .workflow/wr_01/reviews/plan.2.1.prompt.md. Reread it if your context was compacted.
```

A reviewer binding records the tmux server's pid (`server_pid`) and is stale in another tmux session or under another tmux server (pane ids start over when tmux restarts), but not in another window slot, so `renumber-windows on` does not strand a round ([`doctor`](README.doctor.md) still warns when it is on). `restore` never carries a reviewer binding to a new pane: it is dropped. A review pane may write only its round's verdict files, and only from a sub-agent: the `session-event` PreToolUse hook refuses any other `Edit`, `Write`, `MultiEdit`, `NotebookEdit` or `apply_patch` (see [`session-event`](README.session-event.md)). The `deny:` tripwire of the run's definition applies to the review pane; `dev up`, `lock acquire` and `promote` treat only the author's pane as the run's own. `binding show --json` reports `role`, `round` and `server_pid` in `binding` when set. A workflow step's `workflow` commands (`approve`, `reject`, `resume`) refuse to run from a review pane as from the author's, and a review pane is never taken as a pane to start a step in.

## --json

```json
{"schema_version":1,"ok":true,"action":"binding set","status":"ok",
 "results":[{"workspace":"api","outcome":"bound","reason":null,"message":null,
   "binding":{"kind":"run","id":"wr_01","step":"implement","attempt":2,"workspace":"api",
     "session":"api","pane_slot":"api:0.1","packs":[],"pane_id":"%5","bound_at":"2026-10-03T12:00:00Z"}}],
 "warnings":[],"summary":{"bound":1}}
```

`outcome` is `bound`, `shown` or `cleared`. `show` adds `stale` (true or false) to `binding`; `set` and `clear` don't. Every `binding` object has `packs`, an array of pack names, `[]` for a binding with none or one made before packs existed. `show` and `clear` also always report `plays`, the `{"id", "instructions"}` list: a binding set by hand or made before `plays` existed reads as its single play, and a binding with no instructions as `[]`. `show` and `clear` on a pane with no binding fail with the `not_bound` code; a bad kind, id or attempt is a `usage` error. `set` fails with `no_session`, `wrong_session` or `no_such_pane` like the other commands that take a pane.

## Examples

```sh
workspace binding set my-app --pane %5 --kind run --id wr_01 --step implement --attempt 2
workspace binding set --pane 0.1 --kind review --id acme/api#835 --focus security
workspace binding set --kind run --id wr_01 --instructions plan.md    # this pane, inside tmux
workspace binding set --pane %5 --kind play --id play/notes --pack notes --pack handoff
workspace binding set --kind play --id play/orchestrator             # from inside the agent's own pane
workspace binding show
workspace binding show --pane %5 --json                              # stale, packs and plays; no binding exits 1 with not_bound
workspace binding clear
workspace binding clear --pane %5
```
