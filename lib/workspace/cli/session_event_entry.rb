module Workspace
  class CLI
    # The fast way into `workspace session-event`, which a coding agent's hooks run on every tool
    # call. `bin/workspace` asks {.fast?} before it loads anything; for a plain hook command line it
    # calls {.run}, which loads only the files the hook needs instead of the whole of
    # `lib/workspace`, and builds {Commands::SessionEvent} through {SessionEventWiring}, the same
    # builder `build_cli` uses. An event the fast wiring does not serve
    # ({Commands::SessionEvent.full_wiring?}) is handed to the whole CLI. This file's top level
    # requires nothing, so a command line that is not fast costs only its parse.
    class SessionEventEntry
      # The flags a fast command line may carry, each at most once.
      FLAGS = %w[--workspace --agent].freeze

      # The standard libraries `lib/workspace.rb` loads first, which the closure's files use without requiring.
      # Closure files require any other library (yaml, digest, time, tmpdir) inside the method that uses it.
      STDLIB = %w[json fileutils].freeze

      # The files the hook loads, in dependency order, relative to `lib/workspace`.
      CLOSURE = %w[
        errors core/logger core/id_patterns core/duration byte_size core/agent_provider core/permission_rules
        core/config_schema core/agent_protocol core/file_lock core/atomic_file core/locked_json_file core/workspace_name
        core/workspace_lineage core/deferred config terminal_text tool_input_summary review_round_path
        workflow_produced timed_process git process_tree run_liveness lock_holder lock_audit_log lock_store
        lock_namespace lock_idle_tracker lock_enforcer pane_bindings bound_run bash_command_pieces workflow_deny
        review_write_guard reflection_write_guard session_ledger delivery_log hang_guard_counter recovery_stop_marker
        dev_session_release tmuxinator_config_names session_workspace tmux_pane tmux commands/session_event
        cli/session_event_wiring
      ].freeze

      # Loaded on a guard's deny, for the {EventLog} it records.
      EVENT_LOG_FILES = %w[warn project_settings core/config_layering core/config_resolver events_config event_log].freeze

      # Loaded on a Bash call in a bound pane, for the run {WorkflowDeny} reads.
      RUN_STORE_FILES = %w[workflow_log_tail workflow_definition workflow_run workflow_run_store].freeze

      # Loaded on a lock check's first process table read, for the project's `locks.ps_timeout`.
      PS_TIMEOUT_FILES = %w[core/config_layering core/config_resolver project_settings lock_config].freeze

      # The `bin/workspace` {DevSessionRelease} runs, as `build_cli` names it.
      EXECUTABLE = File.expand_path("../../../bin/workspace", __dir__)

      # @param argv [Array<String>] the command line, subcommand first
      # @return [Boolean] whether it is `session-event` with only `--workspace NAME` and `--agent KIND`
      #   (or their `=` forms), each at most once; `--help`, `--debug`, `--json`, `--no-input`, an
      #   abbreviation or any other argument is not
      def self.fast?(argv)
        !options(argv).nil?
      end

      # Runs one hook event and answers the exit code: the command's own (2 for a deny), or 1 with
      # `Error: MESSAGE` on stderr for a {Workspace::Error}, as the CLI's failure funnel prints it
      # without `--json`. A full-wiring event runs through `Workspace.build_cli`, which exits itself
      # on a non-zero code.
      #
      # @param argv [Array<String>] a command line {.fast?} accepts
      # @param stdin [IO] the hook payload, read once
      # @param stdout [IO]
      # @param stderr [IO]
      # @param env [Hash]
      # @return [Integer] the exit code
      # @raise [ArgumentError] when {.fast?} does not accept argv
      def self.run(argv, stdin:, stdout:, stderr:, env:)
        options = options(argv) or raise ArgumentError, "not a fast session-event command line: #{argv.inspect}"
        utf8_by_default
        STDLIB.each { |name| require name }
        require_files(CLOSURE)
        raw = stdin.read
        return run_full(argv, raw, stdout: stdout, stderr: stderr, env: env) if Commands::SessionEvent.full_wiring?(raw, options[:agent])

        run_fast(options, raw, stdout: stdout, stderr: stderr, env: env)
      end

      def self.options(argv)
        return nil unless argv.first == "session-event"

        found = {}
        rest = argv.drop(1)
        until rest.empty?
          name, value = rest.shift.split("=", 2)
          return nil unless FLAGS.include?(name) && !found.key?(name)
          value = rest.shift if value.nil?
          return nil if value.nil? || value.empty? || value.start_with?("-")
          found[name] = value
        end
        {workspace: found["--workspace"], agent: found["--agent"]}
      end

      def self.run_full(argv, raw, stdout:, stderr:, env:)
        require "stringio"
        require_relative "../../workspace"
        Workspace.build_cli(input: StringIO.new(raw), output: stdout, error_output: stderr, env: env).run(argv)
        0
      end

      def self.run_fast(options, raw, stdout:, stderr:, env:)
        require "stringio"
        logger = Logger.new(output: stderr, enabled: env.key?("WORKSPACE_DEBUG"))
        config = Config.new
        tmux = Tmux.new(config: config, logger: logger)
        input = StringIO.new(raw)
        lineage = WorkspaceLineage.new(rev_parse: Git.new(output: stdout, input: input, logger: logger).method(:path_of))
        command = SessionEventWiring.build(config: config, tmux: tmux, input: input, output: stdout, error_output: stderr, logger: logger, env: env,
          event_log: Deferred.new { event_log(config, stderr, logger) }, run_store: Deferred.new { run_store(config) },
          permission_policy_config: nil, instruction_composer: nil, executable: EXECUTABLE, lineage: lineage,
          process_tree: ProcessTree.new(logger: logger, timeout: -> { ps_timeout(config, lineage, stderr) }),
          config_names: TmuxinatorConfigNames.new(config: config))
        command.call(workspace: options[:workspace], agent: options[:agent])[:exit_code]
      rescue UsageError => e
        failure(stderr, e.message)
      rescue Error => e
        failure(stderr, "Error: #{e.message}")
      end

      def self.failure(stderr, human)
        stderr.puts human.to_s.split("\n", -1).map { |line| TerminalText.escape(line, keep_tabs: true) }.join("\n")
        1
      end

      def self.event_log(config, stderr, logger)
        require_files(EVENT_LOG_FILES)
        project_settings = ProjectSettings.new(config: config)
        events_config = EventsConfig.new(config_resolver: ConfigResolver.new(project_settings: project_settings), error_output: stderr)
        EventLog.new(config: config, project_settings: project_settings, error_output: stderr, logger: logger,
          compact_threshold: -> { events_config.compact_threshold })
      end

      def self.run_store(config)
        require_files(RUN_STORE_FILES)
        WorkflowRunStore.new(dir: config.workflow_runs_dir, archive_dir: config.workflow_archive_dir, event_errors_path: config.workflow_event_errors_path)
      end

      # The value `build_cli` gives its {ProcessTree}: the working directory's project's `locks.ps_timeout`.
      def self.ps_timeout(config, lineage, stderr)
        require_files(PS_TIMEOUT_FILES)
        name = begin
          lineage.resolve(cwd: Dir.pwd).name
        rescue Error
          nil
        end
        return ProcessTree::DEFAULT_TIMEOUT unless name

        LockConfig.new(config_resolver: ConfigResolver.new(project_settings: ProjectSettings.new(config: config)), error_output: stderr).ps_timeout_for(name)
      end

      def self.require_files(names)
        names.each { |name| require_relative "../#{name}" }
      end

      # As `lib/workspace.rb` does when it is loaded.
      def self.utf8_by_default
        return if Encoding.default_external == Encoding::UTF_8

        verbose = $VERBOSE
        $VERBOSE = nil
        Encoding.default_external = Encoding::UTF_8
        $VERBOSE = verbose
      end

      private_class_method :options, :run_full, :run_fast, :failure, :event_log, :run_store, :ps_timeout, :require_files, :utf8_by_default
    end
  end
end
