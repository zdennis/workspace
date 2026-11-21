require_relative "support"

class Group6JsonTest < Minitest::Test
  include CalcSupport

  def test_json_result
    r = calc("--json", "1 + 2")
    assert r.success?, r.err
    assert_equal({"expression" => "1 + 2", "result" => 3}, JSON.parse(r.out))
  end

  def test_json_result_with_a_decimal
    r = calc("--json", "9 / 2")
    assert_equal({"expression" => "9 / 2", "result" => 4.5}, JSON.parse(r.out))
  end

  def test_json_error_goes_to_stdout_and_exits_1
    r = calc("--json", "1 / 0")
    assert_equal 1, r.code
    assert_equal({"expression" => "1 / 0", "error" => "division by zero"}, JSON.parse(r.out))
  end

  def test_output_without_json_is_as_before
    assert_value 3, "1 + 2"
    assert_division_by_zero "1 / 0"
  end
end
