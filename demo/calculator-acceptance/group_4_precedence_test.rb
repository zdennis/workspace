require_relative "support"

class Group4PrecedenceTest < Minitest::Test
  include CalcSupport

  def test_multiplication_binds_tighter_than_addition
    assert_value 14, "2 + 3 * 4"
    assert_value 14, "3 * 4 + 2"
  end

  def test_parentheses_group
    assert_value 20, "(2 + 3) * 4"
    assert_value 20, "4 * (2 + 3)"
  end

  def test_left_to_right
    assert_value 5, "10 - 3 - 2"
    assert_value 2, "16 / 4 / 2"
    assert_value 3, "10 - 4 - 3"
  end

  def test_nested_parentheses
    assert_value 21, "((1 + 2)) * (3 + 4)"
    assert_value 9, "(((4 + 5)))"
  end

  def test_division_by_zero_is_still_reported
    assert_division_by_zero "1 / (2 - 2)"
  end
end
