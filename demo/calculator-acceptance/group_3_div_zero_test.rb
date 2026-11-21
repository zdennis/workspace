require_relative "support"

class Group3DivZeroTest < Minitest::Test
  include CalcSupport

  def test_division_by_zero_reports_an_error
    assert_division_by_zero "1 / 0"
  end

  def test_division_by_zero_prints_nothing_on_stdout
    assert_equal "", calc("1 / 0").out.strip
  end

  def test_division_by_zero_with_decimals
    assert_division_by_zero "2.5 / 0"
  end

  def test_division_still_works
    assert_value 0.5, "1 / 2"
  end
end
