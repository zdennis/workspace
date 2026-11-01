require "rbconfig"
require "fileutils"

module Workspace
  # Tells a person about a workflow run through the project's `alerts.notify`
  # command, for the events named in `alerts.workflow` (`gate`, `failed`,
  # `stalled`, `finished`). With `alerts.workflow` unset nothing runs.
  #
  # {WorkflowEngine#transition} calls {#marks} on the run inside its lock
  # before and after a change, and {#fire} once the lock is given up. An event
  # is the difference between the two marks, so it fires in the one process
  # that made the change, once for that change, however often the run is read
  # or swept afterwards. Nothing here needs the agent daemon.
  #
  # The command gets the alert only as `WORKSPACE_ALERT_*` environment
  # variables. Their values come from the run file, so they are escaped for a
  # terminal and cut short. The run's suggested next action is never passed on.
  # The caller never waits on the command and never outlives its time limit:
  # {#deliver} starts a detached supervisor process (`ruby -e`, loading
  # {Notifier}) in its own process group, which runs the command with the
  # notifier's time limit and group kill and then exits. The command line
  # carries only the notify command (the user's own) and the limit; the alert
  # reaches it as environment variables. Each supervisor is bounded by its own
  # limit, so no cap on how many run is needed. A failure to start one is a
  # line on the error stream, never an error; the supervisor's own reports go
  # to +log_path+.
  class WorkflowAlerts
    # The names `alerts.workflow` accepts.
    EVENTS = %w[gate failed stalled finished].freeze

    # The longest an environment value is, in characters.
    MAX_VALUE = 200

    # Seconds a notify command may run before the supervisor stops it.
    TIMEOUT = Notifier::DEFAULT_TIMEOUT

    # The log is renamed to `<log>.1` (replacing an older one) once it passes this many bytes, so two files at most are kept.
    MAX_LOG_BYTES = 1024 * 1024

    # The supervisor's program: runs ARGV's command under the limit with the alert's variables, then waits for it.
    SUPERVISOR = <<~RUBY.freeze
      require ARGV.shift
      timeout = Float(ARGV.shift)
      notifier = Workspace::Notifier.new(command: ARGV.shift, timeout: timeout, label: "workspace workflow")
      notifier.notify(ENV.select { |name, _| name.start_with?("WORKSPACE_ALERT") })
      notifier.wait
    RUBY

    # @param alert_config [Workspace::AlertConfig] reads `alerts.notify` and `alerts.workflow`
    # @param log_path [String, nil] where the supervisor's reports go (nil discards them)
    # @param timeout [Numeric] seconds a notify command may run
    # @param spawner [#call] starts a detached process: `(argv, env, log_path)`; injected for tests
    # @param error_output [IO] where a problem starting the alert is reported
    def initialize(alert_config:, log_path: nil, timeout: TIMEOUT, spawner: nil, error_output: $stderr)
      @alert_config = alert_config
      @log_path = log_path
      @timeout = timeout
      @spawner = spawner || method(:spawn_detached)
      @error_output = error_output
    end

    # What a run stands in now, for {#fire} to compare with a later reading.
    # Reads only the stored run.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Hash{Symbol=>Object}]
    def marks(run)
      step = run["current"]
      state = run.dig("steps", step) || {}
      swept = WorkflowEngine.sweep_marks(run)
      stalled = swept["stalled"]
      {
        gate: (step if state.dig("gate", "state") == "waiting"),
        failed: (step if run["state"] == "failed" || run.dig("reason", "code") == "failed_check"),
        stalled: stalled.is_a?(Hash) ? stalled.keys.map { |cause| ["#{swept["step"]}:#{swept["attempt"]}", cause.to_s] } : [],
        finished: run["state"] == "completed"
      }
    rescue
      {gate: nil, failed: nil, stalled: [], finished: false}
    end

    # Runs the notify command for each event the change from +before+ to the
    # run's stored state started, when `alerts.workflow` names it.
    #
    # @param before [Hash] {#marks} taken before the change
    # @param run [Hash{String=>Object}] the run as stored after it
    # @return [void]
    def fire(before, run)
      after = marks(run)
      events = new_events(before, after)
      return if events.empty?
      alerts = @alert_config.for_workspace(run["workspace"].to_s)
      command = alerts[:notify]
      return unless command
      wanted = events & Array(alerts[:workflow])
      return if wanted.empty?
      wanted.each { |event| deliver(command, env(event, run, before, after)) }
    rescue => e
      report "workspace workflow: could not send alerts for #{clean(run.is_a?(Hash) ? run["id"] : nil)}: #{clean(e.message)}"
    end

    # Starts the supervisor for one alert and returns at once.
    #
    # @param command [String] the notify command, run through the shell by the supervisor
    # @param env [Hash{String=>String}] the `WORKSPACE_ALERT_*` variables
    # @return [void]
    def deliver(command, env)
      @spawner.call([RbConfig.ruby, "-e", SUPERVISOR, File.expand_path("../workspace.rb", __dir__), @timeout.to_s, command], env, @log_path)
    end

    private

    def spawn_detached(argv, env, log)
      sink = log ? (rotate(log) && [log, "a"]) : File::NULL
      Process.detach(Process.spawn(env, *argv, pgroup: true, in: File::NULL, out: sink, err: sink))
    end

    def rotate(log)
      FileUtils.mkdir_p(File.dirname(log))
      File.rename(log, "#{log}.1") if File.size?(log).to_i > MAX_LOG_BYTES
      true
    rescue SystemCallError
      true
    end

    def new_events(before, after)
      events = []
      events << "gate" if after[:gate] && after[:gate] != before[:gate]
      events << "failed" if after[:failed] && after[:failed] != before[:failed]
      events << "stalled" if (after[:stalled] - Array(before[:stalled])).any?
      events << "finished" if after[:finished] && !before[:finished]
      events
    end

    def env(event, run, before, after)
      id, workspace, step = clean(run["id"]), clean(run["workspace"]), clean(run["current"])
      reason = clean(run.dig("reason", "code"))
      env = {
        "WORKSPACE_ALERT" => "workflow",
        "WORKSPACE_ALERT_EVENT" => event,
        "WORKSPACE_ALERT_RUN_ID" => id,
        "WORKSPACE_ALERT_WORKSPACE" => workspace,
        "WORKSPACE_ALERT_STEP" => step,
        "WORKSPACE_ALERT_TEXT" => "#{workspace}: workflow run #{id} #{phrase(event)}#{" at #{step}" unless event == "finished"}"
      }
      env["WORKSPACE_ALERT_REASON"] = reason unless reason.empty?
      env["WORKSPACE_ALERT_CAUSE"] = (after[:stalled] - Array(before[:stalled])).map { |_episode, cause| clean(cause) }.join(",") if event == "stalled"
      env
    end

    def phrase(event)
      {"gate" => "is waiting for you", "failed" => "failed", "stalled" => "has stalled", "finished" => "finished"}.fetch(event)
    end

    def clean(value)
      TerminalText.escape(value.to_s[0, MAX_VALUE])
    end

    def report(message)
      @error_output.puts message
    rescue
      nil
    end
  end
end
