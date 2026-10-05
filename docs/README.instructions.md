# workspace instructions

Print the instructions an agent is given, built from library packs.

## Usage

```sh
workspace instructions compose [--pack NAME]... [--pane %ID] [--name WORKSPACE] [--json]
```

A pack is a [library](README.library.md) play. workspace ships four:

| Pack | What it tells the agent |
|---|---|
| `binding` | How to work in a pane workspace has [bound](README.binding.md) to a run, a review or a play: read the instructions file, write to the artifacts directory, record questions with `workspace ask`, end the turn when done |
| `orchestrator` | Delegate to sub-agents, pass `model:` on every Agent call, keep tasks small and reports terse, have a separate agent check each phase |
| `commits` | Cohesive commits, tests and lint before each one, messages about why, no attribution lines, no push or merge unless told |
| `review` | Run reviewer sub-agents over the diff, fix or answer every finding, write `review.md` |

With no `--pack`, the default packs are composed: `binding`, `orchestrator` and `commits`, in that order, or the ones the global key `workflows.defaults.include` names (`workspace config set workflows.defaults.include "binding, commits"`). `--pack` repeats, and packs are composed in the order given; a name given twice is composed once.

| Option | Description |
|--------|-------------|
| `--pack NAME` | A pack to compose: `NAME` or `play/NAME` |
| `--pane PANE` | The pane id (`%19`) whose binding follows the `binding` pack (default `$TMUX_PANE`, unless `--name` is given) |
| `--name WORKSPACE` | Compose for this workspace instead of the current directory |
| `--json` | Print one JSON document |

## Output

Each pack is printed under a heading that names where it came from, without its frontmatter (a leading block of `key: value` lines between two `---` lines):

```text
## From pack orchestrator (built-in)

You are an orchestrator. You hold the plan, decide what happens next, and report results.
...

## From pack commits (built-in)

- Make each commit one cohesive change, with its tests.
...

Test command for this project: `bundle exec rspec`
Lint command for this project: `bundle exec standardrb lib/ spec/`
```

Two built-in packs get lines for the caller:

- `binding` is followed by the pane's binding, worded as the [SessionStart hook](README.binding.md#sessionstart) words it, when `--pane` (or `$TMUX_PANE`) is bound. A stale binding, one whose pane is no longer in the tmux session and slot it was bound in, is left out, as the hook leaves it out. With `--name` there is no default pane, since `$TMUX_PANE` is the caller's pane and not one of that workspace's. Text composed for another pane, as in `start --prompt "$(workspace instructions compose)"`, would carry the caller's binding: name the packs and leave `binding` out, as the last example does.
- `commits` is followed by the project's test and lint commands when they are set:

  ```sh
  workspace config set commands.test "bundle exec rspec"
  workspace config set commands.lint "bundle exec standardrb lib/ spec/"
  ```

  A worktree reads its parent project's commands. A command holding a backtick gets a longer code fence, and one of several lines a fenced block. See [`config`](README.config.md).

## Workflow steps

A [workflow](README.workflow.md) step's instructions file is composed the same way, in four layers, each under its own heading:

1. the default packs (`workflows.defaults.include`, else `binding`, `orchestrator`, `commits`);
2. the workflow's `include:` packs, then its `instructions:` under `## From workflow <id>`;
3. the step's `include:` packs, then its prompt under `## From step <id>`;
4. `## For this attempt`: what the runner knows about this attempt, such as why the last one failed (with the check's log), a reject or approve note, and the `--note` of `workflow run` or `workflow resume`.

A pack named in more than one layer is composed once, where it is first named. The `binding` pack tells the agent about `workspace step status` and `workspace step done`. In a step's file it is followed by the binding the pane gets for that step: the run, step, attempt, instructions file and artifacts directory.

## Your own packs

Any library play can be named as a pack. `--pack house-rules` looks for `play/house-rules` in the project's library, then the global one, and the heading says which: `(project my-app)` or `(global)`.

The built-in packs can't be replaced. `--pack` searches the built-in plays first, so a play of yours named `review` is not used in place of the `review` pack; give it another name and pass that. (`workspace library show review` and `start --play review` do use yours: they search built-in last.) `workspace library list --builtin` lists the built-in packs and `workspace library show NAME --builtin` prints one.

## --json

```json
{"schema_version":1,"ok":true,
 "packs":[
   {"ref":"play/orchestrator","scope":"builtin","project":null,
    "path":"/opt/workspace/lib/library/play/orchestrator.md",
    "sha256":"9f2c..."}],
 "binding":null,
 "text":"## From pack orchestrator (built-in)\n\nYou are an orchestrator. ...\n"}
```

`packs` lists what was composed, in order: `scope` is `builtin`, `global` or `project` (with `project` naming it), and `sha256` is the hash of the pack file, frontmatter included. `binding` is the pane's binding when one was found and is not stale, else null; it is reported whether or not the `binding` pack was composed. `text` is what the command prints without `--json`.

Errors use the [envelope](README.json.md): `unknown_library_entry` for a pack no searched scope has (`details.scopes` lists them in the order searched, `builtin` first), `library_source_missing` for a pack that can't be read, `unknown_workspace` for a bad `--name`, and `usage` for a bad name, a pack that is not a play, or a `--pane` that is not a pane id. Nothing is printed on stdout but the envelope.

## Examples

```sh
workspace instructions compose
workspace instructions compose --pack orchestrator
workspace instructions compose --pack commits --pack review --name my-app --json
workspace start feature/x --prompt "$(workspace instructions compose --pack orchestrator)"
```
