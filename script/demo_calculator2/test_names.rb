# The one scanner for test method names in a calc_test.rb, shared by the merge driver and the lane harness.
module MergeTestMethods
  METHOD_START = /\A  def (test_\w+)/

  # @return [Array<String>] the test method names the text defines more than once, in order of first appearance
  def self.duplicate_names(text)
    names = text.lines.filter_map { |line| line[METHOD_START, 1] }
    counts = names.tally
    names.uniq.select { |name| counts[name] > 1 }
  end
end
