# Goal

Make dividing by zero report a clear error instead of raising or printing Infinity.

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
$ calc "1 / 0"
(standard output: nothing)
(standard error:  error: division by zero)
(exit status 1)

$ calc "2.5 / 0"   # the same
$ calc "1 / 2"     # still prints 0.5
```

The error line is exactly `error: division by zero` on its own line of standard error, and nothing is
written to standard output. The exit status is 1 (not 2, which stays for `unsupported`).

## Done when

- [ ] `calc "1 / 0"` and `calc "2.5 / 0"` print the error line to standard error, nothing to standard
  output, and exit 1.
- [ ] Ordinary division still works.
- [ ] Tests cover the error (stderr text and exit status) and pass.
- [ ] `bundle exec standardrb demo/calculator2` is clean.
- [ ] The work is committed.

## Out of scope

`%`, `**`, parentheses, `--json`, a REPL.
