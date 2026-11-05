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
  # `hooks_changed`, `hidden_changed`, `tracked_changed`. The scope `config`
  # checks `no_commit`, then the hooks and hidden flags. A part git can't read at
  # check time is a failure, whatever it was at the start.
  #
  # A changed config never fails a step: {#config_change} reports it, apart from
  # {#check}, so it can't hide a failure and the engine can warn. The common dir's
  # `config` is shared with every workspace of the repository, which is why the
  # config digest reads it through `git config --list` and leaves out what other
  # workspaces change in the normal course of things: other branches' `branch.*`
  # sections, and other linked worktrees' `config.worktree` files. Once the
  # `filter.*` entries differ from the base's, {#dirty_paths} turns every filter
  # off, so a filter written during the step neither runs in the guard's git nor
  # hides an edit; any other config change leaves the project's filters working.

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
    CODES = %w[no_commit head_moved operation_in_progress hooks_changed hidden_changed tracked_changed].freeze

    # The code of {#config_change}'s answer: a warning, never a failed step.
    CONFIG_CHANGED = "config_changed"

    # What {#config_digest} reads, recorded in `base_guard` as `config_format`. A run with
    # no such key holds a digest of the raw files, which no reading of today can match.
    CONFIG_FORMAT = 2

    # {#config_change}'s "reading" for a config that can't be read.
    UNREADABLE = "unreadable"

    # A `branch.<name>.<variable>` key: `branch.sort` and its like (two parts) are settings, not a branch's section.
    BRANCH_KEY = /\Abranch\.(.+)\.[^.]+\z/m

    # A `filter.<name>.<variable>` key.
    FILTER_KEY = /\Afilter\.(.+)\.[^.]+\z/m

    # Seconds {#remote_head} waits for the remote.
    REMOTE_TIMEOUT = 15

    # The most seconds {#remote_head} can take: six local reads and the remote.
    REMOTE_READ_LIMIT = REMOTE_TIMEOUT + 6 * HEAD_TIMEOUT

    # Added to {#remote_head}'s git call: no prompt, ssh never asks, and no `ext::` or other helper protocol.
    REMOTE_ENV = {"GIT_TERMINAL_PROMPT" => "0", "GIT_SSH_COMMAND" => "ssh -o BatchMode=yes", "GIT_ALLOW_PROTOCOL" => "https:ssh:git:file"}.freeze

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
    #   and "base_guard" ("config_sha256", "hooks_sha256", "hidden_sha256", "filter_sha256", each nil when unreadable, and "config_format")
    def base(worktree)
      {"base_sha" => head(worktree), "base_guard" => snapshot(worktree).merge("config_format" => CONFIG_FORMAT, "filter_sha256" => filter_digest(filter_entries(worktree)))}
    end

    # @param worktree [String] a checkout
    # @return [Hash{String=>String, nil}] the SHA-256 of the common dir's `config` and the
    #   worktree's `config.worktree` (as `git config --list` reads them, included files in
    #   place, other branches' `branch.*` sections left out), `info/attributes`
    #   and the `refs/replace/` refs; of the effective hooks directory (the repository config's
    #   `core.hooksPath`, else the common dir's `hooks`) over sorted relative paths, modes,
    #   contents and symlink targets; and of the `git ls-files -v` lines tagged lowercase
    #   (assume-unchanged) or `S` (skip-worktree). A part that can't be read is nil
    def snapshot(worktree)
      {"config_sha256" => config_digest(worktree), "hooks_sha256" => hooks_digest(worktree), "hidden_sha256" => hidden_digest(worktree)}
    end

    # @param worktree [String] a checkout
    # @param base [Hash{String=>Object}] {#base}'s answer, or a run, which holds the same keys
    # @param scope [String] "unchanged" (everything) or "config" (hooks and hidden flags only)
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
      %w[hooks hidden].each do |part|
        now = snapshot_part(worktree, part)
        return failure("#{part}_changed") if now.nil? || now != base.dig("base_guard", "#{part}_sha256")
      end
      return nil unless scope == "unchanged"
      paths = dirty_paths(worktree, base: base)
      return failure("tracked_changed", "paths" => paths || []) if paths.nil? || paths.any?
      nil
    end

    # Whether the config reads differently from the last reading the caller knows of. An unreadable
    # config is a change too, and a config back at the base's reading is none. Never raises.
    #
    # @param worktree [String] a checkout
    # @param base [Hash{String=>Object}] {#base}'s answer, or a run, which holds the same keys
    # @param seen [String, nil] the "reading" of the last warning; nil for none, which compares with the base
    # @return [Hash{String=>Object}, nil] nil when nothing changed; else "code" ({CONFIG_CHANGED}, or nil when the config
    #   came back to the base's reading, which is no warning: drop `seen`), "reading" (the digest or {UNREADABLE}, to pass
    #   as `seen` next time) and, with a code, "old_format" (true when the base was recorded before {CONFIG_FORMAT},
    #   so the difference may be no change at all)
    def config_change(worktree, base, seen: nil)
      reading = config_digest(worktree) || UNREADABLE
      stored = base["base_guard"] || {}
      return nil if reading == seen
      return (seen ? {"code" => nil, "reading" => reading} : nil) if reading == stored["config_sha256"]
      {"code" => CONFIG_CHANGED, "reading" => reading, "old_format" => seen.nil? && stored["config_format"] != CONFIG_FORMAT}
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

    # What the branch's remote holds for it now, on the remote a `git push` would go to: `branch.<b>.pushRemote`, then
    # `remote.pushDefault`, then `branch.<b>.remote`, then `origin`. The ref is the one the branch tracks
    # (`branch.<b>.merge`, else its own name). On a push remote other than the tracked one it is `refs/heads/<b>`, where
    # such a push lands, except that a `pr-N` branch keeps a `refs/heads/` merge ref: its local name is no branch anywhere.
    # It runs `git ls-remote` under {REMOTE_TIMEOUT}, with no prompt (`GIT_TERMINAL_PROMPT=0`, ssh in batch mode) and only
    # the https, ssh, git and file protocols. Because the user's git config is ignored, a global `remote.pushDefault`,
    # credential helper, `insteadOf` or `core.sshCommand` is not used: a remote that needs one reads as `unreachable`.
    # Never raises. All of it takes at most {REMOTE_READ_LIMIT} seconds.
    #
    # @param worktree [String] a checkout
    # @return [Hash{String=>String, nil}] "remote", "ref" and "sha" (nil when the remote has no such branch); or
    #   "unread", why not: `detached_head`, `local_upstream` (the branch would push to a local branch), `bad_remote`
    #   (a remote name that looks like an option), `no_remote` (no remote of that name) or `unreachable` (git failed or timed out)
    def remote_head(worktree)
      out, ok = run_git(worktree, "symbolic-ref", "-q", "--short", "HEAD", timeout: HEAD_TIMEOUT)
      branch = out.strip
      return {"unread" => "detached_head"} unless ok && !branch.empty?
      tracked = branch_config(worktree, branch, "remote")
      remote = [branch_config(worktree, branch, "pushRemote"), config(worktree, "remote.pushDefault"), tracked, "origin"].find { |each| !each.empty? }
      return {"unread" => "local_upstream"} if remote == "."
      return {"unread" => "bad_remote"} if remote.start_with?("-")
      ref = remote_ref(branch, branch_config(worktree, branch, "merge"), remote == (tracked.empty? ? "origin" : tracked))
      out, ok = run_git(worktree, "ls-remote", "--", remote, ref, timeout: REMOTE_TIMEOUT, env: REMOTE_ENV)
      return {"unread" => remote_known?(worktree, remote) ? "unreachable" : "no_remote"} unless ok
      sha = out.lines.map { |line| line.split("\t") }.find { |_, name| name&.strip == ref }&.first
      {"remote" => remote, "ref" => ref, "sha" => sha}
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

    # With a `base`, `filter.*` entries that differ from the ones it recorded have every filter turned off for the
    # status: a clean filter set during the step must not run here or report an edited file as clean. A base with no
    # such record (a run stored before it existed) and any other config change leave the filters on.
    #
    # @param worktree [String] a checkout
    # @param base [Hash{String=>Object}, nil] {#base}'s answer, or a run
    # @return [Array<String>, nil] up to {MAX_PATHS} changed tracked paths (staged or not; untracked files,
    #   submodules and `assume-unchanged`/`skip-worktree` files are not seen); nil when git can't answer
    def dirty_paths(worktree, base: nil)
      options = base ? filter_options(worktree, base) : []
      return nil unless options
      out, ok = git(worktree, *options, "status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignore-submodules=all")
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

    # Every file a step left changed against `base`: committed, staged, unstaged and untracked (not ignored) paths.
    # Deleted files are left out, a rename lists the new path only, and there is no cap. Filters are handled as in
    # {#dirty_paths}, through `base_guard`'s `filter_sha256`.
    #
    # @param worktree [String] a checkout
    # @param base [String] a full commit id (40 or 64 hex digits)
    # @param base_guard [Hash{String=>Object}, nil] the `base_guard` {#base} recorded
    # @return [Array<String>, nil] sorted unique binary-encoded paths (bytes exact) relative to the checkout, a nested
    #   repository (listed as `dir/`) left out; nil when `base` is not a full id
    #   or git can't answer
    def changed_paths(worktree, base:, base_guard:)
      return nil unless base.to_s.match?(/\A(\h{40}|\h{64})\z/)
      options = filter_options(worktree, {"base_guard" => base_guard})
      return nil unless options
      tracked, ok = git(worktree, *options, "diff", "--name-only", "-z", "--no-renames", "--diff-filter=d", base, "--", scrub: false)
      return nil unless ok
      untracked, ok = git(worktree, *options, "ls-files", "-z", "--others", "--exclude-standard", scrub: false)
      return nil unless ok
      (tracked.b.split("\0".b) + untracked.b.split("\0".b)).reject { |path| path.end_with?("/") }.uniq.sort
    end

    # @param worktree [String] a checkout
    # @return [String, nil] the checked-out branch's short name, "" on a detached HEAD, nil when git can't say
    def branch(worktree)
      name, ok = own_branch(worktree)
      ok ? name.to_s : nil
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
      (part == "hooks") ? hooks_digest(worktree) : hidden_digest(worktree)
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
      config_paths = %w[config config.worktree].map { |name| git_path(worktree, name) }
      attributes = git_path(worktree, "info/attributes")
      return nil if attributes.nil? || config_paths.any?(&:nil?)
      own, known = own_branch(worktree)
      return nil unless known
      refs, listed = git(worktree, "for-each-ref", "refs/replace/")
      return nil unless listed
      digest = Digest::SHA256.new
      return nil unless config_paths.all? { |path| feed_config(digest, worktree, path, own) }
      feed_file(digest, attributes)
      feed(digest, "replace", refs)
      digest.hexdigest
    rescue
      nil
    end

    # @return [Array(String, Boolean)] the checked-out branch (nil on a detached HEAD), and whether git could say
    def own_branch(worktree)
      ref, ok, code = git(worktree, "symbolic-ref", "-q", "HEAD")
      return [ref.strip.delete_prefix("refs/heads/"), true] if ok
      [nil, code == 1]
    end

    # Feeds one config file as git reads it, so comments and layout don't count. Included files are read in
    # place and `include.path` is an entry like any other: a new include, or a change inside an included file,
    # changes the digest. Only the sections of other branches are dropped, and those change no git command run here.
    #
    # @return [Boolean] false when git can't read the file
    def feed_config(digest, worktree, path, own)
      stat = File.lstat(path)
      feed(digest, path, "link", File.readlink(path)) if stat.symlink?
      out, ok = git(worktree, "config", "--includes", "--file", path, "--list", "-z")
      return false unless ok
      feed(digest, path, "entries", *out.split("\0").reject { |entry| other_branch?(entry, own) })
      true
    rescue Errno::ENOENT
      feed(digest, path, "absent")
      true
    end

    def other_branch?(entry, own)
      name = entry[/\A[^\n]*/][BRANCH_KEY, 1]
      !name.nil? && name != own
    end

    # @return [Array<String>, nil] the effective `filter.*` entries, as `key\nvalue`, none being []; nil when git can't read them
    def filter_entries(worktree)
      out, ok, code = git(worktree, "config", "--includes", "-z", "--get-regexp", '^filter\.')
      return out.split("\0") if ok
      (code == 1) ? [] : nil
    end

    def filter_digest(entries)
      return nil unless entries
      digest = Digest::SHA256.new
      feed(digest, *entries)
      digest.hexdigest
    end

    # Entries that can't be read leave the filters on: git reading the same config for the status fails with it, so
    # no filter runs, and a failure to read them is not evidence of a changed filter.
    #
    # @return [Array<String>, nil] the options for the status; nil when a changed filter can't be turned off
    def filter_options(worktree, base)
      stored = base.dig("base_guard", "filter_sha256")
      return [] unless stored
      entries = filter_entries(worktree)
      return [] if entries.nil? || filter_digest(entries) == stored
      filters_off(entries)
    end

    # The `-c` options that empty every filter named, whatever attribute would select it. A name
    # `git -c` can't carry answers nil, which fails the check, rather than leaving that filter on.
    def filters_off(entries)
      names = entries.filter_map { |entry| entry[/\A[^\n]*/][FILTER_KEY, 1] }.uniq
      return nil if names.any? { |name| name.include?("=") }
      names.flat_map { |name| ["-c", "filter.#{name}.clean=", "-c", "filter.#{name}.smudge=", "-c", "filter.#{name}.process=", "-c", "filter.#{name}.required=false"] }
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
    def git(worktree, *args, hooks: false, scrub: true)
      env_extra = (args.first == "--version" || !attr_source?(worktree)) ? {} : {"GIT_ATTR_SOURCE" => "HEAD"}
      run_git(worktree, *args, hooks: hooks, env: env_extra, scrub: scrub)
    end

    def run_git(worktree, *args, hooks: false, env: {}, timeout: GIT_TIMEOUT, scrub: true)
      inherited = ENV.keys.select { |name| name.start_with?("GIT_") }.to_h { |name| [name, nil] }
      options = hooks ? HARDENED_OPTIONS : HARDENED_OPTIONS + NO_HOOKS
      out, err, ok = @runner.call([@git_path, *options, "-C", worktree, *args], chdir: worktree, timeout: timeout,
        env: inherited.merge(HARDENED_ENV).merge(env), max_bytes: MAX_OUTPUT)
      [scrub ? out.to_s.scrub : out.to_s, ok, exit_code(ok, err)]
    rescue SystemCallError, Timeout::Error, Workspace::TimedProcess::OutputTooLarge
      ["", false, 2]
    end

    def branch_config(worktree, branch, key)
      config(worktree, "branch.#{branch}.#{key}")
    end

    def config(worktree, key)
      run_git(worktree, "config", "--get", key, timeout: HEAD_TIMEOUT).first.strip
    end

    def remote_ref(branch, merge, on_tracked_remote)
      own = "refs/heads/#{branch}"
      return own if merge.empty?
      return merge if on_tracked_remote
      (branch.match?(/\Apr-\d+\z/) && merge.start_with?("refs/heads/")) ? merge : own
    end

    # A URL in place of a remote's name is not listed, so it counts as known.
    def remote_known?(worktree, remote)
      remote.match?(%r{[/:]}) || run_git(worktree, "remote", timeout: HEAD_TIMEOUT).first.split("\n").include?(remote)
    end

    # Only the success flag is known: a failure with no message is git's "not found" (exit 1).
    def exit_code(ok, err)
      return 0 if ok
      err.to_s.strip.empty? ? 1 : 128
    end
  end
end
