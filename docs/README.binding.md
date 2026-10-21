# workspace binding

Bind a tmux pane to a workflow run, a PR review or a library play, so the agent in it is reminded of its subject after a restart, `/clear`, resume or compaction.

## Usage

```sh
workspace binding set [WORKSPACE] [--pane PANE] --kind run|review|play --id ID [--step STEP] [--attempt N] [--focus TEXT] [--instructions PATH] [--artifacts PATH] [--pack NAME]... [--json]
workspace binding show [--pane %ID] [--json]
workspace binding clear [--pane %ID] [--json]
```

`set` takes a pane id (`%19`) or `window.pane` (`0.1`) of the workspace's own tmux session, and stores the binding under the pane id. `WORKSPACE` (or `--name`) defaults to the project detected from the current directory. `show` and `clear` take a pane id. All three default to `$TMUX_PANE`, the pane the command runs in, so an agent can bind its own pane and ask what it is bound to.

| Option | Description |
|--------|-------------|
| `--pane PANE` | The pane to bind, show or clear (default `$TMUX_PANE`) |
| `--kind KIND` | `run` (a workflow run), `review` (a PR review) or `play` (a [library](README.library.md) play) |
| `--id ID` | The run id, the review id such as `acme/api#835`, or the play ref such as `play/kickoff` |
| `--step STEP` | The step the pane is working on |
| `--attempt N` | The step's attempt, 1 or more |
| `--focus TEXT` | What a review concentrates on, such as `security` |
| `--instructions PATH` | A file holding the pane's instructions; a relative path is stored as an absolute one, from the directory the command runs in; a blank value is a usage error |
| `--artifacts PATH` | A directory holding the subject's artifacts; stored as an absolute path, like `--instructions` |
| `--pack NAME` | A [library pack](README.instructions.md) the agent is told again after `/clear` or compaction (`set`; repeatable). Replaces the stored list; an unknown name fails before anything is bound |
| `--json` | Print one action document |

Every text value is one line of at most 200 characters, counted after a path is made absolute. Nothing is typed into the pane, and no prompt text is stored.

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
workspace binding show
workspace binding clear --pane %5
```
