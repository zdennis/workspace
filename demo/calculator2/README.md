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
