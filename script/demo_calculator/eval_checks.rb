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
    def initialize(repo:, ruby: "ruby", runner: DEFAULT_RUNNER, group_timeout: DEFAULT_GROUP_TIMEOUT)
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
    # directory, or a Bash command that cats, pages, greps, edits or `git show`s such a path. Text that
    # only mentions the directory (a `git log --stat`, a README line, a tool's output) is not a read.
    #
    # @param hook_files [Array<String>] the hook log and its `.1` rotation
    # @param transcripts [Array<String>] session `transcript` paths of attempts and review rounds
    # @param from [String, nil] the run's `created_at`
    # @param to [String, nil] the run's `ended_at` (nil: no upper bound)
    # @return [Hash] `{hook: Integer, transcript: {path => Integer or nil}}`;
    #   nil for a transcript that can't be read. Hook lines outside from..to
    #   or without a readable `at` are not counted; transcripts are counted whole.
    def leak_check(hook_files:, transcripts:, from:, to: nil)
      lo = from && Time.parse(from)
      hi = to && Time.parse(to)
      hook = hook_files.sum do |path|
        count_lines(path) do |line|
          next false unless line.include?(ACCEPTANCE_NAME)
          event = parse_json(line)
          at = event && parse_time(event["at"])
          event && [nil, "tool_started"].include?(event["type"]) && reads_acceptance?(event["tool"] || "Bash", event["input"]) &&
            at && (lo.nil? || at >= lo) && (hi.nil? || at <= hi)
        end
      end
      {hook: hook, transcript: transcripts.uniq.to_h { |path| [path, transcript_count(path)] }}
    end

    private

    ACCEPTANCE_NAME = ACCEPTANCE_DIR.split("/").last
    # A program that reads or fetches files and starts a command (not one fed by a pipe), after any leading
    # NAME=value assignments, with the acceptance directory in its arguments: a reader, a lister, `tar`, a run of
    # a group file (`ruby`), or `git show`, `archive`, `cat-file` or `ls-tree` with or without git's own options.
    READ_PROGRAMS = "cat|head|tail|less|more|bat|nl|sed|awk|grep|rg|ls|tar|ruby|" \
      "git(?:\\s+(?:-C|-c|--git-dir|--work-tree)\\s+\\S+|\\s+--[a-z-]+)*\\s+(?:show|archive|cat-file|ls-tree)"
    READ_COMMAND = /(?:\A|&&\s*|;\s*|\(\s*|\bdo\s+)(?:[A-Za-z_]\w*=\S*\s+)*(?:#{READ_PROGRAMS})\s[^|;&\n]*#{ACCEPTANCE_NAME}/
    FILE_TOOLS = %w[Read Grep NotebookRead Edit MultiEdit].freeze

    def transcript_count(path)
      return nil unless File.readable?(path)
      ([path] + subagent_transcripts(path)).sum { |file| session_count(file) }
    end

    # Claude Code keeps a session's sub-agent transcripts in `<session id>/subagents/agent-*.jsonl` beside it.
    def subagent_transcripts(path)
      Dir.glob(File.join(path.sub(/\.jsonl\z/, ""), "subagents", "agent-*.jsonl")).sort
    end

    def session_count(path)
      count = 0
      count_lines(path) do |line|
        next false unless line.include?(ACCEPTANCE_NAME)
        blocks = parse_json(line)&.dig("message", "content")
        next false unless blocks.is_a?(Array)
        count += blocks.count { |b| b.is_a?(Hash) && b["type"] == "tool_use" && reads_acceptance?(b["name"], b["input"]) }
        false
      end
      count
    end

    def reads_acceptance?(tool, input)
      if tool == "Bash"
        command = input.is_a?(Hash) ? input["command"] : input
        command.to_s.strip.match?(READ_COMMAND)
      elsif FILE_TOOLS.include?(tool)
        values = input.is_a?(Hash) ? input.values_at("file_path", "path", "notebook_path") : [input]
        values.any? { |value| value.to_s.include?(ACCEPTANCE_NAME) }
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
