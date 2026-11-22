require "digest"
require "json"
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
    MERGE_DRIVER = "calc-demo-tests".freeze
    ATTRIBUTES_LINE = "#{DEMO_DIR}/test/calc_test.rb merge=#{MERGE_DRIVER}".freeze
    NAME_KEY = "git-config:merge.#{MERGE_DRIVER}.name".freeze
    NAME_VALUE = "calc_test.rb: keep both lanes' added test methods".freeze
    SOURCES_KEY = "workflows.sources".freeze
    # `workflow status --all --json` does not say which locks a run uses, so a run of these workflows counts as holding `test-db`.
    TEST_DB_WORKFLOWS = [INTEGRATE_WORKFLOW_ID].freeze
    DEFAULT_WORKFLOW = "deliver-goal-fast".freeze
    FINISHED_STATES = %w[completed cancelled failed].freeze

    # A refusal before anything started: exit 1, nothing to clean.
    class Refused < DemoCalculator::Refused; end

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
    def initialize(root:, options:, exec:, registry:, out: $stdout, err: $stderr, workspace: "workspace",
      read_file: ->(path) { File.file?(path) ? File.read(path) : nil }, path_exists: ->(path) { File.directory?(path) })
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

    # @return [Integer] 0 when preflight passes (a dry run ends here; the later steps are T13), 1 on a refusal
    def call
      report = preflight
      say_report(report)
      0
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

    private

    def id = @options.id

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
      owner = SharedValues.owner_path(row.key, row.live)
      raise Refused, SharedValues.refusal(row.key, row.live, owner) unless @options.take_over
      raise Refused, "#{row.key} is #{row.live.inspect}, whose owning checkout is unknown, so --take-over cannot tell whether it has a going run; remove the value by hand" if owner.nil? || owner.empty? || owner == "unknown"
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
        ["exclude:/runs/#{id}/", live_info_line("exclude") { |line| line == "/runs/#{id}/" }, "/runs/#{id}/", {}]
      ]
    end

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
