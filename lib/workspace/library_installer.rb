require "fileutils"

module Workspace
  # Copies a library agent or skill into a checkout, where Claude Code loads
  # it: `.claude/agents/<name>.md` or `.claude/skills/<name>/`. A path the
  # repo tracks is never overwritten. Each copy is listed in the repo's
  # `info/exclude` (the common dir's, for a linked worktree), so the checkout
  # stays clean.
  class LibraryInstaller
    # Where each kind goes, relative to the checkout root.
    DESTINATIONS = {
      "agent" => ->(name) { File.join(".claude", "agents", "#{name}.md") },
      "skill" => ->(name) { File.join(".claude", "skills", name) }
    }.freeze

    # @param git [Workspace::Git] answers whether a path is tracked, and where the common dir is
    def initialize(git:)
      @git = git
    end

    # Copies one entry into +worktree+. An untracked file or directory already
    # there is replaced; a linked entry is copied from the file it points to.
    #
    # @param entry [Hash] from {Workspace::Library#copyable}: "ref", "kind", "name", "scope", "path"
    # @param worktree [String] the checkout root
    # @return [Hash] "ref", "scope", "source" (the library path), "path" (in the checkout) and
    #   "outcome": "copied", "replaced", "unchanged", "skipped_tracked" when the repo tracks the path, or
    #   "skipped_linked" when `.claude` or the kind's directory under it is a symlink
    # @raise [Workspace::Error] when git can't tell whether the path is tracked
    def copy(entry, worktree:)
      rel = DESTINATIONS.fetch(entry["kind"]).call(entry["name"])
      dest = File.join(worktree, rel)
      result = {"ref" => entry["ref"], "scope" => entry["scope"], "source" => entry["path"], "path" => dest}
      # Through a linked directory, git can't see what is tracked, and the copy
      # would land outside the checkout.
      return result.merge("outcome" => "skipped_linked") if linked_parent?(worktree, rel)
      return result.merge("outcome" => "skipped_tracked") if @git.tracked?(worktree, rel)

      exists = File.exist?(dest) || File.symlink?(dest)
      if exists && !File.symlink?(dest) && LibraryStore.snapshot(dest) == LibraryStore.snapshot(entry["path"])
        outcome = "unchanged"
      else
        place(entry["path"], dest)
        outcome = exists ? "replaced" : "copied"
      end
      exclude(worktree, "/#{rel}#{"/" if entry["kind"] == "skill"}")
      result.merge("outcome" => outcome)
    end

    private

    # Whether `.claude` or `.claude/<kind>s` under +worktree+ is a symlink.
    def linked_parent?(worktree, rel)
      parts = File.dirname(rel).split(File::SEPARATOR)
      (1..parts.size).any? { |n| File.symlink?(File.join(worktree, *parts.first(n))) }
    end

    # Copies into a temp path beside +dest+, then moves it into place. What
    # was there is moved aside first and put back if the move fails.
    def place(source, dest)
      FileUtils.mkdir_p(File.dirname(dest))
      tmp = "#{dest}.tmp-#{Process.pid}"
      FileUtils.cp_r(File.realpath(source), tmp)
      if File.exist?(dest) || File.symlink?(dest)
        old = "#{dest}.old-#{Process.pid}"
        File.rename(dest, old)
      end
      begin
        File.rename(tmp, dest)
      rescue SystemCallError
        File.rename(old, dest) if old
        old = nil
        raise
      end
      LibraryStore.remove(old) if old
    ensure
      LibraryStore.remove(tmp) if tmp && (File.exist?(tmp) || File.symlink?(tmp))
    end

    def exclude(worktree, pattern)
      common = @git.common_dir_from_files(worktree)
      return unless common
      file = File.join(common, "info", "exclude")
      text = File.exist?(file) ? File.read(file) : ""
      return if text.lines.map(&:chomp).include?(pattern)
      FileUtils.mkdir_p(File.dirname(file))
      File.open(file, "a") { |f| f.write("#{"\n" unless text.empty? || text.end_with?("\n")}#{pattern}\n") }
    end
  end
end
