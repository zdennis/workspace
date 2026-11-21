require_relative "support"

class Group1AddSubTest < Minitest::Test
  include CalcSupport

  def test_addition
    assert_value 3, "1 + 2"
  end

  def test_subtraction
    assert_value 6, "10 - 4"
  end

  def test_decimals
    assert_value 3.75, "1.5 + 2.25"
    assert_value 0.5, "1.5 - 1"
  end

  def test_spaces_are_optional
    assert_value 3, "1+2"
    assert_value 6, "10-4"
    assert_value 3, "  1   +   2  "
  end

  def test_leading_minus
    assert_value(-3, "-3")
    assert_value 2, "-3 + 5"
    assert_value(-7, "-3 - 4")
  end

  def test_arguments_are_joined
    r = calc("1", "+", "2")
    assert_in_delta 3, Float(r.out.strip), 1e-9
  end
end
