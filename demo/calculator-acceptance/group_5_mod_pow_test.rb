require_relative "support"

class Group5ModPowTest < Minitest::Test
  include CalcSupport

  def test_modulo
    assert_value 1, "7 % 3"
  end

  def test_exponent_is_right_associative
    assert_value 512, "2 ** 3 ** 2"
  end

  def test_exponent
    assert_value 8, "2 ** 3"
  end

  def test_exponent_binds_tighter_than_multiplication
    assert_value 18, "2 * 3 ** 2"
  end

  def test_modulo_has_the_precedence_of_multiplication
    assert_value 3, "1 + 6 % 4"
    assert_value 2, "2 * 5 % 4"
  end

  def test_modulo_by_zero_is_the_division_error
    assert_division_by_zero "5 % 0"
  end
end
