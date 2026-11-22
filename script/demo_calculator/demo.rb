require "fileutils"
require "json"
require "open3"
require "time"
require_relative "config"
require_relative "run_record"
require_relative "wait"

module DemoCalculator
  class Refused < StandardError; end

  # The git pathspec that leaves a run's own `--out` directory out of a clean-tree check, so the run's log and record
  # do not make its checkout look dirty. Only that directory: any other file still counts.
  #
  # @param checkout [String] the checkout whose status is read
  # @param out_dir [String, nil] the run's `--out` directory, relative to `checkout` when not absolute
  # @return [Array<String>] `["--", ":(exclude)<dir>"]`, or `[]` when `out_dir` is nil or lies outside `checkout`
  def self.out_dir_exclude(checkout, out_dir)
    return [] if out_dir.nil?
    root = real_path(checkout)
    dir = real_path(File.expand_path(out_dir, checkout))
    return [] unless dir.start_with?(root + File::SEPARATOR)
    ["--", ":(exclude)#{dir.delete_prefix(root + File::SEPARATOR)}"]
  end

  # Resolves symlinks in the part of a path that exists, so /var and /private/var compare equal.
  #
  # @param path [String]
  # @return [String]
  def self.real_path(path)
    missing = []
    existing = File.expand_path(path)
    until File.exist?(existing)
      missing.unshift(File.basename(existing))
      existing = File.dirname(existing)
    end
    File.join(File.realpath(existing), *missing)
  end

  # One demo workspace: the checkout this script sits in, and the commands that drive it.
  class Demo
    # @return [String, nil] where `run` wrote run.json; nil before it did, and under `dry_run`
    attr_reader :record_path

    # @param root [String] the checkout the demo lives in
    # @param workspace [String] the `workspace` program
    # @param name [String, nil] the demo workspace's name; nil lets `workspace` detect it from the directory
    # @param dry_run [Boolean] print each mutating command instead of running it; reads are skipped
    # @param out [IO]
    # @param err [IO] where a recovery hint goes when `run` fails after switching branch
    # @param base [String, nil] the ref `run` branches from; nil means HEAD, which a run branch refuses
    # @param out_dir [String, nil] where `run` writes run.json; nil means tmp/demo-calculator/runs/<stamp>
    # @param clock [#call] returns the current Time
    # @param wait [Boolean] after `run`, poll the queue until it stops (see Wait.stop_reason)
    # @param held_limit [Numeric] seconds an item may stay held before `wait` stops
    # @param timeout [Numeric] seconds `wait` may run in all
    # @param poll [Numeric] seconds between polls
    # @param sleeper [#call] sleeps for the given seconds
    # @param config [Config] which demo this is
    def initialize(root:, workspace:, name: nil, dry_run: false, out: $stdout, err: $stderr, base: nil, out_dir: nil, clock: -> { Time.now },
      wait: false, held_limit: 1200, timeout: 14_400, poll: 15, sleeper: ->(seconds) { sleep(seconds) }, config: Config.v1)
      @config = config
      @root = File.expand_path(root)
      @workspace = workspace
      @name = name
      @dry_run = dry_run
      @out = out
      @err = err
      @base = base
      @out_dir = out_dir
      @clock = clock
      @wait = wait
      @held_limit = held_limit
      @timeout = timeout
      @poll = poll
      @sleeper = sleeper
    end

    # @return [Array<Array<String>>] the commands that empty a queue holding these items (rows of `wq list --json`):
    #   disable it, cancel the running item, skip a held one, remove the waiting ones, then clear the pause
    #   a cancel leaves
    def self.queue_clearing(items, name_args: [])
      wq = ->(*args) { ["work-queue", *args, *name_args] }
      commands = [wq.call("disable")]
      items.each do |item|
        case item["state"]
        when "active", "starting" then commands << wq.call("cancel", item["id"])
        when "held" then commands << wq.call("skip", item["id"])
        end
      end
      queued = items.select { |item| item["state"] == "queued" }.map { |item| item["id"] }
      commands << wq.call("rm", *queued) unless queued.empty?
      commands << wq.call("resume")
    end

    # @return [Array<Array<String>>] the commands that queue the seven workflows, in order; each prints JSON
    def self.queueing(name_args: [], config: Config.v1)
      config.queue_items.call(name_args).map(&:last)
    end

    # @return [Array<Array<String>>] the commands that turn the queue on and start the first item
    def self.starting(name_args: [])
      [["work-queue", "enable", *name_args], ["work-queue", "advance", *name_args]]
    end

    # Puts the stub back and empties the queue. Touches only demo/calculator and this workspace's queue.
    def reset
      guard!
      check_stub!
      clear_queue
      restore_files
    end

    # Moves to a fresh calc-demo/<stamp> branch, empties the queue, drops the acceptance tests and resets the stub
    # there, installs the workflows, queues all seven, runs the first pass and writes the run record.
    #
    # @return [Hash, nil] the record; nil under `dry_run`
    def run
      guard!
      stamp = @clock.call.utc.strftime("%Y%m%dT%H%M%SZ")
      branch = "#{RUN_BRANCH_PREFIX}#{stamp}"
      base = @base || "HEAD"
      preflight(branch)
      check_stub!
      base_sha = git("rev-parse", "#{base}^{commit}")
      acceptance_sha = point_acceptance_ref(base_sha)
      switch_to(branch, base)
      clear_queue
      begin
        workspace_sha = git("rev-parse", "HEAD")
        removal_sha = remove_acceptance_tests
        restore_files
        configure
        items = queue_items
        record = write_record(stamp, branch, base_sha, workspace_sha, items, acceptance_sha, removal_sha)
        self.class.starting(name_args: name_args).each { |argv| workspace(*argv) }
      rescue Refused
        @err.puts "#{@config.program}: run stopped after switching to #{branch}; `git switch -` returns to the previous branch (#{branch} is left partial)" unless @dry_run
        raise
      end
      wait_for_queue(record) if @wait
      record
    end

    private

    # Polls the queue until Wait.stop_reason says stop, calling `work-queue advance` when the queue cannot advance
    # itself, then records why it stopped in run.json.
    def wait_for_queue(record)
      if @dry_run
        say "would wait for the queue (held limit #{@held_limit}s, timeout #{@timeout}s)"
        return
      end
      capabilities = JSON.parse(workspace_stdout("capabilities", "--json"))
      feature = capabilities.dig("features", "work_queue")
      event_log = capabilities.dig("paths", "event_log")
      started_at = @clock.call
      first_seen = {}
      loop do
        now = @clock.call
        begin
          row = read_queue_row
        rescue Refused
          record_stop(record, {"reason" => "no_queue", "item" => nil}, now)
          raise
        end
        items = row["items"] || []
        items.each { |item| first_seen[item["id"]] ||= now if item["state"] == "held" }
        events = (items.any? { |item| item["state"] == "held" }) ? read_events(event_log) : []
        held_since = Wait.held_since(events: events, items: items, first_seen: first_seen)
        stop = Wait.stop_reason(row, now: now, started_at: started_at, held_since: held_since, held_limit: @held_limit, timeout: @timeout)
        return record_stop(record, stop, now) if stop
        if Wait.advance?(row, work_queue_feature: feature)
          begin
            workspace("work-queue", "advance", *name_args)
          rescue Refused => e
            @err.puts "#{@config.program}: #{e.message}"
            return record_stop(record, {"reason" => "advance_failed", "item" => nil}, now)
          end
        end
        @sleeper.call(@poll)
      end
    end

    def record_stop(record, stop, now)
      failed = failed_item unless stop["reason"] == "empty"
      record["wait"] = {"reason" => stop["reason"], "item" => stop["item"], "stopped_at" => now.utc.iso8601, "failed_item" => failed}
      File.write(@record_path, JSON.pretty_generate(record) + "\n")
      say "stopped waiting: #{stop["reason"]}#{" (item #{stop["item"]})" if stop["item"]}"
    end

    # The id of the newest finished item whose outcome was not a success, from the queue's history; nil when it cannot be found.
    def failed_item
      out = workspace_stdout("work-queue", "history", "list", "--json", *name_args)
      entries = JSON.parse(out)["entries"] || []
      entries.reverse.find { |entry| entry["outcome"].to_s.match?(/fail|cancel|error/) }&.dig("id")
    rescue Refused, JSON::ParserError
      nil
    end

    def read_queue_row
      out = workspace_stdout("work-queue", "list", "--json", *name_args)
      row = (JSON.parse(out)["queues"] || []).first
      raise Refused, "no work queue found for workspace #{@name || "(detected from the current directory)"}: check --name" unless row
      row
    end

    def read_events(path)
      return [] unless path && File.file?(path)
      File.foreach(path).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end

    def name_args = @name ? ["--name", @name] : []

    def preflight(branch)
      raise Refused, "the working tree has uncommitted changes: commit or discard them first" unless git("status", "--porcelain", *DemoCalculator.out_dir_exclude(@root, @out_dir)).empty?
      _, status = Open3.capture2("git", "-C", @root, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
      raise Refused, "branch #{branch} already exists" if status.success?
      current = git("rev-parse", "--abbrev-ref", "HEAD")
      return unless @base.nil? && current.start_with?(RUN_BRANCH_PREFIX)
      previous = previous_base_sha
      hint = previous ? " (the previous record's base_sha is #{previous})" : ""
      raise Refused, "HEAD is on #{current}, which holds a previous run's solutions: pass --base REF to say what to branch from#{hint}"
    end

    # Refuses, before anything changes, when the ref a demo restores its stub from is missing or lacks a stub path.
    def check_stub!
      ref = @config.stub_ref
      return unless ref && !@config.template_dir
      _, _, found = Open3.capture3("git", "-C", @root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      raise Refused, "the stub ref #{ref} does not name a commit: create or fetch it before running" unless found.success?
      @config.restored.each do |entry|
        path = "#{@config.demo_dir}/#{entry}"
        out, _, listed = Open3.capture3("git", "-C", @root, "ls-tree", "--name-only", ref, "--", path)
        raise Refused, "the stub ref #{ref} has no #{path}: it must hold the stub to restore" unless listed.success? && !out.strip.empty?
      end
    end

    def previous_base_sha
      newest = Dir.glob(File.join(runs_dir, "*", "run.json")).max
      newest && JSON.parse(File.read(newest))["base_sha"]
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def runs_dir = File.join(@root, @config.runs_dir)

    def switch_to(branch, base)
      say "+ git switch -c #{branch} #{base}"
      git("switch", "-c", branch, base) unless @dry_run
    end

    # The first commit of a run branch removes what would let an agent read how it is scored: the acceptance
    # tests, and this demo's README, which says where eval reads them from.
    def remove_acceptance_tests
      paths = [@config.acceptance_dir, @config.readme_path].select do |path|
        @dry_run ? File.exist?(File.join(@root, path)) : !git("ls-files", "--", path).empty?
      end
      say "no #{@config.acceptance_dir} to remove" unless paths.include?(@config.acceptance_dir)
      return if paths.empty?
      say "+ git rm -r #{paths.join(" ")} and commit"
      return if @dry_run
      git("rm", "-r", "-q", "--", *paths)
      git("commit", "-q", "-m", "Remove the acceptance tests from the run branch", "--", *paths)
      git("rev-parse", "HEAD")
    end

    def queue_items
      @config.queue_items.call(name_args).map do |workflow, argv|
        say "+ workspace #{argv.join(" ")}"
        id = JSON.parse(workspace_stdout(*argv)).dig("results", 0, "id") unless @dry_run
        {"workflow" => workflow, "id" => id}
      end
    end

    def write_record(stamp, branch, base_sha, workspace_sha, items, acceptance_sha = nil, removal_sha = nil)
      dir = @out_dir ? File.expand_path(@out_dir, @root) : File.join(runs_dir, stamp)
      path = File.join(dir, "run.json")
      if @dry_run
        say "would write #{path}"
        return
      end
      workflows = File.join(@root, @config.workflows_dir)
      record = RunRecord.build(
        stamp: stamp, base_sha: base_sha, branch: branch,
        workspace_sha: workspace_sha,
        workspace_version: JSON.parse(workspace_stdout("capabilities", "--json"))["version"],
        items: items,
        definitions: @config.definition_ids.to_h { |id| [id, File.read(File.join(workflows, "#{id}.yml"))] }
      )
      record["acceptance_ref"] = {"name" => @config.acceptance_ref, "sha" => acceptance_sha, "removal_sha" => removal_sha} if @config.acceptance_ref
      record.merge!(@config.record_extras) if @config.record_extras
      @record_path = path
      FileUtils.mkdir_p(dir)
      File.write(path, JSON.pretty_generate(record) + "\n")
      say "wrote #{path}"
      record
    end

    def workspace_stdout(*argv)
      out, err, status = Open3.capture3(@workspace, *argv, chdir: @root)
      @out.print err
      raise Refused, "workspace #{argv.first(2).join(" ")} failed (exit #{status.exitstatus})" unless status.success?
      out
    end

    def guard!
      branch = git("rev-parse", "--abbrev-ref", "HEAD")
      raise Refused, "refusing to run on #{branch}: use a demo branch in its own worktree" if %w[main master HEAD].include?(branch)
      git_dir = File.expand_path(git("rev-parse", "--git-dir"), @root)
      common = File.expand_path(git("rev-parse", "--git-common-dir"), @root)
      raise Refused, "refusing to run in the main checkout: use a worktree on a demo branch" if git_dir == common
    end

    def git(*args)
      out, status = Open3.capture2("git", "-C", @root, *args)
      raise Refused, "git #{args.join(" ")} failed in #{@root}" unless status.success?
      out.strip
    end

    def clear_queue
      items = read_queue
      self.class.queue_clearing(items, name_args: name_args).each { |argv| workspace(*argv) }
    end

    def read_queue
      return [] if @dry_run
      out, status = Open3.capture2(@workspace, "work-queue", "list", "--json", *name_args, chdir: @root)
      raise Refused, "work-queue list failed" unless status.success?
      (JSON.parse(out)["queues"] || []).flat_map { |queue| queue["items"] || [] }
    end

    def restore_files
      demo = File.join(@root, @config.demo_dir)
      @config.restored.each do |entry|
        say "restore #{@config.demo_dir}/#{entry}"
        next if @dry_run
        FileUtils.rm_rf(File.join(demo, entry))
        FileUtils.cp_r(File.join(demo, @config.template_dir, entry), File.join(demo, entry)) if @config.template_dir
      end
      restore_from_git unless @dry_run || @config.template_dir
      commit_restore
    end

    # The stub lives in git, at the ref the demo names, when it has no template directory.
    def restore_from_git
      paths = @config.restored.map { |entry| "#{@config.demo_dir}/#{entry}" }
      git("checkout", @config.stub_ref, "--", *paths)
    end

    # Points the acceptance ref at the run's base, which holds the acceptance tests, so the base stays an ancestor
    # of the run branch.
    #
    # @return [String, nil] that sha; nil when the demo has no acceptance ref
    def point_acceptance_ref(sha)
      return unless @config.acceptance_ref
      say "+ git update-ref #{@config.acceptance_ref} #{sha}"
      git("update-ref", @config.acceptance_ref, sha) unless @dry_run
      sha
    end

    def commit_restore
      paths = @config.restored.map { |entry| "#{@config.demo_dir}/#{entry}" }
      if @dry_run
        say "git commit the restored files if they differ from HEAD"
        return
      end
      git("add", "--all", "--", *paths)
      return if git("status", "--porcelain", "--", *paths).empty?
      git("commit", "-m", "Reset the #{File.basename(@config.demo_dir)} demo to its stub", "--", *paths)
      say "committed the reset"
    end

    def configure
      source = File.join(@root, @config.workflows_dir)
      current = @dry_run ? "" : capture(@workspace, "config", "get", "workflows.sources", chdir: @root)
      listed = current.split(/[,\n]/).map(&:strip).reject(&:empty?)
      suffix = @config.workflows_suffix
      merged = listed.map { |entry| entry.sub(%r{/+\z}, "") }.reject { |entry| entry != source && entry.end_with?(suffix) } | [source]
      workspace("config", "set", "workflows.sources", merged.join(",")) unless merged == listed
      workspace("workflow", "install")
      workspace("config", "set", "--scope", "workspace", *name_args, "commands.test", @config.test_command)
      workspace("config", "set", "--scope", "workspace", *name_args, "commands.lint", @config.lint_command) if @config.lint_command
    end

    def capture(*argv, chdir:)
      out, status = Open3.capture2(*argv, chdir: chdir)
      status.success? ? out.strip : ""
    end

    def workspace(*argv)
      say "+ workspace #{argv.join(" ")}"
      return if @dry_run
      out, status = Open3.capture2e(@workspace, *argv, chdir: @root)
      @out.print out
      raise Refused, "workspace #{argv.first(2).join(" ")} failed (exit #{status.exitstatus})" unless status.success?
    end

    def say(line)
      @out.puts line
    end
  end
end
