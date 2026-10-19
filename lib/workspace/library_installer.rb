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

    # Copies one entry into +worktree+ for `library install`. Unlike {#copy}, a
    # copy that differs from the library entry is refused unless +force+, and a
    # tracked path or a symlinked directory is an error, not a note.
    #
    # @param entry [Hash] from {Workspace::Library#copyable}
    # @param worktree [String] the checkout root
    # @param force [Boolean] replace different content
    # @param dry_run [Boolean] report and write nothing
    # @return [Hash] "result" ("installed", "unchanged", or "would_install" on a dry run) and "path"
    # @raise [Workspace::Error] codes `library_install_exists`, `path_tracked`, `library_path_outside`
    def install(entry, worktree:, force: false, dry_run: false)
      rel = DESTINATIONS.fetch(entry["kind"]).call(entry["name"])
      dest = File.join(worktree, rel)
      guard!(worktree, rel, entry["ref"], dest)
      exists = File.exist?(dest) || File.symlink?(dest)
      if exists && !File.symlink?(dest) && LibraryStore.snapshot(dest) == LibraryStore.snapshot(entry["path"])
        return {"result" => "unchanged", "path" => dest}
      end
      if exists && !force
        raise Error.new("#{dest} exists with different content than #{entry["ref"]}; pass --force to replace it.",
          code: "library_install_exists", details: {"ref" => entry["ref"], "path" => dest},
          retry_with: {"flags" => ["--force"], "destructive" => true})
      end
      return {"result" => "would_install", "path" => dest} if dry_run
      place(entry["path"], dest)
      exclude(worktree, "/#{rel}#{"/" if entry["kind"] == "skill"}")
      {"result" => "installed", "path" => dest}
    end

    # Removes the worktree copy of a library agent or skill, and nothing else:
    # the library entry and the `info/exclude` line stay (the line is harmless,
    # and a later install needs it).
    #
    # @param kind [String] "agent" or "skill"
    # @param name [String] a valid library name
    # @param worktree [String] the checkout root
    # @param dry_run [Boolean] report and write nothing
    # @param entry [Hash, nil] the library entry the copy came from; when given, a copy
    #   that differs from it (or is a symlink) is refused unless +force+
    # @param force [Boolean] remove a locally modified copy
    # @return [Hash] "result" ("removed", "absent", or "would_remove" on a dry run) and "path"
    # @raise [Workspace::Error] codes `library_uninstall_modified`, `path_tracked`, `library_path_outside`
    def uninstall(kind, name, worktree:, dry_run: false, entry: nil, force: false)
      rel = DESTINATIONS.fetch(kind).call(name)
      dest = File.join(worktree, rel)
      guard!(worktree, rel, "#{kind}/#{name}", dest)
      return {"result" => "absent", "path" => dest} unless File.exist?(dest) || File.symlink?(dest)
      if entry && !force && (File.symlink?(dest) || LibraryStore.snapshot(dest) != LibraryStore.snapshot(entry["path"]))
        raise Error.new("#{dest} differs from #{entry["ref"]} in the library, so it may hold local edits; pass --force to remove it.",
          code: "library_uninstall_modified", details: {"ref" => entry["ref"], "path" => dest},
          retry_with: {"flags" => ["--force"], "destructive" => true})
      end
      return {"result" => "would_remove", "path" => dest} if dry_run
      LibraryStore.remove(dest)
      {"result" => "removed", "path" => dest}
    end

    private

    # Refuses a destination that is not directly under the checkout's
    # `.claude/skills/` or `.claude/agents/` (a symlinked `.claude` or kind
    # directory, or a name that climbs out), or that the repo tracks.
    def guard!(worktree, rel, ref, dest)
      parent = File.dirname(rel)
      allowed = %w[skills agents].map { |d| File.join(".claude", d) }
      outside = !allowed.include?(parent) ||
        File.dirname(File.expand_path(dest)) != File.join(File.expand_path(worktree), parent)
      if outside
        raise Error.new("#{dest} is not under #{worktree}/.claude/skills/ or .claude/agents/; #{ref} was not touched.",
          code: "library_path_outside", details: {"ref" => ref, "path" => dest})
      end
      if linked_parent?(worktree, rel)
        raise Error.new("#{dest} is under a symlinked directory, where git can't tell what it tracks; #{ref} was not touched.",
          code: "path_linked", details: {"ref" => ref, "path" => dest})
      end
      return unless @git.tracked?(worktree, rel)
      raise Error.new("The repo tracks #{dest}; #{ref} was not touched.",
        code: "path_tracked", details: {"ref" => ref, "path" => dest})
    end

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
