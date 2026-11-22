# Calculator 2

A demo app for the delivery-loop workflow. It starts as a stub: `bin/calc` reports
`unsupported: EXPR` on stderr and exits 2 for every input. Seven goals, one per feature, teach it
arithmetic, division errors, precedence, `%` and `**`, `--json` and a REPL.

## Layout

- `bin/calc`, `lib/calc.rb`, `test/calc_test.rb`: the app and its own tests (Ruby stdlib, minitest).
- `goals/01-add-sub.md` .. `goals/07-repl.md`: the goal each run is given.
- `workflows/deliver-goal.yml`: the workflow that delivers one goal.
- `acceptance/`: black-box tests that score a run, run by `script/demo_calculator2/acceptance_runner`.
  Hidden from agents on the run branch, as is this README.

## Running

```
script/demo-calculator2 run     # fresh run branch, queue all seven goals
script/demo-calculator2 eval    # score a recorded run
script/demo-calculator2 reset   # put the app back to its stub
```

Run the app's own tests with `ruby demo/calculator2/test/calc_test.rb`, and lint with
`bundle exec standardrb demo/calculator2`.

## Integration and waits

In a lanes run, lane A merges lane B's branch and runs the first-pass checks: the test command, lint and the
plain acceptance run on goal 07. A conflict or a failed check queues a repair in lane A and the run waits for it.

- A clean merge whose checks failed is repaired by `integrate-merged`. The merge stays committed on lane A's
  branch, and the workflow checks it and fixes what it finds, with no merge turn. `integrate-branch` runs only
  for a conflict or a failed merge.
- Duplicate test method names in the merged `test/calc_test.rb` fail the first pass.
- The merge driver for `calc_test.rb` is configured as `ruby "$(git rev-parse --show-toplevel)/script/demo_calculator2/merge_test_methods" %O %A %B`.
  The command names no checkout path, so every worktree runs its own copy.
- The driver merges `calc_test.rb` method by method against the fork point. Lane B's new tests, helpers and `require`
  lines go in, and a method only lane B changed or removed takes lane B's version. Both lanes changing one method, or
  lane B changing any other line, is a conflict.

## Running a lanes series

`series` is the way to run a lanes run. It checks everything first, starts the two workspaces, shares the merge
driver and the workflow definitions, runs, saves the evidence, pins the heads, cleans up and prints one scoreboard row.

```
script/demo-calculator2 series --id ID [--lanes 2] [--workflow deliver-goal-fast] [--sonnet] [--base main] [--keep]
                               [--evidence-dir DIR] [--scoreboard FILE] [--dry-run] [--take-over]
script/demo-calculator2 series --forget ID
```

Options:

- `--id ID`: names the series: lowercase letters and digits, starting with a letter, not `b`. Required unless `--forget`.
- `--lanes N`: only 2 is supported (default 2).
- `--workflow ID`: the workflow each goal runs as (default `deliver-goal-fast`).
- `--sonnet`: runs the agents on `claude-sonnet`.
- `--base REF`: the ref to branch from (default `main`). `main` must equal `origin/main`, and the base's latest CI run must pass.
- `--keep`: keeps the workspaces, branches and shared values after the run.
- `--evidence-dir DIR`: where the evidence goes (default `tmp/demo-calculator2/series/<id>` in this checkout).
- `--scoreboard FILE`: appends the scoreboard row to FILE instead of printing it.
- `--dry-run`: prints every step and every shared key with its state and what a series would do. It changes nothing.
- `--take-over`: replaces a shared value (merge driver, attributes line, `workflows.sources` entry) that another live
  checkout owns. Allowed only when that owning checkout has no going run.
- `--forget ID`: cleans up a series whose process is gone (a crash, or one run with `--keep`).

`WORKSPACE_BIN` names another `workspace` program.

### Steps

1. Preflight, which only reads: the id is valid and unused, `main` equals `origin/main`, the base's latest CI run
   passed, the `test-db` lock is free, the shared values are not owned by another live checkout, and the
   workflow definitions match the base's.
2. Register the id and start both workspaces, `calc2-demo-<id>` and `calc2-demo-<id>-b`, then check each is at the base.
3. With `--sonnet`, set `agent.commands.claude` to `claude-sonnet` in both and relaunch them.
4. Wait for an idle Claude Code pane in both lanes (every 5 seconds, at most 300).
5. Write the shared values, each recorded in the registry first.
6. Run the lanes from lane A's checkout, with its output appended to `runs/<id>/driver.log`.
7. Save the evidence in lane A's `runs/<id>/`: eval, the work-queue histories, each run's attempts and trace, and `command.txt`.
8. Pin the heads, copy the evidence to the evidence directory, kill the workspaces, delete the branches, deregister
   the id and undo the shared values. `--keep` skips all of this. If the evidence copy fails, nothing is killed and
   the id stays registered.
9. Append or print the scoreboard row, then print `LOOP DONE: series <id> ...`.

### Exit codes

- 0: the run ended with `LOOP DONE: ... items=7/7`.
- 3: it stopped after the workspaces started. Steps 7 to 9 still run for what exists.
- 1: a refusal before anything started.

### What it leaves behind

- The evidence directory, `tmp/demo-calculator2/series/<id>` unless `--evidence-dir` says otherwise.
- The pinned heads, `refs/demo-calc2-runs/<id>` and `refs/demo-calc2-runs/<id>-b`.
- With `--keep`, neither of the two above: nothing is pinned or copied, the evidence stays in lane A's
  `runs/<id>/`, and both lane workspaces keep running.
- The scoreboard row, on stdout or appended to `--scoreboard`.
- The registry, `<git-common-dir>/demo-calc2/series.json`. It holds the id while the series runs, and after
  `--keep` or a failed evidence copy, until `--forget`.

### When to use `--dry-run` and `--take-over`

Run `--dry-run` first on a new id or a new checkout. It lists every refusal a real series would hit, prints the plan,
and exits 1 if there were any refusals, else 0.

Use `--take-over` when a refusal says a shared value belongs to another checkout and that checkout has no going run.
It still refuses while the owning checkout has a going run, or when the owner is unknown.

### Forgetting a stale id

An id left in the registry after a crash, or after `--keep`, blocks that id from being used again, and a dry run lists
it as stale. `series --forget ID` runs the cleanup steps for it (pin, copy, kill, delete, deregister). It refuses
while the series' process is alive, and it adds no scoreboard row.
