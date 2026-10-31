module Workspace
  # Reads, for a list of workspace names, the facts a workflow table shows
  # beside each run: whether the workspace is live, what its agent panes are
  # doing, and whether its config and state directory exist. Every read is
  # bounded; a daemon that hangs reads as no answer.
  class WorkflowWorkspaceFacts
    # Extra seconds past the per-daemon timeout that all fetches share.
    GRACE = 0.25

    # @param liveness [Workspace::Liveness] tmux session lookup
    # @param project_config [Workspace::ProjectConfig] tells whether a config exists
    # @param config [Workspace::Config] state directory paths
    # @param agents [Workspace::ProjectAgents] per-workspace agent facts
    # @param timeout [Numeric] seconds each daemon gets to answer
    def initialize(liveness:, project_config:, config:, agents:, timeout: 1.0)
      @liveness = liveness
      @project_config = project_config
      @config = config
      @agents = agents
      @timeout = timeout
    end

    # @param names [Array<String>] workspace names
    # @return [Hash{String => Hash}] per name: `"status"` (`live`, `stopped`,
    #   `gone`, `unknown`), `"agent"` (`working`, `waiting`, `idle` or nil),
    #   `"config"` and `"state_dir"` (booleans, nil when unread) and
    #   `"tmux_session"` (true, false or nil when it can't be told)
    def call(names)
      names = names.uniq
      valid = names.select { |name| valid_name?(name) }
      sessions = read_sessions(valid)
      configs = valid.to_h { |name| [name, config_exists?(name)] }
      dirs = valid.to_h { |name| [name, state_dir?(name)] }
      answers = fetch_agents(valid.select { |name| sessions[name] != false })

      names.to_h do |name|
        [name, facts_for(name, valid.include?(name), sessions, configs, dirs, answers)]
      end
    end

    private

    def valid_name?(name)
      name.is_a?(String) && !name.empty? && !name.include?("\0")
    end

    def facts_for(name, valid, sessions, configs, dirs, answers)
      unless valid
        return {"status" => "unknown", "agent" => nil, "config" => nil, "tmux_session" => nil, "state_dir" => nil}
      end

      session = sessions[name]
      answer = answers[name]
      status = status_for(session, configs[name], answer)
      {
        "status" => status,
        "agent" => (status == "live") ? agent_state(answer) : nil,
        "config" => configs[name],
        "tmux_session" => session,
        "state_dir" => dirs[name]
      }
    end

    def status_for(session, config, answer)
      return "live" if session == true
      return ((answer && answer["available"]) ? "live" : "unknown") if session.nil?

      return "unknown" if config.nil?

      config ? "stopped" : "gone"
    end

    def agent_state(answer)
      return nil unless answer && answer["available"]

      states = Array(answer["panes"]).reject { |pane| pane["kind"] == "shell" }.map { |pane| pane["state"] }
      return "working" if states.include?("working")
      return "waiting" if states.include?("waiting")

      states.empty? ? nil : "idle"
    end

    def read_sessions(names)
      @liveness.call(names)
    rescue SystemCallError, ArgumentError
      names.to_h { |name| [name, nil] }
    end

    def config_exists?(name)
      @project_config.exists?(name)
    rescue SystemCallError, ArgumentError
      nil
    end

    def state_dir?(name)
      File.directory?(@config.pipeline_state_dir(name))
    rescue SystemCallError, ArgumentError
      nil
    end

    def fetch_agents(names)
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      deadline = clock.call + @timeout + GRACE
      threads = names.to_h do |name|
        thread = Thread.new do
          @agents.facts(name, timeout: @timeout)
        rescue
          nil
        end
        thread.report_on_exception = false
        [name, thread]
      end

      threads.to_h do |name, thread|
        finished = thread.join([deadline - clock.call, 0].max)
        thread.kill unless finished
        [name, finished ? thread.value : nil]
      end
    end
  end
end
