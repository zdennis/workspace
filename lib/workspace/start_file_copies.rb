module Workspace
  # Copies the parent project's `start.copy_files` — gitignored config files such
  # as `.env` or `config/database.yml` — from the main checkout into a worktree,
  # once, when `start` sets the worktree up. A destination that already exists,
  # as any of a plain file, a directory or a symlink (even a dangling one), is
  # never overwritten, so a re-run of `start` tops up missing files without
  # touching branch-local edits; safety comes from that, not from gating on a
  # newly created worktree.
  #
  # It never raises for a problem with the copy itself: each one comes back as a
  # warning, because missing config files are not worth a failed start.
  class StartFileCopies
    # @param config_resolver [Workspace::ConfigResolver, nil] nil reads no config: nothing is ever copied
    def initialize(config_resolver: nil)
      @config_resolver = config_resolver
    end

    # @param project_name [String] the parent project whose `start.copy_files` applies; its own layers
    #   only (global, project), never a worktree's — the worktree is being created and its layer is empty
    # @param source_root [String] the main checkout the files come from
    # @param worktree_root [String] the worktree the files go into
    # @return [Hash] `"copied"` and `"skipped"` (checkout-relative paths, in list order; `"skipped"`
    #   also names a file that appeared at the destination between the exists-check and the exclusive
    #   create) and `"warnings"` (sentences, empty when all went well)
    def call(project_name:, source_root:, worktree_root:)
      result = {"copied" => [], "skipped" => [], "warnings" => []}
      paths = read_paths(project_name, result["warnings"])
      paths.each { |rel| copy_one(rel, source_root, worktree_root, result) }
      result
    end

    private

    # The parsed key, or [] with a warning: a hand-edited value goes through the
    # parser here, the same one `config set` uses, so it can never reach the copy.
    def read_paths(project_name, warnings)
      return [] unless @config_resolver
      winner = @config_resolver.view(workspace: project_name).resolve("start.copy_files").winner
      return [] unless winner
      ConfigSchema.parse("start.copy_files", winner.value)
    rescue ArgumentError => e
      warnings << "start.copy_files is not valid (#{e.message}). Fix it with: workspace config set start.copy_files VALUE"
      []
    rescue Workspace::Error, SystemCallError => e
      warnings << "could not read start.copy_files: #{e.message}"
      []
    end

    def copy_one(rel, source_root, worktree_root, result)
      dest = File.join(worktree_root, rel)
      if dest_exists?(dest)
        result["skipped"] << rel
        return
      end
      # The source must be a regular file, never a symlink (a symlinked final
      # component is not followed) — but a symlinked directory component in the
      # main checkout is followed, since that is the person's own checkout.
      stat = File.lstat(File.join(source_root, rel))
      unless stat.file?
        result["warnings"] << "#{rel} in the main checkout is not a regular file; it was not copied."
        return
      end
      unless inside_worktree?(dest, worktree_root)
        result["warnings"] << "#{rel} would not land inside the worktree; it was not copied."
        return
      end
      write(rel, File.join(source_root, rel), dest, stat.mode & 0o7777, result)
    rescue Errno::ENOENT
      result["warnings"] << "#{rel} is missing from the main checkout; it was not copied."
    rescue SystemCallError, Workspace::Error => e
      # This rescue and the one in {#write} are two levels on purpose: this one
      # covers the checks (a source that cannot be read, a containment check
      # that failed to answer), that one the copy itself, which must clean up a
      # partial destination first.
      result["warnings"] << copy_failed(rel, e)
    end

    # `lstat`, never `exist?`: a symlink at the destination — even a dangling one —
    # counts as existing and is never written through.
    def dest_exists?(dest)
      File.lstat(dest)
      true
    rescue SystemCallError
      false
    end

    # The destination's parent may not exist yet, so walk up to the deepest
    # ancestor that answers `lstat` (a symlink answers, so the walk never steps
    # past one) and check its realpath stays inside the worktree — before any
    # `mkdir_p`, so a symlinked directory component cannot make the copy land
    # outside the worktree.
    def inside_worktree?(dest, worktree_root)
      worktree_real = File.realpath(worktree_root)
      dir = File.dirname(dest)
      dir = File.dirname(dir) until lstat_answers?(dir)
      ancestor_real = File.realpath(dir)
      ancestor_real == worktree_real || ancestor_real.start_with?(worktree_real + File::SEPARATOR)
    rescue SystemCallError
      false
    end

    def lstat_answers?(dir)
      File.lstat(dir)
      true
    rescue SystemCallError
      false
    end

    def write(rel, source, dest, mode, result)
      FileUtils.mkdir_p(File.dirname(dest))
      begin
        # The exclusive create keeps a file that appears between the exists-check
        # and now from being clobbered (EEXIST → skipped), and `perm:` holds the
        # source's mode at creation, so a 0600 `.env` is never even briefly
        # readable at the umask default.
        File.open(dest, File::CREAT | File::EXCL | File::WRONLY, perm: mode) { |out| IO.copy_stream(source, out) }
        File.chmod(mode, dest)
        result["copied"] << rel
      rescue Errno::EEXIST
        result["skipped"] << rel
      rescue SystemCallError, IOError => e
        # A partial file must not masquerade as "exists" and be skipped forever.
        FileUtils.rm_f(dest)
        result["warnings"] << copy_failed(rel, e)
      end
    end

    def copy_failed(rel, error)
      "could not copy #{rel}: #{error.message}"
    end
  end
end
