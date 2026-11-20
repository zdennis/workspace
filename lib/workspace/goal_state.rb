module Workspace
  # The goal's one `state`, who it waits on and the event that moves it on, from reads
  # that already exist: the plan's own state ({Workspace::PlanState}, in the snapshot
  # member's `plan.state`), the run's reason and flags ({Workspace::WorkflowStatus}), the
  # pane's state and the member's spine counts. It reads and writes nothing.
  class GoalState
    # Run reasons that mean a person has to act.
    WAITING_REASONS = %w[waiting_you failed_check turn_ended_incomplete waiting_agent_input paused].freeze

    # The values `waiting_on` can take.
    WAITING_ON = %w[nothing person agent lock].freeze

    # The values `next.event` can take.
    EVENTS = %w[gate_approved answered check_passed turn_ended ask_answered prompt_answered lock_released
      workflow_resumed run_unpaused agent_restarted launched stage_started task_started delivered].freeze

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
    # @param delivery [#call, nil] gives {Workspace::DeliveryFacts#read}'s Hash (nil when git cannot
    #   answer); with none given, delivery is not judged and a finished plan or spine is done
    # @param step [String, nil] the run's step the goal is read on: a fan_out sibling under way is read from its own
    #   entry in the row's `steps` (its `reason`, `flags` and `state`). Nil reads the run's cursor step, unless the
    #   cursor's step waits for no person and a sibling under way does: then that sibling's
    def initialize(name:, member:, run:, turn:, pane:, plan_present:, delivery: nil, step: nil)
      @name = name
      @member = member
      @run = run && WorkflowStatus::Row.from_h(run)
      @turn = turn
      @pane = pane
      @plan_present = plan_present
      @delivery_source = delivery
      @current = step_row(step)
      @reason = @current&.dig("reason")
      @plan_state = member.dig("plan", "state")
      @state = derive
      @waiting_on, @next_step = expect
    end

    # @return [Hash, nil] the branch's delivery facts, read once; nil when not judged or unreadable
    def delivery
      return @delivery if defined?(@delivery)
      @delivery = @delivery_source&.call
    end

    # @return [Array<Hash>] what done means for this goal until a `done:` block exists, each `{code, text}`
    def done_means
      [{"code" => "merged_into_base", "text" => "branch merged into #{base_name}"}]
    end

    # @return [Array<Hash>] what is still missing, each `{code, text}` (`not_merged` adds `ahead_of_base`);
    #   empty when merged (whatever the push state) or not judged. Codes: `not_pushed`, `not_merged`, `upstream_gone`, `delivery_unknown`
    def not_yet
      return [] unless @delivery_source
      facts = delivery
      return [{"code" => "delivery_unknown", "text" => "delivery unknown: git could not be read"}] unless facts
      return [] if facts["merged"]
      missing = []
      if facts["upstream_gone"]
        missing << {"code" => "upstream_gone", "text" => "upstream branch deleted (squash or rebase merged?)"}
      elsif facts["pushed"] == false
        missing << {"code" => "not_pushed", "text" => "not pushed"}
      end
      missing << not_merged(facts)
      missing
    end

    # @return [Boolean, nil] whether the branch is on the default branch; nil when delivery is not judged or unknown
    def delivered
      delivery&.dig("merged")
    end

    # @return [Boolean] whether delivery was judged, git could not answer and the plan or spine says the
    #   goal is otherwise finished (the only case where the missing answer decides the state)
    def delivery_unknown?
      !@delivery_source.nil? && delivery.nil? && complete?(@member["spine"])
    end

    private

    # The step the goal is read on, as a `current` row: +step+'s sibling entry when it is one under way, else the
    # cursor's, else (with no +step+) the first sibling under way that waits for a person when the cursor's does not.
    def step_row(step)
      current = @run&.current
      siblings = Array(@run&.steps).select { |each| each.is_a?(Hash) && each["group"] && each.key?("flags") && each["id"] != current&.dig("step") }
      named = siblings.find { |each| each["id"] == step } if step
      return sibling_current(named) if named
      return current if step || WAITING_REASONS.include?(current&.dig("reason", "code"))
      waiting = siblings.find { |each| WAITING_REASONS.include?(each.dig("reason", "code")) }
      waiting ? sibling_current(waiting) : current
    end

    # A sibling's `steps` entry read as a `current` row.
    def sibling_current(entry) = entry.merge("step" => entry["id"])

    def derive
      flags = @current&.dig("flags") || []
      spine = @member["spine"]
      return "done" if done?(spine)
      return "waiting" if (@reason && WAITING_REASONS.include?(@reason["code"]) && !incomplete_while_working?) || @plan_state == "waiting" || @turn&.dig("state") == "waiting"
      return "waiting_lock" if @reason && @reason["code"] == "waiting_lock"
      return "working" if @reason && @reason["code"] == "retry_backoff"
      return "working" if @turn&.dig("state") == "working" || @plan_state == "working"
      return "stuck" if flags.intersect?(%w[idle timed_out]) || @reason&.dig("code") == "pane_gone" || @plan_state == "stalled" || run_without_daemon?
      return "working" if flags.include?("background_work")
      if undelivered?(spine)
        @delivery_wait = true
        return "waiting"
      end
      return "stopped" if @member["running"] == false
      return "idle" if structure?(spine)
      "none"
    end

    # A Stop that lands before the step file exists reads `turn_ended_incomplete`; while the
    # turn is working again the agent is still on it, so nobody has to act.
    def incomplete_while_working?
      @reason["code"] == "turn_ended_incomplete" && @turn&.dig("state") == "working"
    end

    def not_merged(facts)
      ahead = facts["ahead_of_base"]
      text = ahead ? "not on #{base_name} (#{ahead} commit#{"s" unless ahead == 1} ahead)" : "not on #{base_name} (no origin default branch fetched)"
      {"code" => "not_merged", "text" => text, "ahead_of_base" => ahead}
    end

    def base_name
      delivery&.dig("base")&.delete_prefix("origin/") || (delivery&.dig("remote") ? "origin's default branch" : "the default branch")
    end

    # The plan or spine says every piece is done but the work has not landed.
    def undelivered?(spine)
      complete?(spine) && !delivered?
    end

    def delivered?
      @delivery_source.nil? || !!delivery&.dig("merged")
    end

    def done?(spine)
      complete?(spine) && delivered?
    end

    def complete?(spine)
      if spine && spine["exists"] && spine["stages"].to_i.positive?
        counts = spine["counts"] || {}
        return true if counts["completed"].to_i + counts["skipped"].to_i == spine["stages"]
      end
      @plan_state == "done" && (@run.nil? || @run.state == "completed")
    end

    def run_without_daemon?
      @run && %w[running checking reviewing].include?(@current&.dig("state")) && @member["daemon"] && @member["daemon"]["up"] == false && @member["running"] != false
    end

    def structure?(spine)
      !@run.nil? || (spine && spine["exists"]) || !(@plan_state.nil? || @plan_state == "empty")
    end

    def expect
      case @state
      when "done", "none" then ["nothing", nil]
      when "waiting" then @delivery_wait ? delivery_next : waiting_next
      when "waiting_lock"
        ["lock", {"event" => "lock_released", "resource" => @reason.dig("details", "resource"), "holder" => @reason.dig("details", "holder"),
                  "action" => Array(@reason["actions"]).first}]
      when "working" then ["agent", {"event" => "turn_ended", "action" => nil}]
      when "stuck"
        ["person", {"event" => @run ? "workflow_resumed" : "agent_restarted", "action" => @run ? NextAction.build("workflow resume", @run.id) : NextAction.build("launch", @name)}]
      when "stopped" then ["person", {"event" => "launched", "action" => NextAction.build("launch", @name)}]
      else ["person", {"event" => (@run || !@plan_present) ? "stage_started" : "task_started", "action" => nil}]
      end
    end

    # With the delivery facts unknown there is nothing a person can do about delivering.
    def delivery_next
      delivery ? ["person", {"event" => "delivered", "action" => nil}] : ["nothing", nil]
    end

    def waiting_next
      if @reason && WAITING_REASONS.include?(@reason["code"])
        event = {"waiting_you" => ((@reason.dig("details", "kind") == "gate") ? "gate_approved" : "answered"),
                 "failed_check" => "check_passed", "turn_ended_incomplete" => "turn_ended", "waiting_agent_input" => "answered", "paused" => "run_unpaused"}.fetch(@reason["code"])
        return ["person", {"event" => event, "action" => Array(@reason["actions"]).first}]
      end
      ask = Array(@member["questions"]).first
      if ask
        return ["person", {"event" => "ask_answered", "action" => NextAction.build("ask answer", ask["id"].to_s, "--name", @name, needs: [NextAction.need("answer", nil)])}]
      end
      focus = @pane ? NextAction.build("focus", @name, "--pane", @pane["pane_id"].to_s) : nil
      ["person", {"event" => "prompt_answered", "action" => focus}]
    end
  end
end
