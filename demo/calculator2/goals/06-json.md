# Goal

Add a `--json` flag that prints the outcome as one JSON object on standard output.

## Context

A small command-line calculator: Ruby, standard library only (no gems). Work only in `demo/calculator2/`.

- `demo/calculator2/bin/calc` is the entry point, `demo/calculator2/lib/calc.rb` holds the logic.
- Tests are minitest, in `demo/calculator2/test/calc_test.rb`. Run them from the repository root with
  `ruby demo/calculator2/test/calc_test.rb`.
- Lint with `bundle exec standardrb demo/calculator2`.
- Behaviour from earlier goals must keep working.
- Today any expression other than the ones earlier goals handle prints `unsupported: EXPR` to standard
  error and exits 2. Leave that as it is for anything this goal does not cover.
- Whole-number results print without a decimal point (`3`, not `3.0`); other results print as a decimal
  (`4.5`). Numbers are integers or decimals, and spaces around operators are optional.

## Behaviour

```
$ calc --json "1 + 2"
{"expression":"1 + 2","result":3}

$ calc --json "9 / 2"
{"expression":"9 / 2","result":4.5}

$ calc --json "1 / 0"
{"expression":"1 / 0","error":"division by zero"}
(exit status 1)
```

- The object has `expression` (the expression text as given) and either `result` (a JSON number) or
  `error` (the message without the `error: ` prefix).
- The object goes to standard output, even for an error; the exit status for an error is 1.
- Without `--json`, output, standard error and exit statuses are exactly as before.

## Done when

- [ ] Every example above behaves exactly as shown, and the output parses as JSON.
- [ ] Output without `--json` is unchanged.
- [ ] Tests cover the success shape, a decimal result, the error shape and exit status, and the plain
  output, and pass.
- [ ] `bundle exec standardrb demo/calculator2` is clean.
- [ ] The work is committed.

## Out of scope

A REPL.
