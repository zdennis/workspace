require "fileutils"

module Workspace
  # Lists a path in a repository's `info/exclude`, so a file workspace puts
  # in a checkout doesn't show in `git status` and the repo's own
  # `.gitignore` is left alone. A linked worktree shares the common dir's
  # file, which is the one git reads.
  class GitExclude
    # @param git [Workspace::Git] finds a checkout's common dir
    def initialize(git:)
      @git = git
    end

    # @param worktree [String] the checkout root
    # @param pattern [String] an exclude pattern, e.g. "/.workflow/"
    # @return [Boolean] whether the pattern is listed now; false when +worktree+ is not a git checkout
    # @raise [SystemCallError] if the file can't be written
    def add(worktree, pattern)
      common = @git.common_dir_from_files(worktree)
      return false unless common
      file = File.join(common, "info", "exclude")
      # Read as bytes: the file is the repository's own, in whatever encoding its patterns are.
      text = File.exist?(file) ? File.binread(file) : ""
      return true if text.lines.map(&:chomp).include?(pattern.b)
      FileUtils.mkdir_p(File.dirname(file))
      File.open(file, "ab") { |f| f.write("#{"\n" unless text.empty? || text.end_with?("\n")}#{pattern}\n") }
      true
    end
  end
end
