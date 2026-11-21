require_relative "../demo_calculator/eval_checks"
require_relative "config"
require_relative "metrics"

module DemoCalculator2
  # `eval`'s git-backed checks for calculator2: the acceptance runner at a head, standardrb on its directory, reads of the
  # acceptance directory, and a scan of the run's diff for what was added under it or copied from it.
  class Checks < DemoCalculator::EvalChecks
    # @param root [String] the checkout that holds script/demo_calculator2/acceptance_runner
    def initialize(repo:, root: repo, **options)
      super(repo: repo, acceptance_name: "calculator2/acceptance\\b", acceptance_hint: "calculator2/acceptance", acceptance_dir: ACCEPTANCE, **options)
      @root = root
    end

    # Runs the acceptance runner for `goal` against the checkout at head.
    #
    # @param base_sha [String] the ref that holds the acceptance tests (the record's acceptance sha)
    # @param goal [String] one of GOALS, such as `03-div-zero`
    # @return [Hash] `{passed: [goal] | [], failed: [] | [goal], regressions: []}`
    def acceptance(base_sha:, head:, goal:)
      check_rev!(base_sha)
      position = DemoCalculator2::GOALS.index(goal) || raise(Error, "unknown goal #{goal}")
      with_worktree(head) do |dir|
        _, ok = @runner.call([@ruby, File.join(@root, DemoCalculator2::ACCEPTANCE_RUNNER), "--root", dir, "#{DEMO_DIR}/goals/#{goal}.md"],
          env: self.class.clean_ruby_env.merge("CALC2_ACCEPTANCE_REF" => base_sha), chdir: dir, timeout: @group_timeout * (position + 1))
        {passed: ok ? [goal] : [], failed: ok ? [] : [goal], regressions: []}
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
    def leak_check(hook_files:, transcripts:, from:, to: nil, head: nil, removal: nil)
      super.merge(possible: possible_leak_check(hook_files: hook_files, transcripts: transcripts, from: from, to: to, head: head, removal: removal),
        possible_classes: classify_possible(hook_files: hook_files, transcripts: transcripts, from: from, to: to, head: head, removal: removal))
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

    CLASSES = %i[false_positive stat_only near_miss unresolved].freeze
    STAT_FLAG = /\A--(?:stat\S*|name-only|name-status|numstat|shortstat|summary)\z/
    PATCH_FLAG = /\A(?:-[a-zA-Z]*[pu][a-zA-Z0-9]*|--patch\S*|--cc|--word-diff\S*|--full-diff|-c)\z/
    FILE_REDIRECT = %r{(?<![\d&>])>>?(?!&)\s*(?!/dev/null)\S|\btee\b}

    # Sorts each possible hit (see {DemoCalculator::EvalChecks#possible_leak_check}) by what it could have printed, for
    # reporting only; every hit stays counted. A stat-only command prints names and counts. A false positive names
    # revisions or ranges that change nothing under the acceptance directory. A near-miss could print acceptance content
    # but sent its output to a file or `tee`, not the agent's screen. Anything else is unresolved.
    #
    # @return [Hash] `{hook: {class => count}, transcript: {class => count}, near_misses: [{source:, command:}]}`
    def classify_possible(hook_files:, transcripts:, from:, to: nil, head: nil, removal: nil)
      result = {near_misses: []}
      lo = from && Time.parse(from)
      hi = to && Time.parse(to)
      {hook: [hook_files, []], transcript: [[], transcripts]}.each do |source, (hooks, sessions)|
        counts = CLASSES.to_h { |name| [name, 0] }
        classify = lambda do |tool, input|
          hit = history_read?(tool, input, head, removal) && !reads_acceptance?(tool, input)
          if hit
            command = input.is_a?(Hash) ? input["command"].to_s : input.to_s
            name, segment = classify_command(command, head, removal)
            counts[name] += 1
            result[:near_misses] << {source: source.to_s, command: segment} if name == :near_miss
          end
          hit
        end
        hooks.each do |path|
          next unless File.readable?(path)
          File.foreach(path, chomp: true) do |line|
            event = parse_json(line)
            at = event && parse_time(event["at"])
            counted = event && [nil, "tool_started"].include?(event["type"]) && at && (lo.nil? || at >= lo) && (hi.nil? || at <= hi)
            next if !counted
            classify.call(event["tool"] || "Bash", event["input"])
          end
        end
        scan([], sessions, from, to, nil, &classify)
        result[source] = counts
      end
      result[:near_misses].uniq!
      result
    rescue => e
      warn "eval: possible hits left unclassified after #{e.class}: #{e.message}"
      nil
    end

    private

    def classify_command(command, head, removal)
      parts = command.gsub(/['"]/, " ").split(SEGMENT_BREAK)
      classes = []
      after_cd = false
      (0...parts.size).step(2) do |i|
        raw = parts[i]
        call = git_call(raw.gsub(REDIRECTION, " "), fed: i > 0 && parts[i - 1] == "|", dynamic: ["$(", "`"].include?(parts[i + 1]))
        if call && git_flagged?(call, after_cd, head, removal)
          classes << [classify_call(call, raw.match?(FILE_REDIRECT), head), raw.strip]
        end
        after_cd ||= %w[cd pushd].include?(raw.gsub(REDIRECTION, " ").split.first)
      end
      name = CLASSES.reverse.find { |candidate| classes.any? { |found, _| found == candidate } }
      name ? [name, classes.find { |found, _| found == name }.last] : [:unresolved, command]
    rescue
      [:unresolved, command]
    end

    def classify_call(call, redirected, head)
      args = (call.args.last == "$(") ? call.args[0...-1] : call.args
      return :unresolved if call.aliased || call.other_repo || call.fed || args.any? { |word| word.match?(/[$`]/) }
      stat = %w[show diff log].include?(call.verb) && args.any? { |word| STAT_FLAG.match?(word) } && args.none? { |word| PATCH_FLAG.match?(word) }
      touched = touches_acceptance?(call, args, head || "HEAD", stat: stat)
      return :unresolved if touched.nil?
      return (stat ? :stat_only : :false_positive) unless touched
      redirected ? :near_miss : :unresolved
    end

    # True or false when git can say whether the revisions or ranges the call names change the acceptance directory; nil when not.
    def touches_acceptance?(call, args, tip, stat: false)
      revs = rev_words(args).map { |word| BARE_HEAD.include?(word) ? tip : word }
      revs = [tip] if revs.empty? && stat
      return nil if revs.empty? || !%w[show diff log].include?(call.verb)
      return nil if revs.any? { |word| word.start_with?("-") }
      results = if call.verb == "diff" && revs.size == 2 && revs.none? { |word| word.match?(/\.{2,3}/) }
        [changes_under("diff", "--name-only", *revs)]
      else
        revs.map do |word|
          rev, path = word.split(":", 2)
          if path
            path.include?("calculator2/acceptance")
          elsif word.match?(/\.{2,3}/)
            changes_under("diff", "--name-only", word.partition(/\.{2,3}/).map { |piece| BARE_HEAD.include?(piece) ? tip : piece }.join)
          elsif call.verb == "diff"
            changes_under("diff", "--name-only", rev)
          else
            changes_under("show", "--name-only", "--format=", "-m", rev)
          end
        end
      end
      return nil if results.any?(&:nil?)
      results.any?
    end

    def changes_under(*args)
      out, ok = probe(*args, "--", @acceptance_dir)
      ok ? !out.strip.empty? : nil
    end

    DEMO_DIR = DemoCalculator2::DEMO_DIR
    ACCEPTANCE = "#{DEMO_DIR}/acceptance".freeze
  end
end
