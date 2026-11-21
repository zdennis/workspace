# Goal

Add `%` (modulo) and `**` (exponent).

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

`%` has the precedence of `*` and `/`. `**` binds tighter than `*`, `/` and `%`, and associates to the
right.

```
$ calc "7 % 3"        # prints 1
$ calc "2 ** 3"       # prints 8
$ calc "2 ** 3 ** 2"  # prints 512 (2 ** 9)
$ calc "2 * 3 ** 2"   # prints 18
$ calc "1 + 6 % 4"    # prints 3
$ calc "2 * 5 % 4"    # prints 2 (left to right: (2 * 5) % 4)
$ calc "5 % 0"        # error: division by zero on standard error, exit 1
```

Modulo by zero gives the same error as division by zero: `error: division by zero`, nothing on standard
output, exit status 1.

## Done when

- [ ] Every example above behaves exactly as shown, parentheses included in expressions that use these operators.
- [ ] Earlier behaviour still works.
- [ ] Tests cover the new operators, their precedence and associativity, and modulo by zero, and pass.
- [ ] `bundle exec standardrb demo/calculator2` is clean.
- [ ] The work is committed.

## Out of scope

`--json`, a REPL.
