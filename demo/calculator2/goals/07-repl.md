# Goal

Make `calc` with no arguments start a read-eval-print loop.

## Context

A small command-line calculator: Ruby, standard library only (no gems). Work only in `demo/calculator2/`.

- `demo/calculator2/bin/calc` is the entry point, `demo/calculator2/lib/calc.rb` holds the logic.
- Tests are minitest, in `demo/calculator2/test/lane_b_test.rb`. Run every test file from the repository root with
  `ruby -e 'files = Dir["demo/calculator2/test/*_test.rb"].sort; abort "no test files match demo/calculator2/test/*_test.rb" if files.empty?; files.each { |file| require File.expand_path(file) }'`.
- Lint with `bundle exec standardrb demo/calculator2`.
- Behaviour from earlier goals must keep working.
- Today any expression other than the ones earlier goals handle prints `unsupported: EXPR` to standard
  error and exits 2. Leave that as it is for anything this goal does not cover.
- Whole-number results print without a decimal point (`3`, not `3.0`); other results print as a decimal
  (`4.5`). Numbers are integers or decimals, and spaces around operators are optional.

## Behaviour

Running `calc` with no arguments reads standard input line by line. It writes the prompt `> ` to
standard output before each read, evaluates each line with the same rules and flags as the command line
(`--json` included, so `calc --json` prints each result as the JSON object), and prints each result
exactly as the command line would.

```
$ printf '1 + 2\n6 * 7\nexit\n' | calc
> 3
> 42
> 

$ printf '1 / 0\n6 * 7\nexit\n' | calc
> error: division by zero
> 42
> 
```

- The loop ends on a line `exit`, a line `quit`, or end of input. Lines after `exit` or `quit` are not
  evaluated. With empty input it prints the prompt once and ends.
- A bad line (division by zero, unsupported) prints its error as the command line would (standard error
  text, or the JSON error object with `--json`) and the loop goes on. Errors in the loop do not change
  the exit status of the program; it exits 0 when the loop ends normally.
- `calc "EXPR"` with arguments behaves as before.
- Blank lines are ignored.

## Done when

- [ ] Every example above behaves as shown.
- [ ] Command-line behaviour (with arguments) is unchanged.
- [ ] Tests cover the prompt, several lines, `exit`, `quit`, end of input and a bad line followed by a
  good one, and pass.
- [ ] `bundle exec standardrb demo/calculator2` is clean.
- [ ] The work is committed.

## Out of scope

Line editing, history, variables, new operators.
