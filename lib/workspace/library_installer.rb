require "fileutils"

module Workspace
  # Copies a library agent or skill into a checkout, where the coding agent loads
  # it: `<agents dir>/<name>.md` or `<skills dir>/<name>/`, `.claude/agents` and
  # `.claude/skills` unless `library.install.*` says otherwise. A path the
  # repo tracks is never overwritten. Each copy is listed in the repo's
  # `info/exclude` (the common dir's, for a linked worktree), so the checkout
  # stays clean.
  class LibraryInstaller
    # @param git [Workspace::Git] answers whether a path is tracked, and where the common dir is
    # @param dirs [Workspace::LibraryInstallDirs] where each kind goes
    def initialize(git:, dirs: LibraryInstallDirs.new)
      @git = git
      @dirs = dirs
    end

    # @param kind [String] "agent" or "skill"
    # @param name [String] a valid library name
    # @param project [String, nil] the workspace or project whose `library.install.*` values apply
    # @return [String] where the copy goes, relative to the checkout root
    def relative_path(kind, name, project: nil)
      File.join(@dirs.relative(kind, project: project), (kind == "agent") ? "#{name}.md" : name)
    end

    # Copies one entry into +worktree+. An untracked file or directory already
    # there is replaced; a linked entry is copied from the file it points to.
    #
    # @param entry [Hash] from {Workspace::Library#copyable}: "ref", "kind", "name", "scope", "path"
    # @param worktree [String] the checkout root
    # @param project [String, nil] the workspace or project whose `library.install.*` values apply
    # @return [Hash] "ref", "scope", "source" (the library path), "path" (in the checkout) and
    #   "outcome": "copied", "replaced", "unchanged", "skipped_tracked" when the repo tracks the path, or
    #   "skipped_linked" when the install directory or a parent of it is a symlink
    # @raise [Workspace::Error] when git can't tell whether the path is tracked
    def copy(entry, worktree:, project: nil)
      rel = relative_path(entry["kind"], entry["name"], project: project)
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
    # @param project [String, nil] the workspace or project whose `library.install.*` values apply
    # @param force [Boolean] replace different content
    # @param dry_run [Boolean] report and write nothing
    # @return [Hash] "result" ("installed", "unchanged", or "would_install" on a dry run) and "path"
    # @raise [Workspace::Error] codes `library_install_exists`, `path_tracked`, `library_path_outside`
    def install(entry, worktree:, project: nil, force: false, dry_run: false)
      rel = relative_path(entry["kind"], entry["name"], project: project)
      dest = File.join(worktree, rel)
      guard!(worktree, rel, entry["ref"], dest)
      outcome = write_copy(entry, dest, force: force, dry_run: dry_run)
      exclude(worktree, "/#{rel}#{"/" if entry["kind"] == "skill"}") if outcome == "installed"
      {"result" => outcome, "path" => dest}
    end

    # Copies one entry into the user-level directory (`library.install.user_skills_dir`
    # or `user_agents_dir`), for `library install --user`. There is no git and no
    # `info/exclude` there; the exists and `--force` rule is the same as {#install}.
    #
    # @param entry [Hash] from {Workspace::Library#copyable}
    # @param force [Boolean] replace different content
    # @param dry_run [Boolean] report and write nothing
    # @return [Hash] "result" ("installed", "unchanged", or "would_install" on a dry run) and "path"
    # @raise [Workspace::Error] codes `library_install_exists`, `invalid_library_install_dir`
    def install_user(entry, force: false, dry_run: false)
      dest = user_path(entry["kind"], entry["name"])
      {"result" => write_copy(entry, dest, force: force, dry_run: dry_run), "path" => dest}
    end

    # Removes the worktree copy of a library agent or skill, and nothing else:
    # the library entry and the `info/exclude` line stay (the line is harmless,
    # and a later install needs it).
    #
    # @param kind [String] "agent" or "skill"
    # @param name [String] a valid library name
    # @param worktree [String] the checkout root
    # @param project [String, nil] the workspace or project whose `library.install.*` values apply
    # @param dry_run [Boolean] report and write nothing
    # @param entry [Hash, nil] the library entry the copy came from; when given, a copy
    #   that differs from it (or is a symlink) is refused unless +force+
    # @param force [Boolean] remove a locally modified copy
    # @return [Hash] "result" ("removed", "absent", or "would_remove" on a dry run) and "path"
    # @raise [Workspace::Error] codes `library_uninstall_modified`, `path_tracked`, `library_path_outside`
    def uninstall(kind, name, worktree:, project: nil, dry_run: false, entry: nil, force: false)
      rel = relative_path(kind, name, project: project)
      dest = File.join(worktree, rel)
      guard!(worktree, rel, "#{kind}/#{name}", dest)
      remove_copy(dest, entry: entry, force: force, dry_run: dry_run)
    end

    # Removes the user-level copy of a library agent or skill (the counterpart of
    # {#install_user}), under the same rules as {#uninstall}. There is no git and
    # no `info/exclude` line to leave behind.
    #
    # @param kind [String] "agent" or "skill"
    # @param name [String] a valid library name
    # @param dry_run [Boolean] report and write nothing
    # @param entry [Hash, nil] the library entry the copy came from; see {#uninstall}
    # @param force [Boolean] remove a locally modified copy
    # @return [Hash] "result" ("removed", "absent", or "would_remove" on a dry run) and "path"
    # @raise [Workspace::Error] codes `library_uninstall_modified`, `library_path_outside`, `invalid_library_install_dir`
    def uninstall_user(kind, name, dry_run: false, entry: nil, force: false)
      remove_copy(user_path(kind, name), entry: entry, force: force, dry_run: dry_run)
    end

    # @param kind [String] "agent" or "skill"
    # @param name [String] a valid library name
    # @return [String] where `install --user` puts the copy
    # @raise [Workspace::Error] codes `library_path_outside`, `invalid_library_install_dir`
    def user_path(kind, name)
      dir = @dirs.user(kind)
      dest = File.join(dir, (kind == "agent") ? "#{name}.md" : name)
      unless File.dirname(File.expand_path(dest)) == File.expand_path(dir)
        raise Error.new("#{dest} is not directly under #{dir}; #{kind}/#{name} was not touched.",
          code: "library_path_outside", details: {"ref" => "#{kind}/#{name}", "path" => dest})
      end
      dest
    end

    # The copies of one kind in a workspace's install directory that `install`
    # (or `start --skill/--agent`) may have made: an entry whose name is a valid
    # library name and that is either named in the repo's `info/exclude` (which
    # install writes and uninstall leaves) or in +known+. Hand-made items stay out.
    # Nothing is listed through a symlinked install directory.
    #
    # @param kind [String] "agent" or "skill"
    # @param worktree [String] the checkout root
    # @param project [String, nil] the workspace whose `library.install.*` values apply
    # @param known [Array<String>] names of library entries of this kind, which count without an exclude line
    # @return [Array<Hash>] "name" and "path", sorted by name
    # @raise [Workspace::Error] code `invalid_library_install_dir`
    def installed(kind, worktree:, project: nil, known: [])
      rel_dir = @dirs.relative(kind, project: project)
      return [] if linked_parent?(worktree, File.join(rel_dir, "x"))
      listed = excluded_patterns(worktree)
      scan(File.join(worktree, rel_dir), kind) do |name|
        known.include?(name) || listed.include?("/#{relative_path(kind, name, project: project)}#{"/" if kind == "skill"}")
      end
    end

    # The copies of one kind in the user-level directory whose names are in +known+
    # (there is no `info/exclude` there, so a library entry's name is the only mark).
    #
    # @param kind [String] "agent" or "skill"
    # @param known [Array<String>] names of library entries of this kind
    # @return [Array<Hash>] "name" and "path", sorted by name
    # @raise [Workspace::Error] code `invalid_library_install_dir`
    def installed_user(kind, known: [])
      scan(@dirs.user(kind), kind) { |name| known.include?(name) }
    end

    # Whether a copy differs from the library entry it came from: a symlink, or
    # other content. The test `uninstall` refuses on without `--force`.
    #
    # @param path [String] the installed copy
    # @param entry [Hash] with "path", the library entry's file or directory
    # @return [Boolean]
    def modified?(path, entry)
      File.symlink?(path) || LibraryStore.snapshot(path) != LibraryStore.snapshot(entry["path"])
    end

    private

    def remove_copy(dest, entry:, force:, dry_run:)
      return {"result" => "absent", "path" => dest} unless File.exist?(dest) || File.symlink?(dest)
      if entry && !force && modified?(dest, entry)
        raise Error.new("#{dest} differs from #{entry["ref"]} in the library, so it may hold local edits; pass --force to remove it.",
          code: "library_uninstall_modified", details: {"ref" => entry["ref"], "path" => dest},
          retry_with: {"flags" => ["--force"], "destructive" => true})
      end
      return {"result" => "would_remove", "path" => dest} if dry_run
      LibraryStore.remove(dest)
      {"result" => "removed", "path" => dest}
    end

    def scan(dir, kind)
      return [] unless File.directory?(dir)
      children = begin
        Dir.children(dir)
      rescue SystemCallError
        return []
      end
      children.filter_map do |child|
        next if kind == "agent" && !child.end_with?(".md")
        name = (kind == "agent") ? child.delete_suffix(".md") : child
        next unless name.match?(LibraryStore::NAME) && yield(name)
        path = File.join(dir, child)
        next unless (kind == "agent") ? (File.file?(path) || File.symlink?(path)) : (File.directory?(path) || File.symlink?(path))
        {"name" => name, "path" => path}
      end.sort_by { |c| c["name"] }
    end

    def excluded_patterns(worktree)
      common = @git.common_dir_from_files(worktree)
      file = common && File.join(common, "info", "exclude")
      (file && File.file?(file)) ? File.read(file).lines.map(&:strip) : []
    rescue SystemCallError
      []
    end

    # The shared step of both installs: "unchanged" when the same content is
    # there, `library_install_exists` over different content without +force+,
    # else "would_install" or the copy ("installed").
    def write_copy(entry, dest, force:, dry_run:)
      exists = File.exist?(dest) || File.symlink?(dest)
      return "unchanged" if exists && !File.symlink?(dest) && LibraryStore.snapshot(dest) == LibraryStore.snapshot(entry["path"])
      if exists && !force
        raise Error.new("#{dest} exists with different content than #{entry["ref"]}; pass --force to replace it.",
          code: "library_install_exists", details: {"ref" => entry["ref"], "path" => dest},
          retry_with: {"flags" => ["--force"], "destructive" => true})
      end
      return "would_install" if dry_run
      place(entry["path"], dest)
      "installed"
    end

    # Refuses a destination that is not directly under the install directory
    # (a name that climbs out), under a symlinked directory, or that the repo tracks.
    def guard!(worktree, rel, ref, dest)
      outside = File.dirname(File.expand_path(dest)) != File.join(File.expand_path(worktree), File.dirname(rel))
      if outside
        raise Error.new("#{dest} is not directly under #{File.join(worktree, File.dirname(rel))}; #{ref} was not touched.",
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

    # Whether the install directory, or a directory above it, under +worktree+ is a symlink.
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
