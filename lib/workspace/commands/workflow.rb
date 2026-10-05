require "json"

module Workspace
  module Commands
    # The `workflow` and `step` subcommands: shows definitions, starts a run
    # in a workspace's agent pane, shows where runs stand, and lets a person
    # move one (resume, cancel, approve, reject) or the run's own agent report
    # on its step. {Workspace::WorkflowEngine} makes every transition.
    #
    # Reads print one JSON document with `json: true`. Mutations return the
    # row the CLI puts in its action document, and print a line for a person.
    class Workflow
      # Bumped whenever a `--json` document's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # What `step done --status` accepts.
      REPORT_STATUSES = %w[pass fail].freeze

      # @param catalog [Workspace::WorkflowCatalog]
      # @param engine [Workspace::WorkflowEngine]
      # @param status [Workspace::WorkflowStatus]
      # @param store [Workspace::WorkflowRunStore]
      # @param panes [Workspace::WorkflowPanes]
      # @param clock [#call] returns the current Time
      # @param output [IO]
      def initialize(catalog:, engine:, status:, store:, panes:, clock: -> { Time.now }, output: $stdout)
        @catalog = catalog
        @engine = engine
        @status = status
        @store = store
        @panes = panes
        @clock = clock
        @output = output
      end

      # Prints one definition, or every definition when +id+ is nil.
      #
      # @param id [String, nil]
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `unknown_workflow` or `invalid_workflow`
      def show(id: nil, json: false)
        return list(json) unless id
        definition = @catalog.find(id)
        data = definition.to_h
        if json
          return document("workflow" => data.merge("source" => definition.source, "path" => definition.path, "sha256" => definition.sha256))
        end
        @output.puts "#{data["id"]}: #{data["title"]} (#{definition.source}, #{definition.path})"
        @output.puts data["description"] if data["description"]
        @output.puts "Inputs:" if data["inputs"].any?
        data["inputs"].each { |name, spec| @output.puts "  #{name}#{" (required)" if spec["required"]}#{": #{spec["description"]}" if spec["description"]}" }
        @output.puts "Steps:"
        data["steps"].each { |step| @output.puts "  #{step["id"].ljust(12)} #{step_traits(step)}".rstrip }
      end

      # Starts a run of a workflow in a workspace.
      #
      # @param id [String] the workflow
      # @param workspace [String]
      # @param worktree [String] the workspace's checkout
      # @param inputs [Hash{String=>String}]
      # @param pane [String, nil] the pane to run in (a pane id or `window.pane`); nil for the workspace's Claude pane
      # @param note [String, nil] added to every step's instructions
      # @param dry_run [Boolean] check everything and start nothing
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] see {Workspace::WorkflowEngine#preflight}
      def run(id:, workspace:, worktree:, inputs: {}, pane: nil, note: nil, dry_run: false)
        definition = @catalog.find(id)
        if dry_run
          pane_id = pane ? @panes.locate(workspace, pane) : @panes.default_pane(workspace, start_daemon: false)
          checked = @engine.preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane_id)
          @output.puts "Would start #{id} in #{workspace} at step #{checked["step"]}" \
            "#{pane_id ? " in pane #{pane_id}" : " (its agent daemon is not running; starting the run starts it and picks the Claude pane)"}."
          return {"workspace" => workspace, "outcome" => "dry_run", "reason" => nil, "message" => nil, "workflow" => id,
                  "step" => checked["step"], "pane" => pane_id, "inputs" => checked["inputs"], "packs" => checked["packs"]}
        end
        pane_id = pane ? @panes.locate(workspace, pane) : @panes.default_pane(workspace)
        row(@engine.start(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane_id, note: note), "started")
      end

      # Prints where runs stand: one run, or the runs still going.
      #
      # @param run [String, nil] a run id
      # @param workspace [String, nil] only this workspace's runs
      # @param all [Boolean] finished runs too
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `unknown_run`
      def status(run: nil, workspace: nil, all: false, json: false)
        result = run ? @status.run(run) : @status.runs(workspace: workspace, all: all)
        return document("generated_at" => @clock.call.utc.iso8601, "runs" => result["runs"], "warnings" => result["warnings"]) if json
        @output.puts "No workflow runs#{" in #{workspace}" if workspace}#{" still going" unless all}." if result["runs"].empty?
        result["runs"].each { |each| describe(each) }
        result["warnings"].each { |warning| @output.puts "Warning: #{warning}" }
      end

      # Gets a run going again. Everything the engine would refuse is refused
      # first; only then is a daemon started or a pane picked.
      #
      # @param run [String] a run id
      # @param from [String, nil] start again at this step
      # @param note [String, nil] added to the next attempt's instructions
      # @param pane [String, nil] move the run to this pane of its workspace
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [Hash{String=>Object}] the action row; `outcome` is "unchanged" when an agent
      #   is working on the step or its check is still running
      # @raise [Workspace::Error] code `bound_pane` for `--from` at a waiting gate from a pane
      #   bound to a run, or see {Workspace::WorkflowEngine#resume}
      def resume(run:, from: nil, note: nil, pane: nil, caller_pane: nil)
        stored = @store.find(run)
        pane_id = nil
        turn_over = nil
        unless WorkflowRunStore::TERMINAL_STATES.include?(stored["state"])
          state = stored["steps"].fetch(stored["current"])
          refuse_bound_pane!(caller_pane, "workflow resume --from") if from && state.dig("gate", "state") == "waiting"
          @engine.refuse_resume(stored, from: from)
          pane_id = resume_pane(stored, pane)
          if pane_id.nil? && from.nil? && state["state"] == "running" && stored["reason"].nil? &&
              @panes.idle?(stored["workspace"], @panes.pane_of(run) || stored["pane"])
            turn_over = {"step" => stored["current"], "attempt" => state["attempts"].last&.fetch("n", nil)}
          end
        end
        resumed = @engine.resume(run, from: from, note: note, pane: pane_id, turn_over: turn_over)
        row(resumed, resumed["unchanged"] ? "unchanged" : "resumed", message: resumed["unchanged"] && "Nothing was done: #{resumed["unchanged"]}.")
      end

      # @param run [String] a run id
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
      def cancel(run:)
        row(@engine.cancel(run), "cancelled")
      end

      # Passes a gate. Refused from a pane a run is bound to, so an agent
      # can't pass its own gate.
      #
      # @param run [String] a run id
      # @param note [String, nil] added to the next step's instructions
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `bound_pane`, or see {Workspace::WorkflowEngine#approve}
      def approve(run:, note: nil, caller_pane: nil)
        refuse_bound_pane!(caller_pane, "workflow approve")
        row(@engine.approve(run, note: note), "approved")
      end

      # @param run [String] a run id
      # @param note [String] why
      # @param to [String, nil] the step to run again
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] see {Workspace::WorkflowEngine#reject}
      def reject(run:, note:, to: nil)
        row(@engine.reject(run, note: note, to: to), "rejected")
      end

      # What the agent daemon runs when a turn ends in a bound pane, and on
      # its timer for a run nothing else would wake. Prints nothing.
      #
      # @param run [String] a run id
      # @param turn_ended [Boolean] a turn ended; false is the timer's look
      # @param pane [String, nil] the pane the turn ended in
      # @param turn_started [Time, nil] when the turn that ended began, when the daemon knows
      # @return [void]
      def advance(run:, turn_ended: false, pane: nil, turn_started: nil)
        turn_ended ? @engine.turn_ended(run, pane: pane, turn_started: turn_started) : @engine.tick(run)
        nil
      end

      # The agent's own report on its step (`step done`).
      #
      # @param pane [String, nil] the pane the agent runs in (`$TMUX_PANE`)
      # @param status [String] "pass" or "fail"
      # @param summary [String, nil]
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `not_bound` outside a run's pane, `step_not_running`
      def step_done(pane:, status: "pass", summary: nil)
        raise UsageError, "--status must be pass or fail, got #{status.to_s[0, 40].inspect}." unless REPORT_STATUSES.include?(status)
        run_id = bound_run!(pane)
        reported = @engine.report(run_id, status: status, summary: summary)
        @output.puts "Recorded #{status} for step #{reported["step"]} (attempt #{reported["attempt"]}) of run #{run_id}. " \
          "End your turn now; the step is decided when the turn ends."
        {"workspace" => @store.find(run_id)["workspace"], "outcome" => "recorded", "reason" => nil, "message" => nil, "run_id" => run_id,
         "step" => reported["step"], "attempt" => reported["attempt"], "reported" => reported["reported"].slice("status", "summary")}
      end

      # Prints the step the calling pane is on (`step status`).
      #
      # @param pane [String, nil] the pane the agent runs in (`$TMUX_PANE`)
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `not_bound` outside a run's pane
      def step_status(pane:, json: false)
        run = @store.find(bound_run!(pane))
        step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
        state = run["steps"].fetch(run["current"])
        attempt = state["attempts"].last || {}
        started = attempt["started_at"] && Time.iso8601(attempt["started_at"])
        produces = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }.map do |path|
          # A file an earlier attempt left has to be written again to count.
          {"path" => path, "exists" => File.exist?(path), "current" => File.exist?(path) && (started.nil? || File.mtime(path) >= started)}
        end
        info = {"run_id" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"], "step" => run["current"],
                "attempt" => attempt["n"], "state" => state["state"], "instructions" => attempt["prompt_file"],
                "artifacts_dir" => run["artifacts_dir"], "produces" => produces, "check" => !step["status"].nil?,
                "reported" => attempt["reported"]&.slice("status", "summary")}
        return document("step" => info) if json
        @output.puts "Step #{info["step"]} (attempt #{info["attempt"]}, #{info["state"]}) of workflow run #{info["run_id"]} (#{info["workflow"]}) in #{info["workspace"]}."
        @output.puts "Instructions: #{info["instructions"]}" if info["instructions"]
        produces.each do |file|
          found = if file["current"]
            "there"
          else
            file["exists"] ? "left by an earlier attempt; write it again" : "missing"
          end
          @output.puts "Must be written by the time your turn ends: #{file["path"]} (#{found})"
        end
        @output.puts "When your turn ends, the runner runs the step's check." if info["check"]
        @output.puts "Reported: #{info["reported"]["status"]}#{" (#{info["reported"]["summary"]})" if info["reported"]["summary"]}" if info["reported"]
      end

      private

      def document(body)
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true}.merge(body))
      end

      def list(json)
        entries = @catalog.list
        return document("workflows" => entries) if json
        @output.puts "No workflows." if entries.empty?
        entries.each do |entry|
          problems = entry["problems"].any? ? "  INVALID: #{entry["problems"].first}" : ""
          @output.puts "#{entry["id"].ljust(16)} #{entry["source"].ljust(8)} #{entry["title"]}#{problems}"
        end
      end

      def step_traits(step)
        traits = []
        traits << "produces #{step["produces"].join(", ")}" if step["produces"].any?
        traits << "uses #{step["uses"].join(", ")}" if step["uses"].any?
        traits << "check" if step["status"]
        traits << "gate: #{step["gate"]}" if step["gate"]
        traits << "on fail: back to #{step["on_fail"]["goto"]}, #{step["on_fail"]["max"]} time(s)" if step["on_fail"]
        traits << "continues the conversation" if step["context"] == "continue"
        traits.join("; ")
      end

      # The run the step's pane is bound to keeps the pane it has unless that pane is gone:
      # only then is the workspace's Claude pane looked up (which starts its agent daemon).
      def resume_pane(stored, pane)
        return @panes.locate(stored["workspace"], pane) if pane
        gone = stored.dig("reason", "code") == "pane_gone" || (@panes.pane_of(stored["id"]) && !@panes.alive?(stored["id"]))
        gone ? @panes.default_pane(stored["workspace"]) : nil
      end

      # A gate is passed by a person. The check guards against an agent's mistake and is not
      # a boundary: an agent can clear `$TMUX_PANE`.
      def refuse_bound_pane!(caller_pane, verb)
        bound = caller_pane && @panes.run_on(caller_pane)
        return unless bound
        raise Workspace::Error.new("A gate is passed by a person: this pane (#{caller_pane}) is bound to workflow run #{bound}, " \
          "so `#{verb}` is refused here. Run it from another terminal.",
          code: "bound_pane", details: {"pane" => caller_pane, "run_id" => bound})
      end

      def bound_run!(pane)
        run_id = pane && !pane.empty? && @panes.run_on(pane)
        return run_id if run_id
        raise Workspace::Error.new("This pane is not bound to a workflow run#{" (not inside tmux)" if pane.nil? || pane.empty?}.",
          code: "not_bound", details: {"pane" => pane})
      end

      # The action row for a run after a transition. A step that could not be
      # started is a failed action, though the run exists and can be resumed.
      def row(run, verb, message: nil)
        shown = @status.run(run["id"])["runs"].first
        reason = shown.dig("current", "reason")
        undelivered = reason && reason.dig("details", "kind") == "dispatch"
        describe(shown)
        @output.puts message if message
        {"workspace" => run["workspace"], "outcome" => undelivered ? "failed" : verb, "reason" => reason&.fetch("code"),
         "message" => undelivered ? reason.dig("details", "message") : message, "run" => shown}
      end

      def describe(run)
        current = run["current"]
        where = %w[completed cancelled failed].include?(run["state"]) ? "" : "  step #{current["step"]}#{" (attempt #{current["attempt"]})" if current["attempt"]}, #{current["state"]}"
        @output.puts "#{run["id"]}  #{run["workflow"]}  #{run["workspace"]}  #{run["state"]}#{where}"
        reason = current["reason"]
        @output.puts "  #{reason["code"]}: #{reason_text(reason)}" if reason
        current["flags"].each { |flag| @output.puts "  flag: #{flag}" }
        reason&.fetch("actions")&.each { |action| @output.puts "    workspace #{action["action"]} #{(action["args"] + needed(action)).join(" ")}" }
      end

      # What a person has to supply, shown as an upper-case placeholder where it goes.
      def needed(action)
        action["needs"].flat_map { |need| [need["flag"] || "--", need["name"].upcase] }
      end

      def reason_text(reason)
        details = reason["details"]
        case reason["code"]
        when "waiting_lock"
          holder = details["holder"]
          who = if holder["run_id"]
            "run #{holder["run_id"]}#{" (step #{holder["step"]})" if holder["step"]}#{" in #{holder["workspace"]}" if holder["workspace"]}"
          else
            "#{(holder["kind"] == "process") ? "the dev environment" : "an agent"}#{" in #{holder["worktree"]}" if holder["worktree"]} (pid #{holder["pid"]})"
          end
          "queued for #{details["resource"]}, #{details["position"]} of #{details["total"]}, held by #{who}"
        when "waiting_you"
          case details["kind"]
          when "gate" then "step #{details["step"]} passed and waits for approval#{" (#{details["artifacts"].join(", ")})" if details["artifacts"].any?}"
          when "prompt" then "pane #{details["pane"]} is waiting for an answer#{": #{details["message"]}" if details["message"]}"
          when "ask" then "open question #{details["ask"]}: #{details["question"]}"
          else "step #{details["step"]} could not be started (#{details["error"]}): #{details["message"]}"
          end
        when "turn_ended_incomplete"
          stale = Array(details["stale"])
          ["the turn ended", ("without #{details["missing"].join(", ")}" if details["missing"].any?),
            ("with #{stale.join(", ")} left by an earlier attempt and not written again" if stale.any?)].compact.join(" ")
        when "failed_check"
          if details["cause"] == "reported"
            "step #{details["step"]} was reported failed#{": #{details["summary"]}" if details["summary"]}"
          else
            "step #{details["step"]}'s check #{details["timed_out"] ? "ran past its time limit" : "exited #{details["exit_code"].inspect}"}; log: #{details["log"]}"
          end
        when "pane_gone" then "pane #{details["pane"]} of #{details["workspace"]} is not running#{": #{details["message"]}" if details["message"]}"
        else details.to_s
        end
      end
    end
  end
end
