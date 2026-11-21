# A command-line calculator. The work queue's workflow runs build it out, one feature at a time.
module Calc
  class Unsupported < StandardError; end

  # @param expression [String] e.g. "1 + 2"
  # @return [Numeric]
  # @raise [Unsupported] for every expression, until a run teaches the calculator something
  def self.evaluate(expression)
    raise Unsupported, "unsupported: #{expression}"
  end
end
