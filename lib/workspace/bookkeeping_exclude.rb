module Workspace
  # Keeps the files workspace writes for its own bookkeeping out of `git status`
  # and review diffs: its `.workspace-backup-*` copies, and a settings file it
  # created. Both go in the repository's `info/exclude`, never in `.gitignore`.
  #
  # A path git already tracks is never listed, so a tracked
  # `.claude/settings.json` stays visible. Every problem (not a checkout, an
  # unwritable file) is swallowed: the file was written, and a missing exclude
  # line is only noise in `git status`.
  class BookkeepingExclude
    # The one pattern for every backup copy workspace makes.
    BACKUP_PATTERN = "*.workspace-backup-*".freeze

    # @param git [Workspace::Git] finds the checkout and answers `tracked?`
    # @param git_exclude [Workspace::GitExclude] writes `info/exclude`
    def initialize(git:, git_exclude:)
      @git = git
      @git_exclude = git_exclude
    end

    # Lists the backup pattern for the checkout holding +path+.
    #
    # @param path [String] a backup file or the file it was made from
    # @return [Boolean] whether the pattern is listed now
    def backup(path)
      layout = @git.checkout_layout(File.dirname(path))
      return false unless layout&.fetch(:common_dir)

      @git_exclude.add(layout[:toplevel], BACKUP_PATTERN)
    rescue SystemCallError, Workspace::Error
      false
    end

    # Lists a file workspace itself created, unless git tracks it.
    #
    # @param path [String] the new file
    # @return [Boolean] whether the path is listed now
    def created(path)
      layout = @git.checkout_layout(File.dirname(path))
      return false unless layout&.fetch(:common_dir)

      root = File.realpath(layout[:toplevel])
      relative = File.join(File.realpath(File.dirname(path)), File.basename(path)).delete_prefix("#{root}/")
      return false if relative.start_with?("/") || @git.tracked?(layout[:toplevel], relative)

      @git_exclude.add(layout[:toplevel], "/#{relative}")
    rescue SystemCallError, Workspace::Error
      false
    end
  end
end
