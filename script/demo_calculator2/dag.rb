module DemoCalculator2
  # The acceptance groups each goal's own check runs under `acceptance_runner --dag`: goal number => group numbers.
  # 04 and 05 (the evaluator) and 06 and 07 (the program's arguments and loop) do not depend on each other, so a lane
  # that lacks one pair is checked without the other's groups; the plain run of 07 covers 1..7 after the merge.
  DAG = {1 => [1], 2 => [1, 2], 3 => [1, 2, 3], 4 => [1, 2, 3, 4], 5 => [1, 2, 3, 4, 5], 6 => [1, 2, 3, 6], 7 => [1, 2, 3, 6, 7]}.freeze
end
