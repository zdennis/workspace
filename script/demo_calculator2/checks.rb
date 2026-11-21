require_relative "../demo_calculator/eval_checks"
require_relative "config"
require_relative "metrics"

module DemoCalculator2
  # `eval`'s git-backed checks for calculator2: the acceptance runner at a head, standardrb on its directory, reads of the
  # acceptance directory, and a scan of the run's diff for what was added under it or copied from it.
  class Checks < DemoCalculator::EvalChecks
    # @param root [String] the checkout that holds script/demo_calculator2/acceptance_runner
    def initialize(repo:, root: repo, **options)
      super(repo: repo, acceptance_name: "calculator2/acceptance\\b", acceptance_hint: "calculator2/acceptance", **options)
      @root = root
    end

    # Runs the acceptance runner for item `index` against the checkout at head.
    #
    # @param base_sha [String] the ref that holds the acceptance tests (the record's acceptance sha)
    # @return [Hash] `{passed: [index] | [], failed: [] | [index], regressions: []}`
    def acceptance(base_sha:, head:, index:)
      check_rev!(base_sha)
      goal = "#{DemoCalculator2::GOALS.fetch(index - 1)}.md"
      with_worktree(head) do |dir|
        _, ok = @runner.call([@ruby, File.join(@root, DemoCalculator2::ACCEPTANCE_RUNNER), "--root", dir, "#{DEMO_DIR}/goals/#{goal}"],
          env: self.class.clean_ruby_env.merge("CALC2_ACCEPTANCE_REF" => base_sha), chdir: dir, timeout: @group_timeout * index)
        {passed: ok ? [index] : [], failed: ok ? [] : [index], regressions: []}
      end
    end

    # Counts standardrb offenses in demo/calculator2 at head.
    def lint(head:, gemfile:)
      with_worktree(head) do |dir|
        out, = @runner.call(%w[bundle exec standardrb --format json] + [DEMO_DIR], env: {"BUNDLE_GEMFILE" => gemfile}, chdir: dir)
        JSON.parse(out).dig("summary", "offense_count")
      rescue JSON::ParserError
        nil
      end
    end

    # The definite reads of {DemoCalculator::EvalChecks#leak_check}, plus `possible`: the commands that could print the
    # tests from the branch's history (see {DemoCalculator::EvalChecks#possible_leak_check}).
    def leak_check(hook_files:, transcripts:, from:, to: nil)
      super.merge(possible: possible_leak_check(hook_files: hook_files, transcripts: transcripts, from: from, to: to))
    end

    # Looks at what the run branch changed: any path under the acceptance directory that was added or changed after
    # the removal commit, and any added line elsewhere that is one of the acceptance tests' lines.
    #
    # @param base_sha [String] the commit that holds the acceptance tests
    # @param head [String] the last item's commit
    # @param since [String, nil] the commit that removed them from the run branch; nil means base_sha
    # @return [Hash, nil] `{paths: [String], copied: [String]}`; nil when git could not say
    def diff_scan(base_sha:, head:, since: nil)
      check_rev!(base_sha)
      check_rev!(head)
      check_rev!(since || base_sha)
      range = "#{since || base_sha}..#{head}"
      status, ok = git("diff", "--name-status", range, "--", ACCEPTANCE)
      return nil unless ok
      files, listed = git("ls-tree", "-r", "--name-only", base_sha, "--", ACCEPTANCE)
      return nil unless listed
      texts = files.lines.map(&:strip).filter_map do |path|
        text, shown = git("show", "#{base_sha}:#{path}")
        text if shown
      end
      diff, diffed = git("diff", "-U0", range, "--", ".", ":(exclude)#{ACCEPTANCE}")
      return nil unless diffed
      {paths: Metrics.touched(status), copied: Metrics.copied(diff, Metrics.signature(texts))}
    end

    DEMO_DIR = DemoCalculator2::DEMO_DIR
    ACCEPTANCE = "#{DEMO_DIR}/acceptance".freeze
  end
end
