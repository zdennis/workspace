module Workspace
  # What the plan command objects ({Commands::Plan}, {Commands::PlanDispatch}) share: finding a
  # workspace's plan file, the plan's refusals, the `status:` write, and the `plan_changed` event.
  class PlanAccess
    # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are
    # @param tmux [Workspace::Tmux] says which sessions run
    # @param event_log [Workspace::EventLog] gets `plan_changed`
    def initialize(notes:, tmux:, event_log:)
      @notes = notes
      @tmux = tmux
      @event_log = event_log
    end

    # @param name [String] the workspace
    # @return [String] the plan's absolute path, whether or not the file exists
    # @raise [Workspace::Error] as {Workspace::Commands::Notes#info}
    def path_for(name)
      PlanFile.path_in(@notes.info(name: name)["dir"])
    end

    # @param name [String] the workspace
    # @return [Array(String, PlanFile)] the path and the parsed plan
    # @raise [Workspace::Error] `no_plan`
    def require_plan(name)
      file = path_for(name)
      plan = PlanFile.read(file)
      raise no_plan(name, file) unless plan
      [file, plan]
    end

    # @return [Workspace::Error] code `no_plan`
    def no_plan(name, file)
      Workspace::Error.new("No plan for '#{name}' at #{file}. Make one with 'workspace plan init --name #{name}'.",
        code: "no_plan", details: {"name" => name, "path" => file})
    end

    # @return [Workspace::Error] code `plan_done`
    def plan_done(name, file)
      Workspace::Error.new("The plan for '#{name}' is done: nothing is left to do. Edit #{file} to reopen it.",
        code: "plan_done", details: {"name" => name, "path" => file})
    end

    # @param plan [PlanFile]
    # @return [Boolean] whether the plan has nothing left to do
    def finished?(plan)
      plan.status == "done" || (!plan.tasks.empty? && plan.counts["left"].zero?)
    end

    # @return [Hash] the row of a plan verb's action document
    def row(outcome, file, message: nil, pane: nil, reason: nil)
      {"outcome" => outcome, "reason" => reason, "message" => message, "path" => file, "pane" => pane}
    end

    # The `status:` write, with the event when the file changed.
    # @return [Boolean] whether the file changed
    def write_status(name, file, status)
      changed = guarded_write(name, file) { PlanFile.set_status(file, status) }
      record_change(name, status) if changed
      changed
    end

    # Runs a write, turning a missing file into `no_plan` and a system error into `notes_dir_unwritable`.
    def guarded_write(name, file)
      yield
    rescue Errno::ENOENT
      raise no_plan(name, file)
    rescue SystemCallError => e
      raise unwritable(file, e)
    end

    # @return [Workspace::Error] code `notes_dir_unwritable`
    def unwritable(file, error)
      Workspace::Error.new("Can't write the plan #{file}: #{error.message}", code: "notes_dir_unwritable", details: {"path" => File.dirname(file)})
    end

    # Records `plan_changed` in the event log.
    def record_change(name, status)
      @event_log.record(type: "plan_changed", project: name, data: {"workspace" => name, "status" => status})
    end

    # @param memo [Hash] holds the session list across calls
    # @return [Boolean, nil] nil when tmux can't be asked or the workspace runs on a socket of its own
    def session_live?(name, memo)
      return nil if @tmux.custom_socket_option(name)
      memo[:sessions] = read_sessions unless memo.key?(:sessions)
      memo[:sessions]&.include?(@tmux.session_name_for(name))
    end

    private

    def read_sessions
      @tmux.sessions(strict: true)
    rescue Workspace::Error, SystemCallError
      nil
    end
  end
end
