require_relative "support"

class Group2MulDivTest < Minitest::Test
  include CalcSupport

  def test_multiplication
    assert_value 42, "6 * 7"
  end

  def test_division
    assert_value 4.5, "9 / 2"
  end

  def test_decimals_and_spaces
    assert_value 3, "1.5*2"
    assert_value 0.25, "0.5/2"
  end

  def test_negative_operands
    assert_value(-42, "-6 * 7")
    assert_value 4.5, "-9 / -2"
  end
end
