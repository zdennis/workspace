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

`script/demo-calculator run --name WORKSPACE` again starts a fresh run. Each run gets its own branch, `calc-demo/<stamp>`, made from `--base` (default `HEAD`). On a `calc-demo/*` branch `run` refuses unless you pass `--base`, so a second run does not stack on the first one's commits. The branch's first commit removes `demo/calculator-acceptance/` and this README, so the agents cannot read the tests that score them or where they live; `eval` reads those tests from the base commit later. Every definition also carries `deny: ["*acceptance*"]`, which refuses an agent's Bash command that names the tests (a tripwire: the hook checks the run's pane, reviewer panes included, but `bash -c`, a script or a variable gets past it). `run` then writes `run.json` (the branch, the base, the queued runs and a hash of each workflow definition) to `--out`, by default `tmp/demo-calculator/runs/<stamp>/`. A record written to an `--out` outside `tmp/demo-calculator/runs/` is not found by `eval` without `--run`, nor by `eval --compare`. An `--out` inside the repository leaves untracked files, and the next `run` refuses on them until you remove them.

```
script/demo-calculator run --name WORKSPACE --base main --out DIR
```

By default `run` returns once the first item has started. With `--wait` it keeps watching the queue and stops for the first of these reasons, which it records in `run.json`:

| Reason | When |
|---|---|
| `timeout` | `--timeout` has passed in all (default `4h`) |
| `paused` | an item failed and paused the queue |
| `disabled` | the queue was switched off with items still in it |
| `held` | an item has stayed held longer than `--held-limit` (default `20m`) |
| `empty` | every item ended |

If the workspace's agent daemon cannot advance the queue itself (an older `workspace`, or no daemon), `--wait` runs `work-queue advance` whenever nothing is starting or active and an item waits.

`script/demo-calculator reset` alone restores `bin`, `lib`, `test` and `USAGE.md` from `demo/calculator/template/`, commits the change if there is one, and empties the workspace's queue (cancels the running item, skips a held one, removes the waiting ones). It touches nothing outside `demo/calculator/` and that queue. `run` also writes two settings: it puts this checkout's demo workflows directory in the global `workflows.sources`, replacing any other demo checkout's entry (and installs the workflows into the machine-wide cache), and sets the workspace's `commands.test`. `step expect-fail` runs `workspace` from the agent daemon's PATH, so `workspace` must be installed there.

`run` and `reset` refuse to run on `main` or in the main checkout. `--dry-run` prints the commands that change something instead of running them. `--name` defaults to the workspace detected from the current directory. `WORKSPACE_BIN` names another `workspace` program.

## Score a run

```
script/demo-calculator eval [--run DIR] [--name WORKSPACE] [--json]
script/demo-calculator eval --compare [--last K]
```

`eval` scores one recorded run (`--run DIR`, default the newest under `tmp/demo-calculator/runs`). It prints a table with one row per workflow and a `total` row, and writes the same numbers to `eval.json` beside `run.json`. `--json` prints that document instead of the table.

The columns are `feat` (engine features, below), `att` (attempts), `retry`, `rnd` (review rounds), `wall`, `active`, `stopped`, `gap` (from one item ending to the next starting), the four token kinds, `cost` and `accept`. `accept` is the acceptance groups that pass out of the item's number, using the groups as they stood at the base commit; a failing group below the item is listed as `reg:`. Under the table, `lint:` counts `standardrb` offenses in `demo/calculator` at the last item's commit.

`feat` counts the engine features a workflow declares by what the run did with them: `f` fired (the run shows evidence of it), `m` missed (a feature on the success path with no evidence), `a` armed (a failure-only feature such as `backoff`, `deny`, `budget` or `timeout`, which a clean run never has to use) and `?` unknown. `3f 1a 1m` is three fired, one armed, one missed.

Three marks stand in for numbers that are not zero. `?` means the value was not recorded or cannot be read. `≥` before a total means part of it is unknown, so the total is a lower bound. `not run` marks an item that never started because the wait stopped first.

`cost` is `≈$` from `demo/pricing.yml`, which lists USD per million tokens for each model and token kind. Those prices still need confirming against the current price list before anyone quotes a figure. A model missing from the file prices as `?`.

The `leak:` line counts reads of `calculator-acceptance` by the agents: lines in the workspace's hook event log (and its `.1` rotation) inside the run's time span, and lines in each attempt's session transcript. A count above zero means an agent may have seen the tests. A command counts when it starts with a reader, a lister, `tar`, `ruby` (a run of a group file) or `git show|archive|cat-file|ls-tree` and names the directory. Each session's sub-agent transcripts (`<session>/subagents/agent-*.jsonl`) are added to its count. The count misses some reads. The hook log keeps only the first line of a Bash command, so a multi-line command that names the directory on a later line goes uncounted, and a command that builds the path in a variable leaves no path to match. A transcript that cannot be read shows as unreadable.

`eval --compare` reads the `eval.json` files alone, so it works after the run archive is capped. It takes the last `K` runs (`--last`, default 3) that have the same items, model and agent version as the newest run, whatever happened to the definitions, and prints each total as `median [min–max]`, with `≥` where a run lacked the value. Under the header, one `definition ID: same|differs` line per item says whether its definition hash differs across the compared runs. With fewer than `K` matching runs (and never fewer than two) it lists those runs and prints no medians, so `--last 2` compares two. Its header names the fields that differ between runs (model, agent version, base, workspace commit, price date), so a median is not read across a model change unnoticed.

## Try the workflows without a run

`workspace workflow simulate calc-04-precedence --script demo/calculator/simulate/calc-04-precedence.yml` plays one through the real engine with a scripted agent.

## The calculator

Run the tests from the repository root with `ruby demo/calculator/test/calc_test.rb`. `USAGE.md` is the calculator's own documentation, which run 06 fills in.

The acceptance tests live in `demo/calculator-acceptance/`: one file per run, `group_1_add_sub_test.rb` to `group_7_repl_test.rb`, each checking what that run builds through `bin/calc` as a black box. They are minitest files that share `support.rb`. Run one group alone by pointing `CALC_ROOT` at the `demo/calculator` directory to test:

```
CALC_ROOT="$PWD/demo/calculator" ruby demo/calculator-acceptance/group_3_div_zero_test.rb
```

Without `CALC_ROOT` a group tests the calculator beside it. Run branches do not contain these files, so run a group from a checkout that does, such as the base commit.
