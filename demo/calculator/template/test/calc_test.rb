require "minitest/autorun"
require_relative "../lib/calc"

class CalcTest < Minitest::Test
  def test_smoke_the_library_loads
    assert_kind_of Module, Calc
  end
end
