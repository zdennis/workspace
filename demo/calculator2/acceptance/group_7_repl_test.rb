require_relative "support"

class Group7ReplTest < Minitest::Test
  include CalcSupport

  def lines(result)
    result.out.gsub("> ", "").split("\n").map(&:strip).reject(&:empty?)
  end

  def test_prompt_and_evaluation
    r = calc(stdin: "1 + 2\nexit\n")
    assert_includes r.out, "> "
    assert_includes lines(r).map { |l| Float(l, exception: false) }, 3.0
  end

  def test_several_lines
    r = calc(stdin: "1 + 2\n6 * 7\nquit\n")
    values = lines(r).map { |l| Float(l, exception: false) }
    assert_includes values, 3.0
    assert_includes values, 42.0
  end

  def test_exit_ends_the_session
    r = calc(stdin: "exit\n1 + 2\n")
    refute_includes lines(r), "3"
  end

  def test_quit_ends_the_session
    r = calc(stdin: "quit\n1 + 2\n")
    refute_includes lines(r), "3"
  end

  def test_end_of_input_ends_the_session
    r = calc(stdin: "1 + 2\n")
    assert_includes lines(r), "3"
    r = calc(stdin: "")
    assert_includes r.out, "> "
  end

  def test_a_bad_line_prints_its_error_and_the_loop_goes_on
    r = calc(stdin: "1 / 0\n6 * 7\nexit\n")
    assert_includes r.out + r.err, "division by zero"
    assert_includes lines(r), "42"
  end
end
