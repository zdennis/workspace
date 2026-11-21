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
    # Groups use the ruby gems of the plain install, not the caller's bundle.
    CLEAN_RUBY_ENV = {"BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil}.freeze

    # The default runner: runs argv with env in chdir, returns [stdout, success?].
    DEFAULT_RUNNER = lambda do |argv, env: {}, chdir: nil|
      opts = chdir ? {chdir: chdir} : {}
      out, _err, status = Open3.capture3(env, *argv, **opts)
      [out, status.success?]
    rescue SystemCallError => e
      ["", false].tap { warn "eval: #{e.message}" }
    end

    # @param repo [String] a git checkout that holds the run's commits
    # @param ruby [String] the ruby that runs each acceptance group
    # @param runner [#call] `call(argv, env:, chdir:)` returning `[stdout, success?]`
    def initialize(repo:, ruby: "ruby", runner: DEFAULT_RUNNER)
      @repo = repo
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
      with_worktree(head) do |dir|
        archive = File.join(dir, ".acceptance.tar")
        git("archive", "--format=tar", "-o", archive, base_sha, ACCEPTANCE_DIR)
        @runner.call(["tar", "-x", "-C", dir, "-f", archive], env: {}, chdir: nil)
        File.delete(archive) if File.exist?(archive)
        passed = []
        failed = []
        (1..index).each do |n|
          file = Dir.glob(File.join(dir, ACCEPTANCE_DIR, "group_#{n}_*_test.rb")).first
          ok = file && @runner.call([@ruby, file], env: CLEAN_RUBY_ENV.merge("CALC_ROOT" => File.join(dir, CALC_DIR)), chdir: dir).last
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

    # Counts lines naming the acceptance directory that the agents read.
    #
    # @param hook_files [Array<String>] the hook log and its `.1` rotation
    # @param transcripts [Array<String>] attempt `session.transcript` paths
    # @param from [String, nil] the run's `created_at`
    # @param to [String, nil] the run's `ended_at` (nil: no upper bound)
    # @return [Hash] `{hook: Integer, transcript: {path => Integer or nil}}`;
    #   nil for a transcript that can't be read. Hook lines outside from..to
    #   or without a readable `at` are not counted; transcripts are counted whole.
    def leak_check(hook_files:, transcripts:, from:, to: nil)
      lo = from && Time.parse(from)
      hi = to && Time.parse(to)
      hook = hook_files.sum do |path|
        lines(path).count do |line|
          next false unless line.include?(ACCEPTANCE_DIR.split("/").last)
          at = hook_time(line)
          at && (lo.nil? || at >= lo) && (hi.nil? || at <= hi)
        end
      end
      {hook: hook, transcript: transcripts.uniq.to_h { |path| [path, transcript_count(path)] }}
    end

    private

    def transcript_count(path)
      return nil unless File.readable?(path)
      lines(path).count { |line| line.include?("calculator-acceptance") }
    end

    def lines(path)
      File.readable?(path) ? File.readlines(path, chomp: true) : []
    rescue SystemCallError
      []
    end

    def hook_time(line)
      Time.parse(JSON.parse(line)["at"].to_s)
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def git(*args)
      @runner.call(["git", "-C", @repo, *args], env: {}, chdir: nil)
    end

    def with_worktree(head)
      dir = Dir.mktmpdir("calc-eval-")
      added = git("worktree", "add", "--detach", dir, head).last
      raise "eval: git worktree add failed for #{head}" unless added
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
