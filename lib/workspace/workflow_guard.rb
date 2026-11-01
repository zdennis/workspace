require "digest"
require "timeout"

module Workspace
  # The engine's check that a step left a checkout as it found it: no commit,
  # no change to a tracked file, no git operation left running, and no change
  # to the repository's config, hooks, replace refs or hidden-file flags (the
  # places a tracked change could be hidden or a command planted). It is not
  # a `status:` shell line because a shell line reads the same config it is
  # checking; here every git call is the git found when workspace was built,
  # ignores the user's and the system's config, drops every inherited `GIT_*`
  # variable, ignores replace refs, and runs with fsmonitor and hooks off.
  #
  # It is a tripwire for an agent that was misled or made a mistake, not a
  # boundary against one that means harm: a process of the same user can edit
  # the run file, start a process outside the pane, or forge the index's stat
  # data. It does not look at untracked files, submodules (the status runs with
  # `--ignore-submodules=all`) or anything outside the checkout.
  #
  # A run records its base ({#base}) when it starts: the HEAD commit and a
  # snapshot of the config, hooks, replace refs and hidden-file flags. {#check}
  # compares the checkout with it and answers with the first code that fails,
  # in this order: `no_commit`, `head_moved`, `operation_in_progress`,
  # `config_changed`, `hooks_changed`, `hidden_changed`, `tracked_changed`. The
  # scope `config` checks `no_commit`, then the config, hooks and hidden flags.
  # A part git can't read at check time is a failure, whatever it was at the start.

  class WorkflowGuard
    # Seconds one git call may take.
    GIT_TIMEOUT = 30

    # Seconds {#head} waits for git: it runs under a run's lock, so it must stay short.
    HEAD_TIMEOUT = 5

    # Most stdout one git call is read for.
    MAX_OUTPUT = 32 * 1024 * 1024

    # Most paths named in a `tracked_changed` answer.
    MAX_PATHS = 20

    # The codes {#check} answers with, in the order it looks for them.
    CODES = %w[no_commit head_moved operation_in_progress config_changed hooks_changed hidden_changed tracked_changed].freeze

    # Directories git keeps while a rebase is stopped.
    REBASE_DIRS = %w[rebase-merge rebase-apply].freeze

    # What every git call is given, over the environment with its `GIT_*` removed.
    HARDENED_ENV = {"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_OPTIONAL_LOCKS" => "0",
                    "GIT_NO_REPLACE_OBJECTS" => "1"}.freeze

    # Options before every git subcommand.
    HARDENED_OPTIONS = %w[-c core.fsmonitor=false].freeze

    # Turns hooks off for the git calls that could run one.
    NO_HOOKS = %w[-c core.hooksPath=/dev/null].freeze

    # @param runner [#call] runs one command like {Workspace::TimedProcess.run}
    # @param git_path [String] the git to run (`build_cli` gives the absolute path found once on PATH)
    def initialize(runner: Workspace::TimedProcess.method(:run), git_path: "git")
      @runner = runner
      @git_path = git_path
      @attr_source = nil
    end

    # @param worktree [String] a checkout
    # @return [Hash{String=>Object}] "base_sha" (nil on an unborn branch or when git can't answer)
    #   and "base_guard" ("config_sha256", "hooks_sha256", "hidden_sha256"; each nil when unreadable)
    def base(worktree)
      {"base_sha" => head(worktree), "base_guard" => snapshot(worktree)}
    end

    # @param worktree [String] a checkout
    # @return [Hash{String=>String, nil}] the SHA-256 of the common dir's `config`, the
    #   worktree's `config.worktree`, every linked worktree's `config.worktree`, `info/attributes`
    #   and the `refs/replace/` refs; of the effective hooks directory (the repository config's
    #   `core.hooksPath`, else the common dir's `hooks`) over sorted relative paths, modes,
    #   contents and symlink targets; and of the `git ls-files -v` lines tagged lowercase
    #   (assume-unchanged) or `S` (skip-worktree). A part that can't be read is nil
    def snapshot(worktree)
      {"config_sha256" => config_digest(worktree), "hooks_sha256" => hooks_digest(worktree), "hidden_sha256" => hidden_digest(worktree)}
    end

    # @param worktree [String] a checkout
    # @param base [Hash{String=>Object}] {#base}'s answer, or a run, which holds the same keys
    # @param scope [String] "unchanged" (everything) or "config" (config, hooks and hidden flags only)
    # @return [Hash{String=>Object}, nil] nil when the checkout passes; else "code" (see {CODES}),
    #   "paths" (up to {MAX_PATHS}, for `tracked_changed`; empty for the other codes), and
    #   "base_sha"/"head" for `head_moved`
    def check(worktree, base, scope)
      base_sha = base["base_sha"]
      current = head(worktree)
      return failure("no_commit") if base_sha.nil? || current.nil?
      if scope == "unchanged"
        return failure("head_moved", "base_sha" => base_sha, "head" => current) if current != base_sha
        return failure("operation_in_progress") if operation_in_progress?(worktree)
      end
      %w[config hooks hidden].each do |part|
        now = snapshot_part(worktree, part)
        return failure("#{part}_changed") if now.nil? || now != base.dig("base_guard", "#{part}_sha256")
      end
      return nil unless scope == "unchanged"
      paths = dirty_paths(worktree)
      return failure("tracked_changed", "paths" => paths || []) if paths.nil? || paths.any?
      nil
    end

    # Never raises: a checkout that is gone, a timeout and a failed git all read nil.
    #
    # @param worktree [String] a checkout
    # @return [String, nil] the full commit id `git rev-parse` answers for HEAD in the path (a checkout that lost its `.git`
    #   inside another repository reads that repository's HEAD); nil on an unborn branch, past {HEAD_TIMEOUT}, or when git cannot answer
    def head(worktree)
      out, ok = run_git(worktree, "rev-parse", "--verify", "--quiet", "HEAD^{commit}", timeout: HEAD_TIMEOUT)
      ok ? out.strip : nil
    end

    # Counts the commits made on HEAD's first-parent line since `base`, merges left out, under {HEAD_TIMEOUT}
    # (`rev-list --count --first-parent --no-merges`), leaving out any commit reachable from another local or
    # remote-tracking branch (this branch aside, and its upstream when that is a remote-tracking branch that is not the
    # remote's default branch under another name), so a merge, fast-forward or rebase onto
    # another branch brings nothing in. When `base` is
    # not an ancestor of HEAD (history was rewritten) nothing is counted. An empty commit still counts. Never raises.
    #
    # @param worktree [String] a checkout
    # @param base [String, nil] a full commit id (hex only, so it can't be read as an option)
    # @return [Integer, Symbol, nil] the count; `:history_rewritten` when `base` is not an ancestor of HEAD; nil when
    #   `base` is not a commit id git knows here, or git can't answer in time
    def commits_since(worktree, base)
      return nil unless base.is_a?(String) && base.match?(/\A\h{40}(\h{24})?\z/)
      _, ancestor, code = run_git(worktree, "merge-base", "--is-ancestor", base, "HEAD", timeout: HEAD_TIMEOUT)
      return :history_rewritten if !ancestor && code == 1
      return nil unless ancestor
      excludes = own_ref_excludes(worktree)
      return nil unless excludes
      out, ok = run_git(worktree, "rev-list", "--count", "--first-parent", "--no-merges", "#{base}..HEAD", "--not",
        *excludes[:branches], "--branches", *excludes[:remotes], "--remotes", timeout: HEAD_TIMEOUT)
      (ok && out.strip.match?(/\A\d+\z/)) ? out.strip.to_i : nil
    end

    # The `--exclude` options that keep this branch, and its upstream when that holds this branch's work, in the
    # count (`rev-list` matches them without the `refs/heads/` or `refs/remotes/` prefix). A detached HEAD excludes nothing.
    #
    # @return [Hash{Symbol=>Array<String>}, nil] nil when git can't answer
    def own_ref_excludes(worktree)
      ref, ok, code = run_git(worktree, "symbolic-ref", "-q", "HEAD", timeout: HEAD_TIMEOUT)
      return {branches: [], remotes: []} if !ok && code == 1
      return nil unless ok
      ref = ref.strip
      return nil unless ref.start_with?("refs/heads/")
      name = ref.delete_prefix("refs/heads/")
      upstream = own_upstream_name(worktree, ref, name)
      return nil unless upstream
      {branches: ["--exclude=#{name}"], remotes: upstream.empty? ? [] : ["--exclude=#{upstream}"]}
    end
    private :own_ref_excludes

    # The upstream of `ref` as a `rev-list --exclude` name, only when it is a remote-tracking branch that holds this
    # branch's work. A local upstream, or the remote's default branch under another name, is a shared base and is not
    # exempt; neither is an upstream whose remote can't be read (that undercounts, which is the safe direction).
    #
    # @return [String, nil] the name, "" for none; nil when git can't answer
    def own_upstream_name(worktree, ref, name)
      out, ok = run_git(worktree, "for-each-ref", "--format=%(upstream)%0a%(upstream:remotename)%0a%(upstream:remoteref)",
        ref, timeout: HEAD_TIMEOUT)
      return nil unless ok
      upstream, remote, remote_ref = out.split("\n", 3).map(&:strip)
      return "" unless upstream.to_s.start_with?("refs/remotes/")
      return "" if remote.to_s.empty? || remote == "." || !remote_ref.to_s.start_with?("refs/heads/")
      branch = remote_ref.delete_prefix("refs/heads/")
      return "" if branch != name && default_branch?(worktree, remote, branch)
      upstream.delete_prefix("refs/remotes/")
    end
    private :own_upstream_name

    # @return [Boolean] whether `branch` is `remote`'s default branch: what `refs/remotes/<remote>/HEAD` names, or
    #   `main` or `master` when that is not set; true when git can't say (not exempt)
    def default_branch?(worktree, remote, branch)
      out, ok, code = run_git(worktree, "symbolic-ref", "-q", "refs/remotes/#{remote}/HEAD", timeout: HEAD_TIMEOUT)
      return out.strip == "refs/remotes/#{remote}/#{branch}" if ok
      (code == 1) ? %w[main master].include?(branch) : true
    end
    private :default_branch?

    # @param worktree [String] a checkout
    # @return [Array<String>, nil] up to {MAX_PATHS} changed tracked paths (staged or not; untracked files,
    #   submodules and `assume-unchanged`/`skip-worktree` files are not seen); nil when git can't answer
    def dirty_paths(worktree)
      out, ok = git(worktree, "status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignore-submodules=all")
      return nil unless ok
      fields = out.split("\0")
      paths = []
      until fields.empty?
        entry = fields.shift
        paths << entry[3..].to_s
        fields.shift if entry.start_with?("R", "C") || entry[1].to_s.match?(/[RC]/)
      end
      paths.first(MAX_PATHS)
    end

    # @param worktree [String] a checkout
    # @return [Boolean] whether a rebase, merge, cherry-pick, revert or bisect is under way; true when git can't say
    def operation_in_progress?(worktree)
      names = Workspace::Git::OPERATION_FILES.keys + REBASE_DIRS
      names.any? do |name|
        path = git_path(worktree, name)
        path.nil? || File.exist?(path)
      end
    end

    private

    def failure(code, extra = {})
      {"code" => code, "paths" => []}.merge(extra)
    end

    def snapshot_part(worktree, part)
      case part
      when "config" then config_digest(worktree)
      when "hooks" then hooks_digest(worktree)
      else hidden_digest(worktree)
      end
    end

    def git_path(worktree, name)
      out, ok = git(worktree, "rev-parse", "--git-path", name)
      return nil unless ok
      File.expand_path(out.chomp, worktree)
    end

    # Feeds each part as bytes followed by a NUL, so no text (a UTF-8 path, a hook's bytes) is ever joined to another encoding.
    def feed(digest, *parts)
      parts.each do |part|
        digest.update(part.to_s.b)
        digest.update("\0")
      end
    end

    def config_digest(worktree)
      paths = %w[config config.worktree info/attributes].map { |name| git_path(worktree, name) }
      return nil if paths.any?(&:nil?)
      common, found = git(worktree, "rev-parse", "--git-common-dir")
      return nil unless found
      linked = File.expand_path(common.chomp, worktree)
      refs, listed = git(worktree, "for-each-ref", "refs/replace/")
      return nil unless listed
      digest = Digest::SHA256.new
      (paths + linked_worktree_configs(linked)).each { |path| feed_file(digest, path) }
      feed(digest, "replace", refs)
      digest.hexdigest
    rescue
      nil
    end

    def linked_worktree_configs(common)
      Dir.glob("*/config.worktree", base: File.join(common, "worktrees")).sort.map { |name| File.join(common, "worktrees", name) }
    rescue SystemCallError
      []
    end

    def feed_file(digest, path)
      stat = File.lstat(path)
      if stat.symlink?
        feed(digest, path, "link", File.readlink(path))
      else
        feed(digest, path, "file")
        digest.update(Digest::SHA256.file(path).digest)
      end
    rescue Errno::ENOENT
      feed(digest, path, "absent")
    end

    def hooks_digest(worktree)
      dir = hooks_dir(worktree)
      return nil unless dir
      digest = Digest::SHA256.new
      feed(digest, dir)
      if File.directory?(dir)
        names = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |name| %w[. ..].include?(File.basename(name)) }
        names.sort_by(&:b).each do |name|
          path = File.join(dir, name)
          stat = File.lstat(path)
          feed(digest, name, format("%o", stat.mode))
          if stat.symlink?
            feed(digest, "link", File.readlink(path))
          elsif stat.file?
            feed(digest, "file")
            digest.update(Digest::SHA256.file(path).digest)
          else
            feed(digest, "dir")
          end
        end
      end
      digest.hexdigest
    rescue
      nil
    end

    # The hooks directory git would run from: the config's `core.hooksPath` (repository, worktree and
    # included files, relative to the checkout), else the common dir's `hooks`.
    def hooks_dir(worktree)
      out, ok, code = git(worktree, "config", "--includes", "--type=path", "--get", "core.hooksPath", hooks: true)
      return File.expand_path(out.chomp, worktree) if ok && !out.chomp.empty?
      # Exit 1 with no message is "not set"; anything else is git failing to read the config.
      return nil unless code == 1
      common, found = git(worktree, "rev-parse", "--git-common-dir")
      found ? File.join(File.expand_path(common.chomp, worktree), "hooks") : nil
    end

    def hidden_digest(worktree)
      out, ok = git(worktree, "ls-files", "-v", "-z")
      return nil unless ok
      digest = Digest::SHA256.new
      out.split("\0").select { |line| line.match?(/\A[a-zS] /) }.sort_by(&:b).each { |line| feed(digest, line) }
      digest.hexdigest
    rescue
      nil
    end

    # Git 2.41 can read attributes from HEAD only, so a `.gitattributes` or `info/attributes`
    # written during the step selects no filter. Looked for once; an older git skips it.
    def attr_source?(worktree)
      return @attr_source unless @attr_source.nil?
      out, ok = run_git(worktree, "--version")
      major, minor = out[/(\d+)\.(\d+)/, 1], out[/(\d+)\.(\d+)/, 2]
      @attr_source = ok && !major.nil? && (major.to_i > 2 || (major.to_i == 2 && minor.to_i >= 41))
    end

    # @param hooks [Boolean] leave `core.hooksPath` alone, to read what it is set to
    # @return [Array(String, Boolean, Integer)] stdout, success, and the exit code (1 for a failure with no message)
    def git(worktree, *args, hooks: false)
      env_extra = (args.first == "--version" || !attr_source?(worktree)) ? {} : {"GIT_ATTR_SOURCE" => "HEAD"}
      run_git(worktree, *args, hooks: hooks, env: env_extra)
    end

    def run_git(worktree, *args, hooks: false, env: {}, timeout: GIT_TIMEOUT)
      inherited = ENV.keys.select { |name| name.start_with?("GIT_") }.to_h { |name| [name, nil] }
      options = hooks ? HARDENED_OPTIONS : HARDENED_OPTIONS + NO_HOOKS
      out, err, ok = @runner.call([@git_path, *options, "-C", worktree, *args], chdir: worktree, timeout: timeout,
        env: inherited.merge(HARDENED_ENV).merge(env), max_bytes: MAX_OUTPUT)
      [out.to_s.scrub, ok, exit_code(ok, err)]
    rescue SystemCallError, Timeout::Error, Workspace::TimedProcess::OutputTooLarge
      ["", false, 2]
    end

    # Only the success flag is known: a failure with no message is git's "not found" (exit 1).
    def exit_code(ok, err)
      return 0 if ok
      err.to_s.strip.empty? ? 1 : 128
    end
  end
end
