require "fileutils"
require "json"
require "open3"
require "time"
require "tmpdir"

module DemoCalculator
  # The checks of `eval` that need git, ruby or standardrb. Every process goes
  # through the injected runner, so a spec can fake any of them.
  class EvalChecks
    ACCEPTANCE_DIR = "demo/calculator-acceptance".freeze
    CALC_DIR = "demo/calculator".freeze
    DEFAULT_GROUP_TIMEOUT = 60
    # Raised when a git step the checks depend on fails, or a revision is not a plain one.
    class Error < StandardError; end

    # Groups use the ruby gems of the plain install, not the caller's bundle.
    CLEAN_RUBY_ENV = {"BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil, "RUBYGEMS_GEMDEPS" => nil}.freeze

    # What Bundler stores in BUNDLER_ORIG_* for a variable that was not set.
    BUNDLER_UNSET = "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL".freeze

    # CLEAN_RUBY_ENV plus GEM_HOME and GEM_PATH put back to what they were before
    # `bundle exec` pointed them at the bundle (which may lack minitest).
    def self.clean_ruby_env(env = ENV)
      CLEAN_RUBY_ENV.merge(%w[GEM_HOME GEM_PATH].to_h do |key|
        orig = env.fetch("BUNDLER_ORIG_#{key}", env[key])
        [key, (orig unless orig.to_s.empty? || orig == BUNDLER_UNSET)]
      end)
    end

    # The default runner: runs argv with env in chdir, returns [stdout, success?].
    # With timeout (seconds) the whole process group is killed when it runs
    # longer, and the result is failure.
    DEFAULT_RUNNER = lambda do |argv, env: {}, chdir: nil, timeout: nil|
      opts = chdir ? {chdir: chdir} : {}
      Open3.popen3(env, *argv, pgroup: true, **opts) do |stdin, stdout, stderr, waiter|
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        finished = waiter.join(timeout)
        unless finished
          begin
            Process.kill("KILL", -waiter.pid)
          rescue SystemCallError
            nil
          end
          waiter.join
        end
        err_reader.join
        [out_reader.value, !!finished && waiter.value.success?]
      end
    rescue SystemCallError => e
      ["", false].tap { warn "eval: #{e.message}" }
    end

    # @param repo [String] a git checkout that holds the run's commits
    # @param ruby [String] the ruby that runs each acceptance group
    # @param runner [#call] `call(argv, env:, chdir:, timeout:)` returning `[stdout, success?]`
    # @param group_timeout [Numeric] seconds one acceptance group may run before it counts as failed
    # @param acceptance_name [String] regexp source for how a read names the acceptance directory
    # @param acceptance_hint [String] plain text every line that names it contains, a cheap filter
    # @param acceptance_dir [String] the acceptance directory's path in the repo, for confirming a history read
    def initialize(repo:, ruby: "ruby", runner: DEFAULT_RUNNER, group_timeout: DEFAULT_GROUP_TIMEOUT,
      acceptance_name: Regexp.escape(ACCEPTANCE_NAME), acceptance_hint: ACCEPTANCE_NAME, acceptance_dir: ACCEPTANCE_DIR)
      @acceptance_dir = acceptance_dir
      @probes = {}
      @read_command = /(?:\A|&&\s*|;\s*|\(\s*|\bdo\s+)(?:[A-Za-z_]\w*=\S*\s+)*(?:#{READ_PROGRAMS})\s[^|;&\n]*#{acceptance_name}/
      @acceptance_name = acceptance_name
      @acceptance_hint = acceptance_hint
      @repo = repo
      @group_timeout = group_timeout
      @ruby = ruby
      @runner = runner
    end

    # Runs acceptance groups 1..index against the calculator at head, using the
    # groups as they are at base_sha.
    #
    # @param base_sha [String] where the acceptance groups are read from
    # @param head [String] the commit whose calculator is tested
    # @param index [Integer] 1-based item number: groups 1..index run
    # @return [Hash] `{passed: [Integer], failed: [Integer], regressions: [Integer]}`
    #   (regressions are failed groups below index)
    def acceptance(base_sha:, head:, index:)
      check_rev!(base_sha)
      with_worktree(head) do |dir|
        archive = File.join(dir, ".acceptance.tar")
        archived = git("archive", "--format=tar", "-o", archive, base_sha, "--", ACCEPTANCE_DIR).last
        extracted = archived && @runner.call(["tar", "-x", "-C", dir, "-f", archive], env: {}, chdir: nil).last
        raise Error, "eval: could not read #{ACCEPTANCE_DIR} at #{base_sha}" unless extracted
        File.delete(archive) if File.exist?(archive)
        passed = []
        failed = []
        (1..index).each do |n|
          file = Dir.glob(File.join(dir, ACCEPTANCE_DIR, "group_#{n}_*_test.rb")).first
          ok = file && @runner.call([@ruby, file], env: self.class.clean_ruby_env.merge("CALC_ROOT" => File.join(dir, CALC_DIR)), chdir: dir,
            timeout: @group_timeout).last
          (ok ? passed : failed) << n
        end
        {passed: passed, failed: failed, regressions: failed.select { |n| n < index }}
      end
    end

    # Counts standardrb offenses in demo/calculator at head.
    #
    # @param head [String] the last item's commit
    # @param gemfile [String] BUNDLE_GEMFILE, the script checkout's Gemfile
    # @return [Integer, nil] the offense count, nil when standardrb gave no JSON
    def lint(head:, gemfile:)
      with_worktree(head) do |dir|
        out, = @runner.call(%w[bundle exec standardrb --format json] + [CALC_DIR],
          env: {"BUNDLE_GEMFILE" => gemfile}, chdir: dir)
        JSON.parse(out).dig("summary", "offense_count")
      rescue JSON::ParserError
        nil
      end
    end

    # Counts the agents' reads of acceptance test content: a file tool on a path in the acceptance
    # directory, or a Bash command that starts with a reader, a lister, `tar`, `ruby` (a run of a group
    # file) or `git show|archive|cat-file|ls-tree` and names the directory. Text that only mentions the
    # directory (a `git log --stat`, a README line, a tool's output) is not a read. A session's sub-agent
    # transcripts (`<session>/subagents/agent-*.jsonl`) count toward its transcript.
    #
    # @param hook_files [Array<String>] the hook log and its `.1` rotation
    # @param transcripts [Array<String>] session `transcript` paths of attempts and review rounds
    # @param from [String, nil] the run's `created_at`
    # @param to [String, nil] the run's `ended_at` (nil: no upper bound)
    # @param head [String, nil] accepted for {#possible_leak_check}'s callers; a definite read does not use them
    # @param removal [String, nil] the same
    # @return [Hash] `{hook: Integer, transcript: {path => Integer or nil}}`;
    #   nil for a transcript that can't be read. Hook lines outside from..to
    #   or without a readable `at` are not counted; transcripts are counted whole.
    def leak_check(hook_files:, transcripts:, from:, to: nil, head: nil, removal: nil)
      scan(hook_files, transcripts, from, to, @acceptance_hint) { |tool, input| reads_acceptance?(tool, input) }
    end

    # Counts the agents' commands that could print the acceptance tests from the run branch's history without naming
    # the directory. A git command is counted unless its verb is known to print no revision's content: status, add,
    # commit, push, fetch, pull, branch, rev-parse, merge-base, config, rm, mv, init, remote, describe, ls-files, tag, a
    # `stash` without `show`, a `checkout` or `switch` without a revision or `--`, a `log` or `reflog` without a patch or
    # stat flag, and a `diff` or `show` that names no revision other than a bare HEAD. Unknown verbs and `-c alias.*` are
    # counted. A word with `$` or a backtick, a git fed by a pipe or `xargs`, `cat-file --batch*`, and a bare HEAD or `@`
    # when the command has -C, --git-dir, --work-tree, GIT_DIR, GIT_WORK_TREE or follows a `cd` are counted as revisions.
    # `git` may follow wrappers (`env`, `rtk`, `xargs`, `bash -c`) and be path-qualified. A command that is a definite
    # read (see {#leak_check}) is not counted here.
    #
    # Cleared, only when git proves it: `git diff A..B` or `A...B` whose range changes nothing under the acceptance
    # directory while the run head's tree has none (so A lacks the tests as well), and, when `removal` is given, `git show
    # SHA` (with or without paths) of a hash that descends from the removal commit and changes nothing there. A git call
    # that raises or times out counts the command.
    #
    # Known gaps (a scan of command text cannot be complete; the deny tripwire and {#leak_check} are the other layers):
    # - a `cd` into another repository, an alias or script that runs git, and git called from a file or `eval`;
    # - a range cleared because it is empty under the directory at the run head, though the tests were back mid-run;
    # - a ref name that was moved between the agent's command and the eval.
    #
    # @param head [String, nil] the run branch's tip: what the agents' `HEAD` and `@` meant at the end of a range; the repo's HEAD when nil
    # @param removal [String, nil] the commit that removed the acceptance tests from the run branch; nil clears no `git show`
    # @return [Hash] `{hook: Integer, transcript: {path => Integer or nil}}`, as {#leak_check}
    def possible_leak_check(hook_files:, transcripts:, from:, to: nil, head: nil, removal: nil)
      scan(hook_files, transcripts, from, to, nil) { |tool, input| history_read?(tool, input, head, removal) && !reads_acceptance?(tool, input) }
    end

    private

    ACCEPTANCE_NAME = ACCEPTANCE_DIR.split("/").last
    # A program that reads or fetches files and starts a command (not one fed by a pipe), after any leading
    # NAME=value assignments, with the acceptance directory in its arguments: a reader, a lister, `tar`, a run of
    # a group file (`ruby`), or `git show`, `archive`, `cat-file` or `ls-tree` with or without git's own options.
    READ_PROGRAMS = "cat|head|tail|less|more|bat|nl|sed|awk|grep|rg|ls|tar|ruby|" \
      "git(?:\\s+(?:-C|-c|--git-dir|--work-tree)\\s+\\S+|\\s+--[a-z-]+)*\\s+(?:show|archive|cat-file|ls-tree)"
    FILE_TOOLS = %w[Read Grep NotebookRead Edit MultiEdit].freeze

    def scan(hook_files, transcripts, from, to, hint, &matches)
      lo = from && Time.parse(from)
      hi = to && Time.parse(to)
      hook = hook_files.sum do |path|
        count_lines(path) do |line|
          next false if hint && !line.include?(hint)
          event = parse_json(line)
          at = event && parse_time(event["at"])
          event && [nil, "tool_started"].include?(event["type"]) && matches.call(event["tool"] || "Bash", event["input"]) &&
            at && (lo.nil? || at >= lo) && (hi.nil? || at <= hi)
        end
      end
      {hook: hook, transcript: transcripts.uniq.to_h { |path| [path, transcript_count(path, hint, &matches)] }}
    end

    def transcript_count(path, hint, &matches)
      return nil unless File.readable?(path)
      ([path] + subagent_transcripts(path)).sum { |file| session_count(file, hint, &matches) }
    end

    # Claude Code keeps a session's sub-agent transcripts in `<session id>/subagents/agent-*.jsonl` beside it.
    def subagent_transcripts(path)
      Dir.glob(File.join(path.sub(/\.jsonl\z/, ""), "subagents", "agent-*.jsonl")).sort
    end

    def session_count(path, hint, &matches)
      count = 0
      count_lines(path) do |line|
        next false if hint && !line.include?(hint)
        blocks = parse_json(line)&.dig("message", "content")
        next false unless blocks.is_a?(Array)
        count += blocks.count { |b| b.is_a?(Hash) && b["type"] == "tool_use" && matches.call(b["name"], b["input"]) }
        false
      end
      count
    end

    SEGMENT_BREAK = /(&&|\|\||;|\||\n|\$\(|\(|\)|`)/
    LOG_PATCH = /(?:\A|\s)(?:-[a-zA-Z]*[pu][a-zA-Z0-9]*|-c|-L\S*|--patch\S*|--stat\S*|--word-diff\S*|--all|--cc|--full-diff)(?=\s|\z)/
    # Verbs that print no file content from a revision. `checkout` and `switch` are among them only without a revision or `--`.
    SAFE_VERBS = %w[status add commit push fetch pull branch rev-parse merge-base config rm mv init remote describe ls-files tag stash switch checkout].freeze
    # Verbs that print a revision's content when given one.
    REV_VERBS = %w[archive grep ls-tree blame].freeze
    # Options whose value is the next word, so it is not a revision.
    VALUE_OPTIONS = %w[-U -n -L -S -G -O --max-count --unified --since --until --author --grep --format --pretty --diff-filter --skip].freeze
    # What may stand before `git` in a command: assignments, options, wrappers and numbers (`xargs -n1`).
    WRAPPER = %r{\A(?:[A-Za-z_]\w*=\S*|-\S*|(?:\S*/)?(?:rtk|sudo|env|time|nice|nohup|command|exec|xargs|bash|sh|zsh|watch|timeout)|\d+)\z}
    GIT_PROGRAM = %r{\A(?:\\|\S*/)?git\z}
    OTHER_REPO_OPTIONS = %w[-C --git-dir --work-tree].freeze
    GitCall = Struct.new(:verb, :args, :other_repo, :aliased, :fed)
    # Looks like a revision: a hash, `HEAD~N`, `HEAD^`, `HEAD@{n}`, a range, a `refs/` or remote ref, a default branch or a special ref.
    REV_SHAPE = %r{\A(?:[0-9a-f]{4,40}|\S*[~^]\S*|\S*@\{\S*|\S*\.{2,3}\S*|refs/\S+|origin/\S+|upstream/\S+|main|master|ORIG_HEAD|FETCH_HEAD|MERGE_HEAD|CHERRY_PICK_HEAD|stash)\z}
    BARE_HEAD = %w[HEAD @].freeze
    HASH = /\A[0-9a-f]{7,40}\z/
    UNSTABLE_NAME = /\A(?:HEAD|ORIG_HEAD|FETCH_HEAD|MERGE_HEAD|CHERRY_PICK_HEAD|stash)|[~^]|@\{/
    PROBE_TIMEOUT = 10
    # `> file`, `2>&1`, `< file`: not arguments of the git command.
    REDIRECTION = /\d*[<>]+&?\s*\S*/

    # True for a Bash command that can print history content: see {#possible_leak_check}. A raise counts the command.
    def history_read?(tool, input, head = nil, removal = nil)
      return false unless tool == "Bash"
      command = input.is_a?(Hash) ? input["command"] : input
      parts = command.to_s.gsub(/['"]/, " ").split(SEGMENT_BREAK)
      after_cd = false
      (0...parts.size).step(2) do |i|
        segment = parts[i].gsub(REDIRECTION, " ")
        call = git_call(segment, fed: i > 0 && parts[i - 1] == "|", dynamic: ["$(", "`"].include?(parts[i + 1]))
        return true if call && git_flagged?(call, after_cd, head, removal)
        after_cd ||= %w[cd pushd].include?(segment.split.first)
      end
      false
    rescue => e
      warn "eval: leak scan counted a command after #{e.class}: #{e.message}"
      true
    end

    # The git command in a segment, when `git` is at its start or after only wrappers (`rtk`, `env X=1`, `xargs`, `bash -c`).
    def git_call(segment, fed:, dynamic:)
      words = segment.split
      at = words.index { |word| GIT_PROGRAM.match?(word) }
      return nil unless at && words.first(at).all? { |word| WRAPPER.match?(word) }
      before = words.first(at)
      rest = words.drop(at + 1)
      other_repo = before.any? { |word| word.start_with?("GIT_DIR=", "GIT_WORK_TREE=") }
      aliased = false
      until rest.empty? || !rest.first.start_with?("-")
        option = rest.shift
        if option == "-c"
          aliased ||= rest.shift.to_s.start_with?("alias.")
        elsif OTHER_REPO_OPTIONS.include?(option)
          other_repo = true
          rest.shift
        elsif option.start_with?("--git-dir=", "--work-tree=")
          other_repo = true
        elsif option == "--namespace" || option == "--exec-path"
          rest.shift
        end
      end
      verb = rest.shift
      return nil unless verb
      GitCall.new(verb, dynamic ? rest + ["$("] : rest, other_repo, aliased, fed || before.include?("xargs"))
    end

    # The allowlist: a git command is counted unless its verb is known to print no revision's content, or its `diff` or
    # `show` is one of the cleared shapes (see {#possible_leak_check}).
    def git_flagged?(call, after_cd, head, removal)
      return true if call.aliased
      words = call.args
      revs = rev_words(words)
      exempt = !(call.other_repo || after_cd)
      foreign = revs.any? { |word| foreign_rev?(word, exempt) } || words.any? { |word| word.match?(/[$`]/) }
      verb = call.verb
      if verb == "log" || verb == "reflog"
        words.join(" ").match?(LOG_PATCH)
      elsif verb == "show"
        (foreign || (call.fed && revs.empty?)) && !(!call.other_repo && cleared_show?(revs, removal))
      elsif verb == "diff"
        (foreign || (call.fed && revs.empty?)) && !(!call.other_repo && cleared_diff?(revs, head))
      elsif verb == "cat-file"
        foreign || call.fed || words.any? { |word| word.start_with?("--batch") }
      elsif verb == "stash"
        words.first == "show"
      elsif verb == "restore"
        foreign || restore_source?(words)
      elsif verb == "worktree"
        words.first == "add" && (foreign || call.fed)
      elsif verb == "rev-list"
        words.include?("--objects") || call.fed
      elsif %w[checkout switch].include?(verb)
        foreign || words.include?("--")
      elsif REV_VERBS.include?(verb)
        foreign || call.fed
      else
        !SAFE_VERBS.include?(verb)
      end
    end

    # The non-option words before `--`, without the values of options that take one (`-U 5`, `-n 1`).
    def rev_words(words)
      revs = []
      skip = false
      words.each do |word|
        break if word == "--"
        if skip
          skip = false
        elsif word.start_with?("-")
          skip = VALUE_OPTIONS.include?(word)
        else
          revs << word
        end
      end
      revs
    end

    def restore_source?(words)
      words.each_cons(2).any? { |flag, value| %w[--source -s].include?(flag) && !BARE_HEAD.include?(value) } ||
        words.any? { |word| word.start_with?("--source=") && !BARE_HEAD.include?(word.split("=", 2).last) }
    end

    # A token that names a revision other than the checkout's own HEAD (`rev:path` counts by its rev); a bare HEAD
    # counts too when it may mean another checkout's (`exempt` false). A word with `$` or a backtick is unknown.
    def foreign_rev?(token, exempt = true)
      return true if token.match?(/[$`]/)
      return false if token.start_with?("/", "./", "../")
      rev = token.split(":", 2).first.to_s
      return false if rev.empty?
      return !exempt if BARE_HEAD.include?(rev)
      REV_SHAPE.match?(rev) || probe("rev-parse", "--verify", "-q", "#{rev}^{object}").last
    end

    # `git show HASH` (with or without `-- PATHS`, which only narrow the output) of one commit that descends from the
    # removal commit and changes nothing in the acceptance directory.
    def cleared_show?(revs, removal)
      return false unless removal && revs.size == 1 && HASH.match?(revs.first)
      commit = commit_of(revs.first)
      base = commit_of(removal)
      return false unless commit && base && commit != base && descends?(base, commit)
      out, ok = probe("show", "--name-only", "--format=", "-m", commit, "--", @acceptance_dir)
      ok && out.strip.empty?
    end

    # `git diff A..B` or `A...B` where B is the run's HEAD or a hash, the run head's tree has no acceptance directory and
    # the range changes nothing under it. Every HEAD during the run lacked the tests too, and A matches the final tree
    # under the directory, so the range then printed nothing from it either.
    def cleared_diff?(revs, head)
      return false unless revs.size == 1
      left, dots, right = revs.first.partition(/\.{2,3}/)
      return false if dots.empty?
      tip = head || "HEAD"
      left = tip if left.empty? || BARE_HEAD.include?(left)
      right = tip if right.empty? || BARE_HEAD.include?(right)
      return false unless left == tip || HASH.match?(left) || stable_name?(left)
      return false unless right == tip || HASH.match?(right)
      tree, listed = probe("ls-tree", "-r", "--name-only", tip, "--", @acceptance_dir)
      return false unless listed && tree.strip.empty?
      out, ok = probe("diff", "--name-only", "#{left}#{dots}#{right}", "--", @acceptance_dir)
      ok && out.strip.empty?
    end

    def stable_name?(name)
      name.match?(/\A\w[\w.\/-]*\z/) && !name.match?(UNSTABLE_NAME)
    end

    def commit_of(rev)
      out, ok = probe("rev-parse", "--verify", "-q", "#{rev}^{commit}")
      out.strip if ok && !out.strip.empty?
    end

    def descends?(ancestor, commit)
      probe("merge-base", "--is-ancestor", ancestor, commit).last
    end

    # One memoized git call with a time limit. A runner that raises raises here; {#history_read?} counts the command.
    def probe(*args)
      @probes[args] ||= @runner.call(["git", "-C", @repo, *args], env: {}, chdir: nil, timeout: PROBE_TIMEOUT)
    end

    def reads_acceptance?(tool, input)
      if tool == "Bash"
        command = input.is_a?(Hash) ? input["command"] : input
        command.to_s.strip.match?(@read_command)
      elsif FILE_TOOLS.include?(tool)
        values = input.is_a?(Hash) ? input.values_at("file_path", "path", "notebook_path") : [input]
        values.any? { |value| value.to_s.match?(/#{@acceptance_name}/) }
      else
        false
      end
    end

    def parse_json(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def count_lines(path, &block)
      File.readable?(path) ? File.foreach(path, chomp: true).count(&block) : 0
    rescue SystemCallError
      0
    end

    def parse_time(text)
      Time.parse(text.to_s)
    rescue ArgumentError
      nil
    end

    def git(*args)
      @runner.call(["git", "-C", @repo, *args], env: {}, chdir: nil)
    end

    def check_rev!(rev)
      raise Error, "eval: refusing revision #{rev.inspect}" if rev.to_s.empty? || rev.to_s.start_with?("-")
    end

    def with_worktree(head)
      check_rev!(head)
      dir = Dir.mktmpdir("calc-eval-")
      added = git("worktree", "add", "--detach", dir, head).last
      raise Error, "eval: git worktree add failed for #{head}" unless added
      yield dir
    ensure
      if dir
        git("worktree", "remove", "--force", dir)
        git("worktree", "prune")
        FileUtils.rm_rf(dir)
      end
    end
  end
end
