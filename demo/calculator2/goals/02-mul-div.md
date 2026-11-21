# Goal

Teach `calc` to evaluate `*` and `/` between two numbers, as `+` and `-` already are.

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
$ calc "6 * 7"     # prints 42
$ calc "9 / 2"     # prints 4.5
$ calc "1.5*2"     # prints 3
$ calc "0.5/2"     # prints 0.25
$ calc "-6 * 7"    # prints -42 (a leading minus works on either operand)
$ calc "-4 * 5"    # prints -20
```

## Done when

- [ ] Every example above prints exactly what is shown and exits 0.
- [ ] `+` and `-` still work.
- [ ] Tests cover the new behaviour and pass.
- [ ] `bundle exec standardrb demo/calculator2` is clean.
- [ ] The work is committed.

## Out of scope

Division by zero (a later goal), `%`, `**`, parentheses, precedence between operators, `--json`, a REPL.
