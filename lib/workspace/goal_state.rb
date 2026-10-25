module Workspace
  # The goal's one `state`, who it waits on and the event that moves it on, from reads
  # that already exist: the plan's own state ({Workspace::PlanState}, in the snapshot
  # member's `plan.state`), the run's reason and flags ({Workspace::WorkflowStatus}), the
  # pane's state and the member's spine counts. It reads and writes nothing.
  class GoalState
    # Run reasons that mean a person has to act.
    WAITING_REASONS = %w[waiting_you failed_check turn_ended_incomplete].freeze

    # The values `waiting_on` can take.
    WAITING_ON = %w[nothing person agent lock].freeze

    # The values `next.event` can take.
    EVENTS = %w[gate_approved answered check_passed turn_ended ask_answered prompt_answered lock_released
      workflow_resumed agent_restarted launched stage_started task_started].freeze

    # @return [String] `done`, `waiting`, `waiting_lock`, `working`, `stuck`, `stopped`, `idle` or `none`
    attr_reader :state

    # @return [String] one of {WAITING_ON}
    attr_reader :waiting_on

    # @return [Hash, nil] `{event, action, ...}`, nil when nothing is expected
    attr_reader :next_step

    # @param name [String] the workspace
    # @param member [Hash] the snapshot member row (`spine`, `plan`, `running`, `daemon`, `questions`)
    # @param run [Hash, nil] the newest active run, as {Workspace::WorkflowStatus#runs} gives it
    # @param turn [Hash, nil] the goal's `turn`
    # @param pane [Hash, nil] the pane the turn is read from
    # @param plan_present [Boolean] whether the workspace has a readable plan file
    def initialize(name:, member:, run:, turn:, pane:, plan_present:)
      @name = name
      @member = member
      @run = run
      @turn = turn
      @pane = pane
      @plan_present = plan_present
      @reason = run&.dig("current", "reason")
      @plan_state = member.dig("plan", "state")
      @state = derive
      @waiting_on, @next_step = expect
    end

    private

    def derive
      flags = @run&.dig("current", "flags") || []
      spine = @member["spine"]
      return "done" if done?(spine)
      return "waiting" if (@reason && WAITING_REASONS.include?(@reason["code"])) || @plan_state == "waiting" || @turn&.dig("state") == "waiting"
      return "waiting_lock" if @reason && @reason["code"] == "waiting_lock"
      return "working" if @turn&.dig("state") == "working" || @plan_state == "working"
      return "stuck" if flags.intersect?(%w[idle timed_out]) || @reason&.dig("code") == "pane_gone" || @plan_state == "stalled" || run_without_daemon?
      return "stopped" if @member["running"] == false
      return "idle" if structure?(spine)
      "none"
    end

    def done?(spine)
      if spine && spine["exists"] && spine["stages"].to_i.positive?
        counts = spine["counts"] || {}
        return true if counts["completed"].to_i + counts["skipped"].to_i == spine["stages"]
      end
      @plan_state == "done" && @run.nil?
    end

    def run_without_daemon?
      @run && %w[running checking].include?(@run.dig("current", "state")) && @member["daemon"] && @member["daemon"]["up"] == false && @member["running"] != false
    end

    def structure?(spine)
      !@run.nil? || (spine && spine["exists"]) || !(@plan_state.nil? || @plan_state == "empty")
    end

    def expect
      case @state
      when "done", "none" then ["nothing", nil]
      when "waiting" then waiting_next
      when "waiting_lock"
        ["lock", {"event" => "lock_released", "resource" => @reason.dig("details", "resource"), "holder" => @reason.dig("details", "holder"),
                  "action" => Array(@reason["actions"]).first}]
      when "working" then ["agent", {"event" => "turn_ended", "action" => nil}]
      when "stuck"
        ["person", {"event" => @run ? "workflow_resumed" : "agent_restarted", "action" => @run ? action("workflow resume", @run["id"]) : action("launch", @name)}]
      when "stopped" then ["person", {"event" => "launched", "action" => action("launch", @name)}]
      else ["person", {"event" => (@run || !@plan_present) ? "stage_started" : "task_started", "action" => nil}]
      end
    end

    def waiting_next
      if @reason && WAITING_REASONS.include?(@reason["code"])
        event = {"waiting_you" => ((@reason.dig("details", "kind") == "gate") ? "gate_approved" : "answered"),
                 "failed_check" => "check_passed", "turn_ended_incomplete" => "turn_ended"}.fetch(@reason["code"])
        return ["person", {"event" => event, "action" => Array(@reason["actions"]).first}]
      end
      ask = Array(@member["questions"]).first
      if ask
        return ["person", {"event" => "ask_answered", "action" => action("ask answer", ask["id"].to_s, "--name", @name, needs: [{"name" => "answer", "flag" => nil}])}]
      end
      focus = @pane ? action("focus", @name, "--pane", @pane["pane_id"].to_s) : nil
      ["person", {"event" => "prompt_answered", "action" => focus}]
    end

    def action(name, *args, needs: [])
      {"action" => name, "args" => args, "needs" => needs}
    end
  end
end
