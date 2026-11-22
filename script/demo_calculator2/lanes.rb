require "fileutils"
require "json"
require "open3"
require "shellwords"
require "time"
require_relative "../demo_calculator/demo"
require_relative "config"
require_relative "event_waiter"
require_relative "shared_values"
require_relative "test_names"

module DemoCalculator2
  # Lane B's fork failed one of its three checks (HEAD, the acceptance base ref, ancestry); the run stops, since a lane
  # on the wrong commit would be scored against the wrong tests.
  class ForkCheckFailed < DemoCalculator::Refused; end

  # `run --lanes`: two workspaces deliver the goals at once. Lane A (the checkout the script sits in) runs 01-05 on the
  # run branch. Lane B, a second workspace that is running, idle and on main, is forked from the head lane A's goal 03
  # ended on and runs 06 and 07. When both queues drain, lane A merges lane B's branch and checks 1..7 with the plain
  # acceptance runner; a conflict or a failing check queues `integrate-branch` in lane A.
  #
  # Every command goes through the injected `exec`, so the fork and the integrate decision run in specs without git
  # or `workspace`.
  class Lanes
    MERGE_DRIVER = "calc-demo-tests".freeze
    ATTRIBUTES_LINE = "#{DEMO_DIR}/test/calc_test.rb merge=#{MERGE_DRIVER}".freeze
    # Queue outcomes that count as a goal delivered.
    SUCCESS = %w[succeeded completed].freeze
    # What joins a project name to a worktree suffix in a workspace name (Workspace::WorkspaceName::SEPARATOR).
    WORKTREE_SEPARATOR = ".worktree-"
    DRIVER_LINE = "LOOP DONE".freeze

    # @param root [String] lane A's checkout
    # @param workspace [String] the `workspace` program
    # @param lane_b [String, nil] lane B's workspace name; nil only for `integrate` over an existing run
    # @param workflow [String] the workflow both lanes' goals run as
    # @param name [String, nil] lane A's workspace name; nil lets `workspace` detect it
    # @param goals [Array<String>] the goals of the run, in GOALS order; each goes to its own lane
    # @param exec [#call] `call(argv, chdir:)` runs one command and returns `[stdout, success]`
    # @param clock [#call] returns the current Time
    # @param sleeper [#call] sleeps for the given seconds
    # @param waiter [#call, nil] `call(seconds, workspaces:)` returns when a queue event arrives or the seconds pass (and may answer `close`); nil sleeps with `sleeper`
    # @param poll [Numeric] the longest seconds one wait lasts
    # @param timeout [Numeric] seconds `--wait` may run in all
    # @param held_limit [Numeric] seconds an item may stay held
    # @param idle_wait [Numeric] the longest seconds lane B may take to show an idle agent pane before the run is refused
    # @param idle_poll [Numeric] seconds between snapshots while waiting for lane B to go idle
    def initialize(root:, workspace:, lane_b: nil, workflow: WORKFLOW_ID, name: nil, goals: GOALS, stub_ref: "main", base: nil, out_dir: nil,
      dry_run: false, wait: false, out: $stdout, err: $stderr, clock: -> { Time.now }, sleeper: ->(seconds) { sleep(seconds) },
      waiter: nil, poll: 5, timeout: 14_400, held_limit: 1200, idle_wait: 300, idle_poll: 5,
      exec: ->(argv, chdir:) {
        out, status = Open3.capture2(*argv, chdir: chdir)
        [out, status.success?]
      })
      @root = File.expand_path(root)
      @workspace = workspace
      @lane_b = lane_b
      @workflow = workflow
      @name = name
      @goals = goals
      @stub_ref = stub_ref
      @base = base
      @out_dir = out_dir
      @dry_run = dry_run
      @wait = wait
      @out = out
      @err = err
      @clock = clock
      @sleeper = sleeper
      @waiter = waiter || ->(seconds, workspaces: nil) { sleeper.call(seconds) }
      @poll = poll
      @timeout = timeout
      @held_limit = held_limit
      @idle_wait = idle_wait
      @idle_poll = idle_poll
      @exec = exec
    end

    # Checks lane B, starts lane A's queue and, with `wait`, drives the fork, the drain and the integration.
    #
    # @return [Hash, nil] the run record, whose `wait` says why it stopped; nil under `dry_run`
    # @raise [DemoCalculator::Refused] when a lane is not ready or a command fails before the queues run
    def run
      a_goals = DemoCalculator2.lane_goals(:a, @goals)
      b_goals = DemoCalculator2.lane_goals(:b, @goals)
      fork_goal = DemoCalculator2.fork_goal(@goals)
      raise DemoCalculator::Refused, "--lanes needs a lane A goal (01-05) at or before 03 to fork after, and a lane B goal (06, 07)" if fork_goal.nil? || b_goals.empty?
      raise DemoCalculator::Refused, "--lanes needs --lane-b WORKSPACE" unless @lane_b
      say_coverage(a_goals, b_goals)
      started = @clock.call
      stamp = started.utc.strftime("%Y%m%dT%H%M%SZ")
      branch_b = "#{DemoCalculator::RUN_BRANCH_PREFIX}#{stamp}-b"
      path_b = prepare_lane_b
      extras = {"lanes" => {"workflow" => @workflow, "started_at" => started.utc.iso8601, "fork_after" => fork_goal,
                            "a" => {"workspace" => @name, "goals" => a_goals}, "b" => {"workspace" => @lane_b, "path" => path_b, "branch" => branch_b, "goals" => b_goals, "items" => []}}}
      config = DemoCalculator2.lane_config(:a, workflow_id: @workflow, stub_ref: @stub_ref, goals: @goals, extras: extras)
      demo = DemoCalculator::Demo.new(root: @root, workspace: @workspace, name: @name, dry_run: @dry_run, out: @out, err: @err, base: @base,
        out_dir: @out_dir, clock: -> { started }, config: config)
      record = demo.run(before_start: -> {
        write_attributes(demo.record_path)
        write_out_exclude(demo.record_path)
      })
      if @dry_run
        say "would wait for lane A's #{fork_goal}, then in lane B: git checkout -B #{branch_b} <#{fork_goal}'s final head>, queue #{b_goals.join(", ")} and enable its queue"
        say "would then merge #{branch_b} in lane A and run the tests, lint and the plain acceptance runner on 07-repl (groups 1..7)"
        return nil
      end
      @record_path = demo.record_path
      @wait ? wait_run(@record_path) : record
    end

    # Runs the integration over a recorded run whose queues have drained, and prints the closing line.
    #
    # @param record_path [String] a run.json with a `lanes` block and a `fork`
    # @return [Hash] the record
    def integrate_run(record_path)
      @record_path = record_path
      record = JSON.parse(File.read(record_path))
      raise DemoCalculator::Refused, "#{record_path} has no lanes block: it is not a `run --lanes` record" unless record["lanes"].is_a?(Hash)
      raise DemoCalculator::Refused, "lane B has not forked in #{record_path}: there is nothing to merge" unless record["fork"].is_a?(Hash)
      @name ||= record.dig("lanes", "a", "workspace")
      @lane_b ||= record.dig("lanes", "b", "workspace")
      @loop_started = @clock.call
      drive(record) { integrate(record) }
      record
    end

    # Merges lane B's branch in lane A and decides first pass: a clean merge, then the test command, lint and the plain
    # 07-repl acceptance run, one attempt each. A conflict (merge aborted) or a failure of any of them records
    # `first_pass: false` and queues `integrate-branch` (`integrate-merged` after a clean merge) in lane A, then waits for it; its result is recorded apart.
    #
    # @param record [Hash] the run record; gets an `integration` block and is written back
    # @return [Hash, nil] a stop (`reason`, `item`) when waiting for integrate-branch stopped early
    def integrate(record)
      branch = record.dig("lanes", "b", "branch")
      integration = {"branch" => branch, "started_at" => @clock.call.utc.iso8601}
      record["integration"] = integration
      _, merged = git(@root, "merge", "--no-ff", "--no-edit", branch)
      if merged
        integration["merge"] = "clean"
        integration["conflict"] = false
        integration["first_pass"] = first_pass_checks(integration)
      else
        _, in_progress = git(@root, "rev-parse", "-q", "--verify", "MERGE_HEAD")
        git(@root, "merge", "--abort") if in_progress
        integration["merge"] = in_progress ? "conflict" : "failed"
        integration["conflict"] = in_progress
        integration["first_pass"] = false
      end
      save(record)
      # A clean merge whose checks failed stays committed on lane A's branch: integrate-merged starts from it and merges nothing more.
      stop = integration["first_pass"] ? nil : repair(record, integration, branch)
      head, = git(@root, "rev-parse", "HEAD")
      integration["head"] = head.to_s.strip
      integration["ended_at"] = @clock.call.utc.iso8601
      save(record)
      stop
    end

    # The checks a fork must pass before lane B runs anything; each failure is a refusal.
    #
    # @param lane_b_path [String] lane B's checkout
    # @param branch [String] the branch to create there
    # @param sha [String] the full sha lane A's fork goal ended on
    # @param acceptance_base [String] the sha lane A's run recorded for refs/demo-calc2/acceptance-base
    # @return [void]
    # @raise [ForkCheckFailed] when checking out fails, HEAD is not sha, the acceptance ref is missing or differs, or it is not an ancestor of sha
    def fork_check!(lane_b_path, branch, sha, acceptance_base)
      _, ok = git(lane_b_path, "checkout", "-B", branch, sha)
      raise ForkCheckFailed, "git checkout -B #{branch} #{sha} failed in #{lane_b_path}" unless ok
      head, = git(lane_b_path, "rev-parse", "HEAD")
      raise ForkCheckFailed, "lane B's HEAD is #{head.to_s.strip[0, 12]}, not the fork point #{sha[0, 12]}" unless head.to_s.strip == sha
      ref, found = git(lane_b_path, "rev-parse", ACCEPTANCE_REF)
      raise ForkCheckFailed, "lane B cannot see #{ACCEPTANCE_REF}" unless found
      raise ForkCheckFailed, "#{ACCEPTANCE_REF} is #{ref.strip[0, 12]} in lane B, not #{acceptance_base.to_s[0, 12]} as lane A's run recorded" unless ref.strip == acceptance_base
      _, ancestor = git(lane_b_path, "merge-base", "--is-ancestor", ACCEPTANCE_REF, sha)
      raise ForkCheckFailed, "#{ACCEPTANCE_REF} is not an ancestor of the fork point #{sha[0, 12]}" unless ancestor
    end

    # Adds `calc_test.rb merge=calc-demo-tests` to `info/attributes` in the shared git dir, and sets `merge.calc-demo-tests.name`
    # and `.driver` in that repository's local config. Every goal appends test methods to that file, and the driver
    # (`merge_test_methods`) keeps both lanes' added methods whole, where `merge=union` interleaved their `end` lines. The driver
    # command names no path (`$(git rev-parse --show-toplevel)`), so every checkout writes the same value and a killed worktree cannot leave it dangling.
    # Each value is classified first ({SharedValues}): written when absent or dangling, left when equal, and a driver that belongs to
    # another live checkout refuses the run. The file and the config are shared by every worktree and are part of no diff. The run
    # record gets `merge_driver` with what was written (the line and the config section), whether anything was, and the driver value it replaced.
    #
    # @param record_path [String, nil] the run.json to record what was written in
    # @return [void]
    # @raise [DemoCalculator::Refused] when the driver config names another live checkout
    def write_attributes(record_path = nil)
      config = {"merge.#{MERGE_DRIVER}.name" => "calc_test.rb: keep both lanes' added test methods", "merge.#{MERGE_DRIVER}.driver" => SharedValues::DRIVER_COMMAND}
      live = config.keys.to_h { |key| [key, live_config(key)] }
      states = config.to_h { |key, value| [key, shared_state("git-config:#{key}", live[key], value)] }
      driver_key = "merge.#{MERGE_DRIVER}.driver"
      if states[driver_key] == :foreign_live
        value = live[driver_key]
        raise DemoCalculator::Refused, SharedValues.refusal(SharedValues::DRIVER_KEY, value, SharedValues.owner_path(SharedValues::DRIVER_KEY, value))
      end
      line_state = shared_state("attributes:#{ATTRIBUTES_LINE}", live_attributes_line, ATTRIBUTES_LINE)
      path = (line_state == :equal) ? attributes_path : append_info_line("attributes", ATTRIBUTES_LINE)
      written = line_state != :equal
      config.each do |key, value|
        next if states[key] == :equal
        written = true
        say "+ git config --local #{key} #{value.inspect}"
        git(@root, "config", "--local", key, value) unless @dry_run
      end
      return if @dry_run || record_path.nil?
      replaced = (states[driver_key] == :dangling) ? live[driver_key] : nil
      @record_path = record_path
      record = JSON.parse(File.read(record_path))
      save(record.merge("merge_driver" => {"attributes_path" => path, "attributes_line" => ATTRIBUTES_LINE, "config_section" => "merge.#{MERGE_DRIVER}",
                                           "driver" => SharedValues::DRIVER_COMMAND, "written" => written, "replaced" => replaced}))
    end

    # Adds an anchored line for the run's own output directory (`--out`, else the default under `tmp/`) to `info/exclude` in the shared git dir, once, so no process that
    # checks a checkout for untracked files (the acceptance runner, integrate-branch) sees the run's log and record. Does nothing
    # when that directory lies outside this checkout. The line is recorded in the run record as `out_exclude`.
    #
    # @param record_path [String, nil] the run.json to record the line in
    # @return [void]
    def write_out_exclude(record_path)
      dir = record_path ? File.dirname(record_path) : @out_dir && File.expand_path(@out_dir, @root)
      rel = DemoCalculator.out_dir_relative(@root, dir)
      return unless rel
      line = "/#{rel}/"
      path = append_info_line("exclude", line)
      return if @dry_run || record_path.nil?
      @record_path = record_path
      record = JSON.parse(File.read(record_path))
      save(record.merge("out_exclude" => {"path" => path, "line" => line}))
    end

    def info_path(file)
      dir, ok = git(@root, "rev-parse", "--git-common-dir")
      raise DemoCalculator::Refused, "cannot find the shared git dir in #{@root}" unless ok
      File.join(File.expand_path(dir.strip, @root), "info", file)
    end

    def attributes_path = info_path("attributes")

    def live_config(key)
      out, ok = git(@root, "config", "--local", "--get", key)
      (ok && !out.to_s.strip.empty?) ? out.to_s.strip : nil
    end

    def live_attributes_line
      path = attributes_path
      return nil unless File.exist?(path)
      File.readlines(path, chomp: true).map(&:strip).reverse.find { |line| line.start_with?("#{DEMO_DIR}/test/calc_test.rb ") }
    end

    def shared_state(key, live, wanted)
      SharedValues.classify(key, live: live, wanted: wanted, path_exists: ->(path) { File.directory?(path) })
    end

    def append_info_line(file, line)
      path = info_path(file)
      say "+ add `#{line}` to #{path}"
      return path if @dry_run
      existing = File.exist?(path) ? File.read(path) : ""
      return path if existing.lines.map(&:strip).include?(line)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, existing + ((existing.empty? || existing.end_with?("\n")) ? "" : "\n") + line + "\n")
      path
    end

    # Runs the wait, the fork and the integration over a recorded run, as `run --wait` does after it queues, and prints the closing line.
    #
    # @param record_path [String] a run.json written by `run --lanes`
    # @return [Hash] the record
    def wait_run(record_path)
      @record_path = record_path
      record = JSON.parse(File.read(record_path))
      raise DemoCalculator::Refused, "#{record_path} has no lanes block: it is not a `run --lanes` record" unless record["lanes"].is_a?(Hash)
      @name ||= record.dig("lanes", "a", "workspace")
      @lane_b ||= record.dig("lanes", "b", "workspace")
      @loop_started = @clock.call
      drive(record) { wait_loop(record, watch: [[:a, @name]], fork_pending: true) || integrate(record) }
      record
    end

    # @param seconds [Numeric]
    # @return [String] such as `24m10s`
    def self.duration(seconds)
      whole = seconds.round
      format("%dm%02ds", whole / 60, whole % 60)
    end

    # Lane B must be running, with an idle agent pane, a clean checkout reachable from the stub ref and an empty,
    # disabled queue; the queue is emptied and disabled here.
    #
    # @return [String, nil] lane B's checkout path; nil under dry_run
    def prepare_lane_b
      if @dry_run
        say "would check that lane B (#{@lane_b}) is running, has an idle agent pane and a clean checkout on #{@stub_ref}, then empty and disable its queue"
        return nil
      end
      member = wait_for_idle_lane_b
      path = member["path"].to_s
      raise DemoCalculator::Refused, "lane B's checkout is not a directory: #{path}" unless File.directory?(path)
      status, = git(path, "status", "--porcelain", *DemoCalculator.out_dir_exclude(path, @out_dir && File.expand_path(@out_dir, @root)))
      raise DemoCalculator::Refused, "lane B's checkout has uncommitted changes" unless status.to_s.strip.empty?
      _, on_stub = git(path, "merge-base", "--is-ancestor", "HEAD", @stub_ref)
      raise DemoCalculator::Refused, "lane B's HEAD is not on #{@stub_ref}: it must start from main, not a run branch" unless on_stub
      clear_lane_b_queue
      path
    end

    private

    def say(line) = @out.puts(line)

    def say_coverage(a_goals, b_goals)
      coverage = DemoCalculator2.group_coverage(a_goals + b_goals)
      lines = {"A" => a_goals, "B" => b_goals}.map { |lane, goals| "  lane #{lane}: " + goals.map { |goal| "#{goal[0, 2]} groups #{coverage[goal].join(",")}" }.join("; ") }
      check = DemoCalculator2.coverage_check(a_goals + b_goals)
      say "group coverage of each item's own check (acceptance_runner_lanes):"
      lines.each { |line| say line }
      integration_only = check[:integration_only].empty? ? "none" : check[:integration_only].join(",")
      say "  groups no item's own check runs, covered only by the plain 07-repl run after the merge (groups 1..7): #{integration_only}"
    end

    def name_args(name) = name ? ["--name", name] : []

    def git(dir, *args)
      out, ok = @exec.call(["git", *args], chdir: dir)
      [out, ok]
    end

    def workspace_json(*argv)
      out, ok = @exec.call([@workspace, *argv], chdir: @root)
      raise DemoCalculator::Refused, "workspace #{argv.first(2).join(" ")} failed" unless ok
      JSON.parse(out)
    rescue JSON::ParserError
      raise DemoCalculator::Refused, "workspace #{argv.first(2).join(" ")} did not print JSON"
    end

    def workspace_do(*argv)
      say "+ workspace #{argv.join(" ")}"
      return if @dry_run
      _, ok = @exec.call([@workspace, *argv], chdir: @root)
      raise DemoCalculator::Refused, "workspace #{argv.first(2).join(" ")} failed" unless ok
    end

    def save(record)
      File.write(@record_path, JSON.pretty_generate(record) + "\n")
    end

    # Lane B's snapshot member once it is running with an idle agent pane. Only a missing idle pane is waited on, every
    # `idle_poll` seconds up to `idle_wait`; any other problem refuses at once.
    def wait_for_idle_lane_b
      deadline = nil
      loop do
        doc = workspace_json("snapshot", "--json", "--name", @lane_b)
        member = (doc["projects"] || []).flat_map { |project| project["members"] || [] }.find { |each| same_workspace?(each["workspace"], @lane_b) }
        raise DemoCalculator::Refused, "no workspace named #{@lane_b} (lane B): start it first" unless member
        raise DemoCalculator::Refused, "lane B (#{@lane_b}) is not running" unless member["running"]
        return member if Array(member["panes"]).any? { |pane| pane["kind"] == "claude" && %w[idle done].include?(pane["state"]) }
        now = @clock.call
        unless deadline
          deadline = now + @idle_wait
          say "waiting up to #{@idle_wait}s for lane B (#{@lane_b}) to have an idle Claude Code pane"
        end
        raise DemoCalculator::Refused, "lane B (#{@lane_b}) has no idle Claude Code pane" if now + @idle_poll > deadline
        @sleeper.call(@idle_poll)
      end
    end

    # Whether a workspace name the CLI reports is the one the person passed: the same name, or a worktree workspace whose
    # name after ".worktree-" is it, as WorkspaceName#for_input settles a short name; case is ignored.
    def same_workspace?(reported, given)
      return false if reported.nil? || given.nil?
      suffix = reported.split(WORKTREE_SEPARATOR, 2)[1]
      reported.casecmp?(given) || (!suffix.nil? && suffix.casecmp?(given))
    end

    def clear_lane_b_queue
      row = queue_row(@lane_b)
      DemoCalculator::Demo.queue_clearing(row["items"] || [], name_args: name_args(@lane_b)).each { |argv| workspace_do(*argv) }
      row = queue_row(@lane_b)
      empty = (row["items"] || []).empty?
      raise DemoCalculator::Refused, "lane B's queue is not empty and off after clearing it" if !empty || row["state"] != "off"
    end

    def queue_row(name)
      row = (workspace_json("work-queue", "list", "--json", *name_args(name))["queues"] || []).first
      raise DemoCalculator::Refused, "no work queue found for workspace #{name || "(detected from the current directory)"}: check --name" unless row
      row
    end

    def history(name)
      workspace_json("work-queue", "history", "list", "--json", *name_args(name))["entries"] || []
    end

    # Ends the run with exactly one LOOP DONE line: the block's stop (or nil when every queue drained and the integration is
    # done) decides which, and so does any failure of a command on the way.
    def drive(record)
      conclude(record, yield)
    rescue DemoCalculator::Refused, SystemCallError, JSON::ParserError, ArgumentError, TypeError => e
      @err.puts "demo-calculator2: #{e.message}"
      stop_run(record, {"reason" => "error", "item" => nil})
    ensure
      @waiter.close if @waiter.respond_to?(:close)
    end

    def stop_run(record, stop)
      record["wait"] = {"reason" => stop["reason"], "item" => stop["item"], "stopped_at" => @clock.call.utc.iso8601, "failed_item" => failed_item}
      say "#{DRIVER_LINE}: stopped reason=#{stop["reason"]}#{" item=#{stop["item"]}" if stop["item"]}"
      save(record)
    rescue SystemCallError => e
      @err.puts "demo-calculator2: cannot write #{@record_path}: #{e.message}"
    end

    def conclude(record, stop)
      return stop_run(record, stop) if stop
      integration = record["integration"]
      repair = integration["integrate_run"]
      return stop_run(record, {"reason" => "integrate_failed", "item" => repair["item"]}) if repair && !repair["passed"]
      first_start = first_item_start(record)
      wall = Time.parse(integration["ended_at"].to_s) - (first_start || Time.parse(record.dig("lanes", "started_at").to_s))
      done, total = items_delivered(record)
      line = "#{DRIVER_LINE}: wall=#{self.class.duration(wall)} integration=#{repair ? "integrate" : "clean"} first_pass=#{integration["first_pass"]} items=#{done}/#{total}"
      record["lanes"]["first_item_at"] = first_start&.utc&.iso8601 if record["lanes"]
      record["wait"] = {"reason" => "empty", "item" => nil, "stopped_at" => @clock.call.utc.iso8601, "failed_item" => nil}
      save(record)
      say line
    end

    # When lane A's first item's first attempt started. The eval's wall begins at the run's own start, a little earlier, so the two walls differ by the dispatch latency. Nil when it can't be read.
    def first_item_start(record)
      first = record["items"].first
      entry = first && history(@name).find { |each| each["id"] == first["id"] }
      run_id = entry&.dig("result", "run_id")
      return nil unless run_id
      times = Array(workspace_json("workflow", "attempts", run_id, "--json")["attempts"]).filter_map { |row| Time.parse(row["started_at"].to_s) if row["started_at"] }
      times.min
    rescue DemoCalculator::Refused, ArgumentError
      nil
    end

    # The newest finished item, in either lane, whose outcome was not a success.
    def failed_item
      [@name, @lane_b].uniq.flat_map { |name| history(name) }.reverse.find { |entry| entry["outcome"].to_s.match?(/fail|cancel|error/) }&.dig("id")
    rescue DemoCalculator::Refused
      nil
    end

    def items_delivered(record)
      a_ids = record["items"].map { |item| item["id"] }
      b_ids = Array(record.dig("lanes", "b", "items")).map { |item| item["id"] }
      done = history(@name).count { |entry| a_ids.include?(entry["id"]) && SUCCESS.include?(entry["outcome"]) }
      done += history(@lane_b).count { |entry| b_ids.include?(entry["id"]) && SUCCESS.include?(entry["outcome"]) } unless b_ids.empty?
      [done, a_ids.size + b_ids.size]
    end

    # Polls the watched queues every `poll` seconds, forking lane B when lane A's fork goal finishes, until they all
    # drain or one of Wait.stop_reason's reasons (or `fork_check`) says stop.
    #
    # @return [Hash, nil] `reason` and `item`; nil when every watched queue drained
    def wait_loop(record, watch:, fork_pending:)
      feature = workspace_json("capabilities", "--json").dig("features", "work_queue")
      first_seen = {}
      fork_item = record["items"][record["goals"].index(record.dig("lanes", "fork_after"))]["id"] if fork_pending
      loop do
        now = @clock.call
        if fork_pending
          entry = history(@name).find { |each| each["id"] == fork_item }
          if entry && SUCCESS.include?(entry["outcome"])
            begin
              fork!(record, entry)
            rescue ForkCheckFailed => e
              @err.puts "demo-calculator2: #{e.message}"
              return {"reason" => "fork_check", "item" => fork_item}
            end
            fork_pending = false
            watch += [[:b, @lane_b]]
          elsif entry
            return {"reason" => "fork_check", "item" => fork_item}
          end
        end
        drained = true
        rows = watch.map { |_, name| queue_row(name) }
        rows.each do |row|
          items = row["items"] || []
          items.each { |item| first_seen[item["id"]] ||= now if item["state"] == "held" }
          held_since = DemoCalculator::Wait.held_since(events: [], items: items, first_seen: first_seen)
          stop = DemoCalculator::Wait.stop_reason(row, now: now, started_at: @loop_started, held_since: held_since, held_limit: @held_limit, timeout: @timeout)
          if stop.nil?
            drained = false
          elsif stop["reason"] != "empty"
            return stop
          end
        end
        if fork_pending && drained
          next if history(@name).any? { |each| each["id"] == fork_item }
          @err.puts "demo-calculator2: lane A's queue drained before the fork goal's item finished"
          return {"reason" => "fork_check", "item" => fork_item}
        end
        return nil if drained && !fork_pending
        rows.zip(watch).each do |row, (_, name)|
          workspace_do("work-queue", "advance", *name_args(name)) if DemoCalculator::Wait.advance?(row, work_queue_feature: feature)
        end
        @waiter.call(@poll, workspaces: [@name, @lane_b].compact.uniq)
      end
    end

    # Forks lane B at the head lane A's fork goal ended on (never lane A's HEAD, which a later goal may have moved),
    # checks the fork, sets lane B's commands, queues its goals and starts its queue.
    def fork!(record, entry)
      run_id = entry.dig("result", "run_id")
      raise ForkCheckFailed, "the fork goal's queue entry names no run" unless run_id
      sha = resolve(final_head(run_id))
      fork_check!(record.dig("lanes", "b", "path"), record.dig("lanes", "b", "branch"), sha, record.dig("acceptance_ref", "sha"))
      record["fork"] = {"at" => @clock.call.utc.iso8601, "sha" => sha, "acceptance_base" => record.dig("acceptance_ref", "sha"),
        "goal" => record.dig("lanes", "fork_after"), "item" => entry["id"], "run_id" => run_id}
      b_name = name_args(@lane_b)
      config = DemoCalculator2.lane_config(:b, workflow_id: @workflow, stub_ref: @stub_ref, goals: record.dig("lanes", "b", "goals"))
      workspace_do("config", "set", "--scope", "workspace", *b_name, "commands.test", config.test_command)
      workspace_do("config", "set", "--scope", "workspace", *b_name, "commands.lint", config.lint_command)
      goals = record.dig("lanes", "b", "goals")
      record.dig("lanes", "b")["items"] = config.queue_items.call(b_name).zip(goals).map do |(workflow, argv), goal|
        say "+ workspace #{argv.join(" ")}"
        {"workflow" => workflow, "id" => workspace_json(*argv).dig("results", 0, "id"), "goal" => goal}
      end
      save(record)
      DemoCalculator::Demo.starting(name_args: b_name).each { |argv| workspace_do(*argv) }
    end

    # @return [String] the head after the last attempt that recorded one, else the head the last began on
    def final_head(run_id)
      rows = Array(workspace_json("workflow", "attempts", run_id, "--json")["attempts"])
      heads = rows.map { |row| row["head"] }.grep(Hash)
      sha = heads.reverse.filter_map { |head| head["after"] }.find { |value| value.is_a?(String) && !value.empty? }
      sha ||= heads.reverse.filter_map { |head| head["before"] }.find { |value| value.is_a?(String) && !value.empty? }
      raise ForkCheckFailed, "run #{run_id} recorded no head to fork from" unless sha
      sha
    end

    def resolve(sha)
      full, ok = git(@root, "rev-parse", "--verify", "#{sha}^{commit}")
      raise ForkCheckFailed, "#{sha} is not a commit in #{@root}" unless ok
      full.strip
    end

    # The duplicate test-name scan of the merged calc_test.rb, then one attempt each at the test command, lint and the plain acceptance runner on 07-repl, stopping at the first failure.
    def first_pass_checks(integration)
      return false unless test_names_clean?(integration)

      config = DemoCalculator2.config
      commands = {
        "test" => ["sh", "-c", config.test_command],
        "lint" => ["sh", "-c", config.lint_command],
        "acceptance" => [File.join(@root, ACCEPTANCE_RUNNER), "#{DEMO_DIR}/goals/07-repl.md"]
      }
      commands.each do |key, argv|
        output, ok = @exec.call(argv, chdir: @root)
        integration[key] = ok
        unless ok
          say "first-pass check #{key} failed: #{argv.join(" ")}"
          say output.to_s.lines.last(40).join.chomp
        end
        return false unless ok
      end
      true
    end

    def test_names_clean?(integration)
      path = File.join(@root, DEMO_DIR, "test", "calc_test.rb")
      duplicates = File.exist?(path) ? MergeTestMethods.duplicate_names(File.read(path)) : []
      integration["test_names"] = {"ok" => duplicates.empty?, "duplicates" => duplicates}
      say "first-pass check test_names failed: duplicate test methods in #{DEMO_DIR}/test/calc_test.rb: #{duplicates.join(", ")}" unless duplicates.empty?
      duplicates.empty?
    end

    # Queues the repair in lane A, waits for it and records its outcome apart from the first pass: integrate-merged after a
    # clean merge (nothing left to merge), integrate-branch after a conflict or a failed merge.
    def repair(record, integration, branch)
      merged = integration["merge"] == "clean"
      argv = DemoCalculator2.integrate_argv(branch, name_args(@name), merged: merged)
      integration["repair_workflow"] = argv[3]
      say "+ workspace #{argv.join(" ")}"
      id = workspace_json(*argv).dig("results", 0, "id")
      integration["integrate_run"] = {"item" => id, "queued_at" => @clock.call.utc.iso8601}
      save(record)
      DemoCalculator::Demo.starting(name_args: name_args(@name)).each { |each| workspace_do(*each) }
      stop = wait_loop(record, watch: [[:a, @name]], fork_pending: false)
      entry = history(@name).find { |each| each["id"] == id }
      integration["integrate_run"].merge!("outcome" => entry && entry["outcome"], "run_id" => entry&.dig("result", "run_id"), "passed" => !entry.nil? && SUCCESS.include?(entry["outcome"]))
      stop
    end
  end
end
