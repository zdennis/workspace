# Goal

Teach `calc` to evaluate `+` and `-`.

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
$ calc "1 + 2"          # prints 3
$ calc "10 - 4"         # prints 6
$ calc "1.5 + 2.25"     # prints 3.75
$ calc "1.5 - 1"        # prints 0.5
$ calc "1+2"            # prints 3 (spaces optional)
$ calc "  1   +   2  "  # prints 3 (extra spaces allowed)
$ calc "-3"             # prints -3 (a lone number prints itself)
$ calc "-3 + 5"         # prints 2
$ calc "-3 - 4"         # prints -7
```

A number may have a leading minus sign. Exit status is 0 on success.

## Done when

- [ ] Every example above prints exactly what is shown and exits 0.
- [ ] Tests in `demo/calculator2/test/calc_test.rb` cover each example and pass.
- [ ] `bundle exec standardrb demo/calculator2` is clean.
- [ ] The work is committed.

## Out of scope

`*`, `/`, `%`, `**`, parentheses, several operators in one expression, `--json`, a REPL.
