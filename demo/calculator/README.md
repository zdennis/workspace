# Calculator demo

A work queue of seven workflow runs builds a command-line calculator, one feature per run. The checkout holds only the stub: `bin/calc` and `lib/calc.rb` report "unsupported" for everything, and `test/calc_test.rb` has one smoke test. The agents in the runs write the rest.

| Workflow | Feature built | Engine feature it shows |
|---|---|---|
| `calc-01-add-sub` | `+` `-` | one step and a `status:` check |
| `calc-02-mul-div` | `*` `/` | `require:` proofs (`commits`, `exec`) |
| `calc-03-div-zero` | divide by zero error | fail-first (`step expect-fail`), `on_fail` with `backoff` |
| `calc-04-precedence` | precedence, parentheses | agent `review:` |
| `calc-05-mod-pow` | `%` `**` | read-only plan step with `guard:` and `produces` |
| `calc-06-json` | `--json` output | `fan_out` group |
| `calc-07-repl` | REPL mode | `timeout:`, `budget:`, `deny:` |

Each file starts with a comment naming its feature. 02 to 05 `extends:` the one before, so `diff` between neighbours shows just that feature. 06 and 07 are written out in full, because the engine cannot yet extend a workflow with a `fan_out` group. No step waits for a person.

## Run it

Make a worktree on a demo branch (never the main checkout), then from inside it:

```
script/demo-calculator run --name WORKSPACE
```

`run` resets the demo, makes sure `demo/calculator/workflows` is in `workflows.sources` and installed, sets the workspace's `commands.test` to `ruby` (for `step expect-fail`), queues the seven workflows, runs `work-queue enable` and the first `work-queue advance`. From then on the workspace's agent daemon starts each next item when the one before it ends; nobody runs `advance`. A failed item pauses the queue: fix it, then `workspace work-queue resume --name WORKSPACE`.

## Watch it

```
workspace events --follow --name WORKSPACE --types work_queue_item_started,work_queue_item_finished,work_queue_item_held,work_queue_paused,work_queue_resumed
workspace work-queue list --name WORKSPACE
workspace workflow status --name WORKSPACE
workspace daemon watch WORKSPACE
workspace work-queue history list --name WORKSPACE
```

The first prints a line as each item starts and ends. The others show the queue, the running item's steps, the daemon's decisions as they happen, and how each finished item ended.

## Run it again

`script/demo-calculator run --name WORKSPACE` again resets and requeues everything, so each run starts from the stub.

`script/demo-calculator reset` alone restores `bin`, `lib`, `test` and `USAGE.md` from `demo/calculator/template/`, commits the change if there is one, and empties the workspace's queue (cancels the running item, skips a held one, removes the waiting ones). It touches nothing outside `demo/calculator/` and that queue. `run` also writes two settings: it puts this checkout's demo workflows directory in the global `workflows.sources`, replacing any other demo checkout's entry (and installs the workflows into the machine-wide cache), and sets the workspace's `commands.test`. `step expect-fail` runs `workspace` from the agent daemon's PATH, so `workspace` must be installed there.

Both verbs refuse to run on `main` or in the main checkout. `--dry-run` prints the commands that change something instead of running them. `--name` defaults to the workspace detected from the current directory. `WORKSPACE_BIN` names another `workspace` program.

## Try the workflows without a run

`workspace workflow simulate calc-04-precedence --script demo/calculator/simulate/calc-04-precedence.yml` plays one through the real engine with a scripted agent.

## The calculator

Run the tests from the repository root with `ruby demo/calculator/test/calc_test.rb`. `USAGE.md` is the calculator's own documentation, which run 06 fills in.
