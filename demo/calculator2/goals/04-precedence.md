# Goal

Support expressions with several operators, following precedence and parentheses.

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
$ calc "2 + 3 * 4"          # prints 14
$ calc "3 * 4 + 2"          # prints 14
$ calc "(2 + 3) * 4"        # prints 20
$ calc "4 * (2 + 3)"        # prints 20
$ calc "10 - 3 - 2"         # prints 5 (same precedence goes left to right)
$ calc "16 / 4 / 2"         # prints 2
$ calc "((1 + 2)) * (3 + 4)"  # prints 21 (parentheses nest)
$ calc "(((4 + 5)))"        # prints 9
$ calc "1 / (2 - 2)"        # error: division by zero on standard error, exit 1
```

`*` and `/` bind tighter than `+` and `-`; operators of equal precedence go left to right; parentheses
group. The division-by-zero error from the previous goal still applies anywhere in an expression.

## Done when

- [ ] Every example above behaves exactly as shown.
- [ ] Earlier behaviour (single operators, leading minus, division by zero) still works.
- [ ] Tests cover precedence, left-to-right order, nested parentheses and the zero-divisor case, and pass.
- [ ] `bundle exec standardrb demo/calculator2` is clean.
- [ ] The work is committed.

## Out of scope

`%`, `**`, `--json`, a REPL.
