# frozen_string_literal: true

# The shared fake of the questions callers ask Workspace::Git about a checkout. Each answer is a
# String (given for every path) or a Hash from the path or directory asked about; nothing starts a
# process, and an unknown path answers nil as real git does on failure. `fake_contract_spec` checks
# that it accepts every call the real class accepts.
#
#   FakeGit.new(remote_url: "git@h:o/r.git")
#   FakeGit.new(paths: {"/repo" => {git_dir: ".git"}}, head_name: {"/repo" => "main"})
class FakeGit
  CONTROL_METHODS = %i[calls].freeze

  # @return [Array<Array>] each call as `[method, *arguments]`
  attr_reader :calls

  # @param remote_url [String, Hash, nil] origin's url per path
  # @param paths [Hash{String=>Hash{Symbol=>String}}] `path_of` answers per directory, then `:git_dir`, `:common_dir`, `:toplevel`
  # @param head_name [String, Hash, nil] `head_name` per directory
  # @param current_branch_name [String, Hash, nil] `current_branch_name` per directory
  def initialize(remote_url: nil, paths: {}, head_name: nil, current_branch_name: nil)
    @remote_url = remote_url
    @paths = paths
    @head_name = head_name
    @current_branch_name = current_branch_name
    @calls = []
  end

  def remote_url(path) = answer(:remote_url, @remote_url, path)

  def path_of(dir, what)
    @calls << [:path_of, dir, what]
    @paths.fetch(dir, {})[what]
  end

  def head_name(dir) = answer(:head_name, @head_name, dir)

  def current_branch_name(dir) = answer(:current_branch_name, @current_branch_name, dir)

  private

  def answer(method, scripted, argument)
    @calls << [method, argument]
    scripted.is_a?(Hash) ? scripted[argument] : scripted
  end
end
