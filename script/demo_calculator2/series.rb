require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"

require_relative "../demo_calculator/demo"
require_relative "config"
require_relative "series_registry"
require_relative "shared_values"

module DemoCalculator2
  # One command that runs a whole lanes run: start the two workspaces, share the merge driver and the definitions, run, collect
  # evidence and clean up. This part is the options, the read-only exec of `--dry-run` and the step 1 preflight, which reads and
  # never writes.
  class Series
    ID_PATTERN = /\A[a-z][a-z0-9]*\z/
    MERGE_DRIVER = SharedValues::MERGE_DRIVER
    ATTRIBUTES_LINE = SharedValues::ATTRIBUTES_LINE
    NAME_KEY = SharedValues::NAME_KEY
    NAME_VALUE = SharedValues::NAME_VALUE
    SOURCES_KEY = "workflows.sources".freeze
    # `workflow status --all --json` does not say which locks a run uses, so a run of these workflows counts as holding `test-db`.
    TEST_DB_WORKFLOWS = [INTEGRATE_WORKFLOW_ID].freeze
    DEFAULT_WORKFLOW = "deliver-goal-fast".freeze
    FINISHED_STATES = %w[completed cancelled failed].freeze
    # The launcher `--sonnet` sets as `agent.commands.claude` (see `workspace agent executables --kind claude`).
    SONNET_COMMAND = "claude-sonnet".freeze
    IDLE_WAIT = 300
    IDLE_POLL = 5
    IDLE_STATES = %w[idle done].freeze
    LOOP_DONE = "LOOP DONE".freeze

    # A refusal before anything started: exit 1, nothing to clean.
    class Refused < DemoCalculator::Refused; end

    # A stop after step 2 began: exit 3, and the cleanup of T14 runs for what exists.
    class Stopped < StandardError; end

    # The default exec: runs argv, answers `[stdout, success]` and keeps stderr apart in {#last_stderr}, so a note on stderr can
    # never break a JSON read.
    class RealExec
      attr_reader :last_stderr

      # @return [Array(String, Boolean)]
      def call(argv, chdir:)
        out, @last_stderr, status = Open3.capture3(*argv, chdir: chdir)
        [out, status.success?]
      rescue SystemCallError => e
        @last_stderr = e.message
        ["", false]
      end
    end

    # The default run: spawns argv with stdout and stderr appended to `log`, waits and answers the exit status (nil when the
    # program could not start).
    RUN_LOGGED = lambda do |argv, chdir:, log:|
      FileUtils.mkdir_p(File.dirname(log))
      pid = Process.spawn(*argv, :chdir => chdir, [:out, :err] => [log, "a"])
      Process.wait(pid)
      $?.exitstatus
    rescue SystemCallError => e
      File.write(log, "#{e.message}\n", mode: "a")
      nil
    end

    # A `--dry-run` exec was asked for a command that could write.
    class DryRunWrite < StandardError; end

    Options = Struct.new(:id, :lanes, :workflow, :sonnet, :base, :keep, :evidence_dir, :scoreboard, :dry_run, :take_over, :forget, keyword_init: true)

    # One shared value as preflight saw it: what it is now, its classification and what a series would do with it.
    Shared = Struct.new(:key, :live, :wanted, :state, :action, keyword_init: true)

    # What preflight found: the shared values and the stale ids it only reports.
    Report = Struct.new(:shared, :stale, keyword_init: true)

    # Runs only commands that read, for `--dry-run`. Anything else raises {DryRunWrite}.
    class ReadOnlyExec
      GIT = %w[rev-parse show-ref worktree for-each-ref merge-base show].freeze
      WORKSPACE = [%w[status], %w[list], %w[lock status], %w[config get], %w[config show], %w[snapshot], %w[workflow show], %w[workflow status]].freeze

      # @param exec [#call] the real `call(argv, chdir:)`, answering `[output, ok]`
      def initialize(exec)
        @exec = exec
      end

      # @return [Array] what the wrapped exec answers
      # @raise [DryRunWrite] unless argv is on the allowlist
      def call(argv, **opts)
        raise DryRunWrite, "dry run would have run: #{argv.join(" ")}" unless allowed?(argv)
        @exec.call(argv, **opts)
      end

      private

      def allowed?(argv)
        program, *rest = argv
        case File.basename(program.to_s)
        when "git" then git_allowed?(rest)
        when "gh" then rest.first(2) == %w[run list]
        when "workspace" then WORKSPACE.any? { |words| rest.first(words.size) == words }
        else false
        end
      end

      def git_allowed?(rest)
        case rest.first
        when "worktree" then rest[1] == "list"
        when "config" then rest[1] == "--get" || rest[1..2] == %w[--local --get]
        when "show" then rest.none? { |arg| arg.start_with?("--output") }
        else GIT.include?(rest.first)
        end
      end
    end

    # @param argv [Array<String>] the words after `series`
    # @return [Options] frozen
    # @raise [OptionParser::ParseError] on a bad option
    def self.parse(argv)
      o = Options.new(lanes: 2, workflow: DEFAULT_WORKFLOW, base: "main", sonnet: false, keep: false, dry_run: false, take_over: false)
      OptionParser.new do |p|
        p.on("--id ID") { |v| o.id = v }
        p.on("--lanes N", Integer) { |v| o.lanes = v }
        p.on("--workflow ID") { |v| o.workflow = v }
        p.on("--sonnet") { o.sonnet = true }
        p.on("--base REF") { |v| o.base = v }
        p.on("--keep") { o.keep = true }
        p.on("--evidence-dir DIR") { |v| o.evidence_dir = v }
        p.on("--scoreboard FILE") { |v| o.scoreboard = v }
        p.on("--dry-run") { o.dry_run = true }
        p.on("--take-over") { o.take_over = true }
        p.on("--forget ID") { |v| o.forget = v }
      end.parse!(argv.dup)
      raise OptionParser::MissingArgument, "--id" if o.id.nil? && o.forget.nil?
      raise OptionParser::InvalidArgument, "--lanes: only 2 is supported" unless o.lanes == 2
      o.freeze
    end

    # @param root [String] the checkout `series` runs from
    # @param options [Options]
    # @param exec [#call] `call(argv, chdir:)` answering `[stdout, ok]`: stdout only, with stderr kept apart (a note
    #   on stderr must never break the JSON read); give a {ReadOnlyExec} for a dry run
    # @param registry [SeriesRegistry] read-only for a dry run
    # @param out [#puts]
    # @param workspace [String] the workspace program
    # @param read_file [#call] `call(path)` answering the text, or nil when there is no such file
    # @param path_exists [#call] `call(path)` says whether a checkout or directory exists
    # @param write_file [#call] `call(path, text)` writes a file, making its directory
    # @param run_logged [#call] `call(argv, chdir:, log:)` runs the run with its output appended to `log` and answers the exit status
    # @param clock [#call] seconds, for the idle wait's cap
    # @param sleeper [#call] `call(seconds)`
    # @param copy_dir [#call] `call(from, to)` copies a directory's contents into `to`, making it
    # @param command [String, nil] the series command line `command.txt` records (default: rebuilt from the options)
    def initialize(root:, options:, exec:, registry:, out: $stdout, err: $stderr, workspace: "workspace",
      read_file: ->(path) { File.file?(path) ? File.read(path) : nil }, path_exists: ->(path) { File.directory?(path) },
      write_file: ->(path, text) { FileUtils.mkdir_p(File.dirname(path)) && File.write(path, text) }, run_logged: RUN_LOGGED,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) },
      idle_wait: IDLE_WAIT, idle_poll: IDLE_POLL,
      copy_dir: ->(from, to) { FileUtils.mkdir_p(to) && FileUtils.cp_r(File.join(from, "."), to) }, command: nil)
      @copy_dir = copy_dir
      @command = command
      @write_file = write_file
      @run_logged = run_logged
      @clock = clock
      @sleeper = sleeper
      @idle_wait = idle_wait
      @idle_poll = idle_poll
      @root = root
      @options = options
      @exec = (options.dry_run && !exec.is_a?(ReadOnlyExec)) ? ReadOnlyExec.new(exec) : exec
      raise ArgumentError, "a dry run needs a read-only registry" if options.dry_run && !registry.read_only?
      @registry = registry
      @out = out
      @err = err
      @workspace = workspace
      @read_file = read_file
      @path_exists = path_exists
    end

    # @return [Integer] 0 when the run ends on `items=7/7`, 3 on a stop after step 2 began, 1 on a refusal before it. A dry run ends
    #   after preflight with 0.
    def call
      return forget if @options.forget
      report = preflight
      say_report(report)
      return 0 if @options.dry_run
      run_steps
    rescue Refused, SeriesRegistry::Corrupt => e
      @err.puts "demo-calculator2: series refused: #{e.message}"
      1
    end

    # Step 1. Reads only.
    # @return [Report]
    # @raise [Refused] with the first problem found
    def preflight
      check_id
      check_unused
      check_base
      check_ci
      check_test_db
      shared = check_shared_values
      check_definitions
      Report.new(shared: shared, stale: @registry.stale)
    end

    # One row of the scoreboard, from what eval and the run record say. Every field is nil when its source is missing.
    # @param eval_doc [Hash, nil] eval.json
    # @param run [Hash, nil] run.json
    # @param concurrent [Integer] the other series registered when this one started
    # @param id [String, nil] the series id
    # @param evidence [String, nil] where the evidence is
    # @return [String] one Markdown table row, in the column order of the build-loop scoreboard; `?` for a value eval does not have.
    #   The concurrent count goes in the failure-class column as `concurrent=N`, because eval does not classify failures.
    def self.scoreboard_row(eval_doc, run, concurrent:, id: nil, evidence: nil)
      doc = eval_doc.is_a?(Hash) ? eval_doc : {}
      run = run.is_a?(Hash) ? run : {}
      totals = doc["totals"] || {}
      lanes = doc["lanes"] || {}
      unknown = DemoCalculator::Fmt::UNKNOWN
      goal_walls = %w[01 02 03 04 05 06 07].map do |number|
        row = Array(doc["rows"]).find { |each| each["goal"].to_s.start_with?(number) && each["ran"] }
        DemoCalculator::Fmt.duration(row && row["wall"])
      end
      integration = lanes.dig("integration", "first_pass")
      integration_text = yes_no(integration)
      goals_pass = totals["first_pass"]
      goals_text = goals_pass.nil? ? unknown : "#{goals_pass}/#{totals["items"]}"
      overall = if goals_pass.nil? || integration.nil? then unknown
      elsif goals_pass == totals["items"] && integration then "yes"
      else "no"
      end
      completed = totals.dig("states", "completed")
      cost = totals["cost_usd"]
      bound = Array(totals["partial"]).include?("cost_usd") ? "≥" : "≈"
      cost_text = cost.nil? ? unknown : format("%s$%.2f", bound, cost)
      leak = doc["leak"]
      leaks = leak ? leaks_text(leak) : unknown
      cells = [
        id || unknown, run["base_sha"] ? run["base_sha"][0, 8] : unknown, date_text(run["stamp"]), DemoCalculator::Fmt.duration(lanes["wall"]),
        *goal_walls, "#{overall} (#{goals_text} goals; integration #{integration_text})",
        completed.nil? ? unknown : "#{completed}/#{totals["items"]}", cost_text, leaks, unknown, "concurrent=#{concurrent}", evidence || unknown
      ]
      "| #{cells.map { |cell| cell.to_s.gsub("|", "\\|").tr("\n", " ") }.join(" | ")} |"
    end

    # The wording of EvalReport.leak_line: an unreadable transcript is not a zero.
    def self.leaks_text(leak)
      counts = Hash(leak["transcript"]).values
      unreadable = counts.count(&:nil?)
      return DemoCalculator::Fmt::UNKNOWN if unreadable > 0 && unreadable == counts.size
      text = "#{leak["hook"].to_i + counts.compact.sum} confirmed"
      (unreadable > 0) ? "#{text} (#{unreadable} of #{counts.size} unreadable)" : text
    end

    def self.yes_no(value)
      return DemoCalculator::Fmt::UNKNOWN if value.nil?
      value ? "yes" : "no"
    end

    # @return [String] a run stamp like `20261121T150800Z` as `2026-11-21 15:08`, or `?`
    def self.date_text(stamp)
      match = /\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})/.match(stamp.to_s)
      match ? "#{match[1]}-#{match[2]}-#{match[3]} #{match[4]}:#{match[5]}" : DemoCalculator::Fmt::UNKNOWN
    end

    private

    def id = @options.forget || @options.id

    # `--forget ID`: steps 8 and 9 for an id the registry still holds (a series that crashed or ran with `--keep`).
    def forget
      raise Refused, "#{id} is not in the series registry" unless @registry.entries.key?(id)
      raise Refused, "series #{id} is still running (its process is alive); `--forget` only cleans up a series whose process is gone" unless @registry.stale.include?(id)
      @started = true
      @lanes = []
      @stop_reason = "forgotten"
      a_path = worktree_path(id)
      @lanes << {workspace: nil, path: a_path} if a_path
      finish
      0
    end

    # The checkout of the worktree `calc2-demo-<name>`, from git's own list.
    def worktree_path(name)
      out, ok = @exec.call(%w[git worktree list --porcelain], chdir: @root)
      return nil unless ok
      out.to_s.lines.filter_map { |line| line.chomp.delete_prefix("worktree ") if line.start_with?("worktree ") }.find { |path| File.basename(path).match?(/\Acalc2-demo-#{Regexp.escape(name)}\z/) }
    end

    # Steps 2 to 6. Once step 2 registered the id, any stop is exit 3 and {#finish} runs for what exists.
    def run_steps
      @started = false
      @lanes = []
      begin
        start_lanes
        check_heads
        use_sonnet if @options.sonnet
        wait_for_idle_lanes
        write_shared_state
        run_lanes
      rescue => e
        raise unless @started
        @stop_reason ||= e.message
        @err.puts "demo-calculator2: series #{id} stopped: #{e.message}#{" (#{e.class})" unless e.is_a?(Stopped) || e.is_a?(Refused)}"
        3
      ensure
        finish if @started
      end
    end

    # Steps 7 to 9 (evidence, pin and clean, report), which run for whatever step 2 created, however the steps ended. Each
    # sub-step is independent: one that fails is reported and the rest go on.
    def finish
      @concurrent ||= (registry_entries.keys - [id]).size
      a_path = @lanes.first && @lanes.first[:path]
      keep = @options.keep && !@options.forget
      @run_dir = a_path && File.join(a_path, "runs", id)
      attempt("reading run.json") { @run = parse(@read_file.call(File.join(@run_dir, "run.json"))) } if @run_dir
      save_evidence unless @options.forget
      attempt("reading eval.json") { @eval_doc = parse(@read_file.call(File.join(@run_dir, "eval.json"))) } if @run_dir
      cleaned = keep ? false : pin_and_clean
      report(keep, cleaned)
    end

    # The registered series, or none when the registry cannot be read: cleanup goes on and kills nothing it cannot prove is its own.
    def registry_entries
      @registry.entries
    rescue SeriesRegistry::Corrupt => e
      @err.puts "demo-calculator2: series #{id}: #{e.message}"
      {}
    end

    # Step 7: everything lands in lane A's `runs/<id>/`.
    def save_evidence
      return unless @run_dir
      script = File.join(@lanes.first[:path], "script", "demo-calculator2")
      attempt("eval") { @write_file.call(File.join(@run_dir, "eval.txt"), run_ok(@lanes.first[:path], script, "eval", "--run", @run_dir)) }
      run_ids = []
      run_ids.concat([@run&.dig("fork", "run_id"), @run&.dig("integration", "integrate_run", "run_id")].compact) if @run.is_a?(Hash)
      @lanes.each_with_index do |lane, index|
        attempt("work-queue history of #{lane[:workspace]}") do
          text = run_ok(@root, @workspace, "work-queue", "history", "list", "--json", "--name", lane[:workspace])
          @write_file.call(File.join(@run_dir, "work-queue-history-#{index.zero? ? "a" : "b"}.json"), text)
          doc = parse(text)
          run_ids.concat(Array(doc["entries"]).filter_map { |entry| entry.dig("result", "run_id") }) if doc.is_a?(Hash)
        end
      end
      run_ids.uniq.each do |run_id|
        %w[attempts trace].each do |verb|
          attempt("workflow #{verb} #{run_id}") { @write_file.call(File.join(@run_dir, "#{verb}-#{run_id}.json"), run_ok(@root, @workspace, "workflow", verb, run_id, "--json")) }
        end
      end
      attempt("command.txt") { @write_file.call(File.join(@run_dir, "command.txt"), "#{command_line}\n") }
    end

    def command_line
      return @command if @command
      o = @options
      words = ["script/demo-calculator2", "series", "--id", id, "--base", o.base, "--workflow", o.workflow]
      words << "--sonnet" if o.sonnet
      words << "--take-over" if o.take_over
      words << "--keep" if o.keep
      words.push("--evidence-dir", o.evidence_dir) if o.evidence_dir
      words.push("--scoreboard", o.scoreboard) if o.scoreboard
      words.join(" ")
    end

    # Step 8. Pins first, copies the evidence before anything is killed, then kills, deletes and deregisters, and each of those
    # only for a name the registry entry or run.json records. A copy that failed stops the kills, so the evidence is not lost with
    # the checkout; the id stays registered for `series --forget`.
    # @return [Boolean] whether the series was deregistered
    def pin_and_clean
      entry = registry_entries[id] || {}
      pinned = pin_heads
      copied = copy_evidence
      unless copied
        @err.puts "demo-calculator2: series #{id}: the evidence was not copied, so nothing is killed and the id stays registered (series --forget #{id} tries again)"
        return false
      end
      kill_workspaces(entry)
      delete_branches(entry, pinned)
      attempt("deleting refs/demo-calc2/acceptance/#{id}") { run_ok(@root, "git", "update-ref", "-d", "refs/demo-calc2/acceptance/#{id}") }
      deregister
    end

    def run_branches
      return [] unless @run.is_a?(Hash)
      [@run["branch"], @run.dig("lanes", "b", "branch")].compact
    end

    # @return [Array<String>] the branches whose head is now pinned under `refs/demo-calc2-runs/`
    def pin_heads
      pinned = []
      branches = [[id, @run&.fetch("branch", nil)], ["#{id}-b", @run&.dig("lanes", "b", "branch")]]
      branches.each_with_index do |(name, branch), index|
        attempt("pinning refs/demo-calc2-runs/#{name}") do
          path = @lanes[index] && @lanes[index][:path]
          sha = if branch
            run_ok(@root, "git", "rev-parse", branch).strip
          elsif path
            run_ok(path, "git", "rev-parse", "HEAD").strip
          end
          next if sha.nil? || sha.empty?
          run_ok(@root, "git", "update-ref", "refs/demo-calc2-runs/#{name}", sha)
          @registry.record(id, refs: ["refs/demo-calc2-runs/#{name}"], branches: [branch].compact)
          pinned << branch if branch
        end
      end
      pinned
    end

    # @return [Boolean] false when a copy was needed and failed
    def copy_evidence
      return true unless @run_dir && @path_exists.call(@run_dir)
      attempt("copying #{@run_dir} to #{evidence_target}") { @copy_dir.call(@run_dir, evidence_target) }
    end

    def evidence_target
      File.expand_path(@options.evidence_dir || File.join("tmp", "demo-calculator2", "series", id), @root)
    end

    def kill_workspaces(entry)
      recorded = Array(entry["workspaces"])
      wanted = (recorded + [@run&.dig("lanes", "a", "workspace"), @run&.dig("lanes", "b", "workspace")]).compact.uniq
      wanted.each do |name|
        attempt("killing #{name}") do
          raise "#{name} is not in series #{id}'s registry entry; it is not killed" unless recorded.include?(name)
          run_ok(@root, @workspace, "kill", "--name", name, "--force", "--json")
        end
      end
    end

    def delete_branches(entry, pinned)
      (run_branches | Array(entry["branches"])).each do |branch|
        attempt("deleting #{branch}") do
          raise "#{branch} is not a #{DemoCalculator::RUN_BRANCH_PREFIX}<stamp>-#{id}[-b] branch of this series; it is not deleted" unless branch.match?(/\Acalc-demo\/\d{8}T\d{6}Z-#{Regexp.escape(id)}(-b)?\z/)
          raise "#{branch} was not pinned; it is not deleted" unless pinned.include?(branch)
          run_ok(@root, "git", "branch", "-D", branch)
        end
      end
    end

    # Drops the id and undoes what the registry hands back. Each undo is independent.
    # @return [Boolean]
    def deregister
      undo = nil
      return false unless attempt("deregistering") { undo = @registry.remove(id) }
      @driver_gone = false
      undo.each { |item| attempt("undoing #{item["key"]}") { undo_shared(item) } }
      true
    end

    def undo_shared(item)
      key = item["key"]
      replaced = item["replaced"]
      case key
      when /\Aexclude:(.+)\z/ then drop_info_line("exclude", $1)
      when /\Aattributes:(.+)\z/ then drop_info_line("attributes", $1)
      when /\Agit-config:(.+)\z/ then undo_git_config(key, $1, replaced)
      when /\Aworkflows\.sources:(.+)\z/ then drop_source($1)
      end
    end

    def undo_git_config(key, name, replaced)
      old = replaced && replaced["value"]
      path = (key == SharedValues::DRIVER_KEY) ? SharedValues.driver_path(old) : nil
      alive = old && (path.nil? ? (key != SharedValues::DRIVER_KEY && !@driver_gone) : @path_exists.call(path))
      @driver_gone = true if key == SharedValues::DRIVER_KEY && replaced && !alive
      if alive
        run_ok(@root, "git", "config", "--local", name, old)
      else
        run_ok(@root, "git", "config", "--local", "--unset", name)
      end
    end

    def drop_info_line(file, line)
      path = info_path(file)
      text = @read_file.call(path)
      return if text.nil?
      kept = text.lines.reject { |each| each.strip == line }
      @write_file.call(path, kept.join) unless kept.size == text.lines.size
    end

    def drop_source(ours)
      keys = parse(run_ok(@root, @workspace, "config", "show", "--json"))&.fetch("keys", nil)
      list = keys.is_a?(Array) ? keys.find { |key| key["key"] == SOURCES_KEY }&.fetch("effective", nil) : nil
      list = list.split(",").map(&:strip) if list.is_a?(String)
      rest = Array(list).map(&:to_s) - [ours]
      return if rest.size == Array(list).size
      if rest.empty?
        run_ok(@root, @workspace, "config", "unset", SOURCES_KEY)
      else
        run_ok(@root, @workspace, "config", "set", SOURCES_KEY, rest.join(","))
      end
    end

    def info_path(file)
      File.join(File.expand_path(run_ok(@root, "git", "rev-parse", "--git-common-dir").strip, @root), "info", file)
    end

    # Step 9: the scoreboard row, then the closing line.
    def report(keep, cleaned)
      evidence = keep ? @run_dir : evidence_target
      line = self.class.scoreboard_row(@eval_doc, @run, concurrent: @concurrent, id: id, evidence: evidence)
      if @options.forget
        # The series wrote its own row when it ended; a second one would count the run twice.
      elsif @options.scoreboard
        attempt("appending to #{@options.scoreboard}") do
          path = File.expand_path(@options.scoreboard, @root)
          existing = @read_file.call(path).to_s
          @write_file.call(path, existing + ((existing.empty? || existing.end_with?("\n")) ? "" : "\n") + line + "\n")
        end
      else
        @out.puts line
      end
      @out.puts "series #{id}: kept; nothing killed and the id stays registered (series --forget #{id})" if keep
      @out.puts "series #{id}: deregistered" if cleaned
      reason = @stop_reason.to_s.lines.first.to_s.strip
      reason = "no run" if reason.empty?
      detail = @driver_done ? @driver_done.sub(/\A.*?#{LOOP_DONE}:?\s*/o, "") : "stopped reason=#{reason}"
      detail += " (no scoreboard row: --forget does not add one)" if @options.forget
      @out.puts "#{LOOP_DONE}: series #{id} #{detail}"
    end

    def attempt(what)
      yield
      true
    rescue => e
      @err.puts "demo-calculator2: series #{id}: #{what} failed: #{e.message}"
      false
    end

    def run_ok(chdir, *argv)
      out, ok = @exec.call(argv, chdir: chdir)
      raise "`#{argv.join(" ")}` failed" unless ok
      out
    end

    # Step 2. The id is registered before the first start and each workspace is recorded as soon as its start answers, before the
    # next command runs.
    def start_lanes
      @registry.register(id)
      @concurrent = @registry.entries.size - 1
      @started = true
      [id, "#{id}-b"].each do |name|
        out, ok = @exec.call([@workspace, "start", "calc2-demo-#{name}", "--base", @options.base, "--headless", "--yes", "--json"], chdir: @root)
        doc = parse(out)
        doc = {} unless doc.is_a?(Hash)
        @registry.record(id, workspaces: [doc["workspace"]]) if doc["workspace"]
        raise Stopped, "`workspace start calc2-demo-#{name}` failed" unless ok && doc["workspace"] && doc["path"]
        @lanes << {workspace: doc["workspace"], path: doc["path"]}
      end
    end

    def check_heads
      base = stop_unless_ok(@root, "git", "rev-parse", @options.base).strip
      @lanes.each do |lane|
        head = stop_unless_ok(lane[:path], "git", "rev-parse", "HEAD").strip
        raise Stopped, "#{lane[:workspace]} is at #{head[0, 12]}, not #{@options.base} (#{base[0, 12]})" unless head == base
      end
    end

    # Step 3. The pane command is read back from the tmuxinator file: `sessions --json` carries no command field.
    def use_sonnet
      @lanes.each do |lane|
        name = lane[:workspace]
        stop_unless_ok(@root, @workspace, "config", "set", "--scope", "workspace", "--name", name, "agent.commands.claude", SONNET_COMMAND)
        stop_unless_ok(@root, @workspace, "template", "apply", name, "--relaunch")
        doc = parse(stop_unless_ok(@root, @workspace, "tmux", "show", "--name", name, "--json"))
        panes = doc.is_a?(Hash) ? Array(doc["windows"]).flat_map { |window| Array(window["panes"]) } : []
        pane = panes.find { |each| each["kind"] == "claude" }
        raise Stopped, "#{name}'s Claude Code pane does not run #{SONNET_COMMAND} (#{pane ? pane["command"].inspect : "no such pane"})" unless pane && pane["command"].to_s.start_with?("#{SONNET_COMMAND} ")
      end
    end

    # Step 4. Both lanes need an idle Claude Code pane, polled every `idle_poll` seconds for at most `idle_wait`.
    def wait_for_idle_lanes
      deadline = @clock.call + @idle_wait
      loop do
        waiting = @lanes.reject { |lane| idle_pane?(lane[:workspace]) }
        return if waiting.empty?
        raise Stopped, "no idle Claude Code pane in #{waiting.map { |lane| lane[:workspace] }.join(", ")} after #{@idle_wait}s" if @clock.call + @idle_poll > deadline
        @sleeper.call(@idle_poll)
      end
    end

    def idle_pane?(name)
      doc = json_object(@workspace, "snapshot", "--json", "--name", name)
      member = Array(doc["projects"]).flat_map { |project| Array(project["members"]) }.find { |each| each["workspace"] == name }
      !!member && member["running"] && Array(member["panes"]).any? { |pane| pane["kind"] == "claude" && IDLE_STATES.include?(pane["state"]) }
    end

    # Step 5. Classifies the shared values again (one may have changed since preflight; a new `foreign_live` refuses and nothing
    # runs), then, for each, records it in the registry before writing it. `equal` writes nothing; the sources entry goes first.
    def write_shared_state
      @going_runs = nil
      rows = check_shared_values.sort_by { |row| row.key.start_with?(SharedValues::SOURCES_PREFIX) ? 0 : 1 }
      rows.each do |row|
        @registry.add(id, row.key, row.wanted, state: row.state, take_over: @options.take_over, live: foreign_value(row))
        write_shared(row) unless row.state == :equal
      end
    end

    # The one value a row is about: the live value, or for a sources row the entry that differs from ours, a live one first.
    def foreign_value(row)
      return row.live unless row.key.start_with?(SharedValues::SOURCES_PREFIX)
      others = Array(row.live).select { |entry| entry != row.wanted && entry.end_with?(SharedValues::SOURCES_SUFFIX) }
      others.find { |entry| @path_exists.call(entry) } || others.first
    end

    def write_shared(row)
      case row.key
      when /\Aworkflows\.sources:/ then write_sources(row)
      when /\Agit-config:(.+)\z/ then stop_unless_ok(@root, "git", "config", "--local", $1, row.wanted)
      when /\Aattributes:/ then append_info_line("attributes", row.wanted)
      when /\Aexclude:/ then append_info_line("exclude", row.wanted)
      end
    end

    # Adds our entry after the others, or in front of them on a take-over, so the other checkout's entry is never removed.
    def write_sources(row)
      others = Array(row.live).reject { |entry| entry == row.wanted }
      list = (row.state == :foreign_live) ? [row.wanted, *others] : [*others, row.wanted]
      stop_unless_ok(@root, @workspace, "config", "set", SOURCES_KEY, list.join(","))
    end

    def append_info_line(file, line)
      path = File.join(File.expand_path(must_read("git", "rev-parse", "--git-common-dir").strip, @root), "info", file)
      existing = @read_file.call(path).to_s
      return if existing.lines.map(&:strip).include?(line)
      @write_file.call(path, existing + ((existing.empty? || existing.end_with?("\n")) ? "" : "\n") + line + "\n")
    end

    # Step 6. Runs lane A's own copy of the script from its worktree, its stdout and stderr appended to `runs/<id>/driver.log` as it
    # goes (so `tail -f` works), then reads the log for the closing line.
    # @return [Integer] 0 on a `LOOP DONE` line that ends `items=7/7` and exit status 0, else 3
    def run_lanes
      lane_a, lane_b = @lanes
      argv = [File.join(lane_a[:path], "script", "demo-calculator2"), "run", "--lanes", "--lane-b", lane_b[:workspace], "--id", id, "--wait", "--out", File.join("runs", id)]
      argv += ["--workflow", @options.workflow] unless @options.workflow == WORKFLOW_ID
      log = File.join(lane_a[:path], "runs", id, "driver.log")
      status = @run_logged.call(argv, chdir: lane_a[:path], log: log)
      done = @read_file.call(log).to_s.lines.reverse.find { |line| line.include?(LOOP_DONE) }
      @driver_done = done&.strip
      return 0 if status == 0 && done&.match?(/items=7\/7/)
      @stop_reason = done ? done.strip : "no LOOP DONE line"
      @err.puts "demo-calculator2: series #{id}: the run stopped (#{done ? done.strip : "no LOOP DONE line"}); see runs/#{id}/driver.log"
      3
    end

    def stop_unless_ok(chdir, *argv)
      out, ok = @exec.call(argv, chdir: chdir)
      raise Stopped, "`#{argv.join(" ")}` failed" unless ok
      out
    end

    def check_id
      return if id.to_s.match?(ID_PATTERN) && id != "b"
      raise Refused, "id #{id.inspect} must be lowercase letters and digits starting with a letter, and not b"
    end

    def check_unused
      %W[#{id} #{id}-b].each do |name|
        _, found = read("git", "show-ref", "--verify", "--quiet", "refs/demo-calc2-runs/#{name}")
        raise Refused, "id #{id} is used: refs/demo-calc2-runs/#{name} exists" if found
      end
      out = must_read("git", "worktree", "list", "--porcelain")
      paths = out.to_s.lines.filter_map { |line| line.chomp.delete_prefix("worktree ") if line.start_with?("worktree ") }
      raise Refused, "id #{id} is used: a worktree calc2-demo-#{id} exists" if paths.any? { |path| File.basename(path).match?(/\Acalc2-demo-#{id}(-b)?\z/) }
      names = json(@workspace, "list", "--all", "--json")
      raise Refused, "`workspace list --all --json` did not print a list" unless names.is_a?(Array)
      raise Refused, "id #{id} is used: a workspace calc2-demo-#{id} exists" if names.any? { |name| name.match?(/(\A|\.worktree-|\.)calc2-demo-#{id}(-b)?\z/) }
      raise Refused, "id #{id} is used: it is in the series registry (series --forget #{id})" if @registry.entries.key?(id)
    end

    def check_base
      return unless @options.base == "main"
      local = must_read("git", "rev-parse", "main")
      remote = must_read("git", "rev-parse", "origin/main")
      raise Refused, "main is not origin/main (#{local.to_s.strip[0, 8]} vs #{remote.to_s.strip[0, 8]}); update main or pass --base" if local.to_s.strip.empty? || local.strip != remote.to_s.strip
    end

    def check_ci
      runs = json("gh", "run", "list", "--branch", @options.base, "-L", "1", "--json", "conclusion,status")
      raise Refused, "`gh run list` did not print a list" unless runs.is_a?(Array)
      run = runs.first
      return if run && run["status"] == "completed" && run["conclusion"] == "success"
      raise Refused, "the latest CI run on #{@options.base} is not a success (#{run ? "#{run["status"]}/#{run["conclusion"]}" : "none found"})"
    end

    def check_test_db
      locks = json_object(@workspace, "lock", "status", "--json")["locks"]
      raise Refused, "`workspace lock status --json` did not name the locks" unless locks.is_a?(Hash)
      holder = locks.dig("test-db", "holder")
      raise Refused, "the test-db lock is held (#{holder.inspect})" if holder
      user = going_runs.find { |run| TEST_DB_WORKFLOWS.include?(run["workflow"]) }
      raise Refused, "run #{user["id"]} of #{user["workflow"]} in #{user["workspace"]} uses the test-db lock" if user
    end

    def going_runs
      @going_runs ||= begin
        runs = json_object(@workspace, "workflow", "status", "--all", "--json")["runs"]
        raise Refused, "`workspace workflow status --all --json` did not name the runs" unless runs.is_a?(Array) && runs.all?(Hash)
        runs.reject { |run| FINISHED_STATES.include?(run["state"]) }
      end
    end

    def check_shared_values
      rows = shared_inputs.map do |key, live, wanted, extra|
        state = SharedValues.classify(key, live: live, wanted: wanted, path_exists: @path_exists, **extra)
        Shared.new(key: key, live: live, wanted: wanted, state: state, action: action_for(key, live, state))
      end
      rows.select { |row| row.state == :foreign_live }.each { |row| refuse_foreign(row) }
      rows
    end

    def action_for(key, live, state)
      case state
      when :equal then "unchanged"
      when :absent then "would add #{key}"
      when :dangling then "would replace #{live.inspect} (its checkout #{SharedValues.owner_path(key, live)} is gone)"
      else (@options.take_over ? "would take over #{live.inspect} from #{SharedValues.owner_path(key, live)}" : "refuse")
      end
    end

    def refuse_foreign(row)
      live = foreign_value(row)
      owner = SharedValues.owner_path(row.key, live)
      raise Refused, SharedValues.refusal(row.key, live, owner) unless @options.take_over
      raise Refused, "#{row.key} is #{live.inspect}, whose owning checkout is unknown, so --take-over cannot tell whether it has a going run; remove the value by hand" if owner.nil? || owner.empty? || owner == "unknown"
      going = going_runs.find { |run| run["worktree"] && same_path?(run["worktree"].to_s, owner) }
      raise Refused, "#{row.key} belongs to #{owner}, whose workspace #{going["workspace"]} has a going run (#{going["id"]}); wait for it before --take-over" if going
    end

    def same_path?(one, other)
      resolve = ->(path) { File.exist?(path) ? File.realpath(path) : File.expand_path(path) }
      resolve.call(one) == resolve.call(other)
    end

    def shared_inputs
      driver = live_git_config("merge.#{MERGE_DRIVER}.driver")
      name = live_git_config("merge.#{MERGE_DRIVER}.name")
      sources = File.join(@root, DEMO_DIR, "workflows")
      same = ->(entry) { DEFINITION_IDS.all? { |def_id| (text = @read_file.call(File.join(entry, "#{def_id}.yml"))) && text == base_copy(def_id) } }
      [
        [SharedValues::DRIVER_KEY, driver, SharedValues::DRIVER_COMMAND, {}],
        [NAME_KEY, name, NAME_VALUE, {}],
        ["attributes:#{ATTRIBUTES_LINE}", live_info_line("attributes") { |line| line.start_with?("#{DEMO_DIR}/test/calc_test.rb ") }, ATTRIBUTES_LINE, {}],
        ["#{SharedValues::SOURCES_PREFIX}#{sources}", live_sources, sources, {same_definitions: same}],
        ["exclude:#{exclude_line}", live_info_line("exclude") { |line| line == exclude_line }, exclude_line, {}]
      ]
    end

    def exclude_line = SharedValues.exclude_line(File.join("runs", id))

    def live_git_config(key)
      out, ok = read("git", "config", "--local", "--get", key)
      (ok && !out.to_s.strip.empty?) ? out.to_s.strip : nil
    end

    def live_info_line(file, &match)
      out = must_read("git", "rev-parse", "--git-common-dir")
      text = @read_file.call(File.join(File.expand_path(out.strip, @root), "info", file))
      text && text.lines.map(&:strip).reverse.find(&match)
    end

    # The effective list: `config get` reads one layer's file, and this key lives in the global one.
    def live_sources
      keys = json_object(@workspace, "config", "show", "--json")["keys"]
      raise Refused, "`workspace config show --json` did not list the keys" unless keys.is_a?(Array)
      list = keys.find { |key| key["key"] == SOURCES_KEY }&.fetch("effective", nil)
      list = list.split(",").map(&:strip) if list.is_a?(String)
      Array(list).map { |entry| entry.to_s.start_with?("~/") ? File.join(Dir.home, entry[2..]) : entry.to_s }
    end

    # Every definition the catalog would resolve must be the base's bytes; an id it does not resolve yet is ours to add.
    def check_definitions
      DEFINITION_IDS.each do |def_id|
        wanted = base_copy(def_id)
        out, = read(@workspace, "workflow", "show", def_id, "--json")
        doc = parse(out)
        raise Refused, "`workspace workflow show #{def_id} --json` did not print a JSON object" unless doc.is_a?(Hash)
        next if doc["code"] == "unknown_workflow"
        resolved = doc["workflow"]
        raise Refused, "cannot read workflow #{def_id}: #{doc["error"] || "no definition in the answer"}" unless resolved.is_a?(Hash)
        have = resolved["sha256"] || @read_file.call(resolved["path"].to_s)&.then { |text| Digest::SHA256.hexdigest(text) }
        next if have == Digest::SHA256.hexdigest(wanted)
        raise Refused, "workflow #{def_id} resolves to #{resolved["path"]} (#{resolved["source"]}), which differs from #{@options.base}'s #{DEMO_DIR}/workflows/#{def_id}.yml"
      end
    end

    def base_copy(def_id)
      @base_copies ||= {}
      @base_copies.fetch(def_id) do
        @base_copies[def_id] = must_read("git", "show", "#{@options.base}:#{DEMO_DIR}/workflows/#{def_id}.yml")
      end
    end

    def read(*argv) = @exec.call(argv, chdir: @root)

    # stdout of a read preflight depends on; a failed command refuses, it never reads as "nothing there".
    def must_read(*argv)
      out, ok = read(*argv)
      raise Refused, "`#{argv.join(" ")}` failed; cannot check #{id}" unless ok
      out
    end

    def json_object(*argv)
      doc = json(*argv)
      raise Refused, "`#{argv.join(" ")}` did not print a JSON object; cannot check #{id}" unless doc.is_a?(Hash)
      doc
    end

    def json(*argv)
      out = must_read(*argv)
      parse(out) or raise Refused, "`#{argv.join(" ")}` did not print JSON; cannot check #{id}"
    end

    def parse(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
    end

    def say_report(report)
      @out.puts "series #{id}: preflight ok (base #{@options.base})"
      report.shared.each { |row| @out.puts "  #{row.key}: now #{row.live.inspect}; #{row.action}" }
      @out.puts "  stale ids in the registry (not removed; `series --forget ID`): #{report.stale.join(", ")}" unless report.stale.empty?
    end
  end
end
