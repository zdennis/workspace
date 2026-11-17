module Workspace
  module Commands
    # Binds a tmux pane to a workflow run, a PR review or a library play, so the SessionStart
    # hook can remind the agent in that pane of its subject after a restart,
    # `/clear`, resume or compaction. See {Workspace::PaneBindings}.
    class Binding
      # @param bindings [Workspace::PaneBindings]
      # @param locator [Workspace::PaneLocator] resolves the pane to one of the workspace's own
      # @param tmux [Workspace::Tmux] reads the pane's slot
      # @param output [IO]
      # @param runs [#going?, #run, nil] the run store; nil means no pane is ever reported as owned by a run
      def initialize(bindings:, locator:, tmux:, output: $stdout, runs: nil)
        @runs = runs
        @bindings = bindings
        @locator = locator
        @tmux = tmux
        @output = output
      end

      # Binds a pane of the workspace's tmux session.
      #
      # @param workspace [String]
      # @param pane [String] a pane id ("%19") or "window.pane" ("0.1"); stored by pane id
      # @param fields [Hash{String=>Object}] see {Workspace::PaneBindings#bind}; a reviewer binding also
      #   records the tmux server's pid
      # @return [Hash{String=>Object}] the stored binding
      # @raise [Workspace::UsageError] for fields {Workspace::PaneBindings#bind} refuses
      # @raise [Workspace::Error] see {Workspace::PaneLocator#locate}
      def set(workspace:, pane:, **fields)
        entry = bind(workspace: workspace, pane: pane, **fields)
        @output.puts "Bound pane #{entry["pane_id"]} to #{entry["kind"]} #{entry["id"]}."
        entry
      end

      # Binds a pane like {#set}, printing nothing; `launch` uses it for the
      # pane it sent a play to.
      #
      # @param (see #set)
      # @return (see #set)
      # @raise (see #set)
      # @raise [SystemCallError] if `bindings.json` can not be written
      def bind(workspace:, pane:, **fields)
        located = @locator.locate(workspace, pane)
        stored = fields.transform_keys(&:to_s).merge(
          "workspace" => workspace, "session" => located.fetch(:session), "pane_slot" => @tmux.pane_slot(located.fetch(:id))
        )
        stored["server_pid"] = @tmux.server_pid_for_pane(located.fetch(:id)) if stored["role"] == "reviewer"
        @bindings.bind(located.fetch(:id), stored)
      end

      # Prints what the agent is told, and says so when the binding is stale. The packs
      # the agent is also told (see {Workspace::PaneBindings#packs_for}) are in the result, not the printout.
      #
      # @param pane [String] a pane id ("%19")
      # @return [Hash{String=>Object}] the pane's binding, plus "stale" (see {#stale?}), "packs" (`[]` when none) and "plays" (see {Workspace::PaneBindings#plays_for})
      # @raise [Workspace::Error] code `not_bound` when the pane has none
      def show(pane:)
        entry = require_binding(pane)
        stale = stale?(entry)
        @output.puts @bindings.context_for(entry)
        packs = @bindings.packs_for(entry)
        @output.puts "Packs: #{packs.join(", ")}." if packs.any?
        if stale
          @output.puts "Stale: pane #{pane} is no longer at #{entry["pane_slot"] || entry["session"]}, where it was bound, " \
            "so the agent in it is not reminded. Bind it again, or clear it."
        end
        entry.merge("stale" => stale, "packs" => packs, "plays" => @bindings.plays_for(entry))
      end

      # The pane's binding when the SessionStart hook would announce it.
      #
      # @param pane [String] a pane id ("%19")
      # @return [Hash{String=>Object}, nil] nil when the pane is not bound or its binding is stale
      # @raise [Workspace::UsageError] when `pane` is not a pane id
      def live(pane:)
        require_pane_id(pane)
        entry = @bindings.binding_for(pane)
        (entry && !stale?(entry)) ? entry : nil
      end

      # @param pane [String] a pane id ("%19")
      # @return [String, nil] the id of the going workflow run the pane is bound to (kind `run`, author or
      #   reviewer), nil for any other binding, a run that has ended or when no run store was given
      # @raise [Workspace::UsageError] when `pane` is not a pane id
      def owning_run(pane:)
        entry = live(pane: pane)
        return nil unless @runs && entry && entry["kind"] == "run"
        entry["id"] if @runs.going?(entry["id"])
      end

      # @param pane [String] a pane id ("%19")
      # @return [Hash{String=>Object}, nil] nil when no going run owns the pane, else the frozen
      #   `{"run", "pane", "paused"}` (paused is whether the run is paused)
      # @raise [Workspace::UsageError] when `pane` is not a pane id
      def owned(pane:)
        id = owning_run(pane: pane)
        return nil unless id
        {"run" => id, "pane" => pane, "paused" => !@runs.run(id).paused.nil?}.freeze
      end

      # @param owned [Hash{String=>Object}] what {#owned} returned
      # @param workspace [String]
      # @param action [Symbol] one of :type, :handoff_new, :handoff_check, :pause
      # @param own_pane [Boolean] whether the caller is the agent in the owned pane
      # @param resumed [Boolean] for :type, whether a paused plan was set back to active
      # @return [Hash] the frozen `{code:, message:, details:}` of the `pane_bound_to_run` refusal
      def refusal(owned, workspace:, action:, own_pane: false, resumed: false)
        run = owned.fetch("run")
        pane = owned.fetch("pane")
        paused = owned.fetch("paused")
        unpause_or_status = paused ? "workspace workflow unpause #{run}" : "workspace workflow status #{run}"
        use = if own_pane && %i[handoff_new handoff_check].include?(action)
          nil
        elsif action == :pause
          paused ? "workspace workflow status #{run}" : "workspace workflow pause #{run} [--interrupt]"
        else
          unpause_or_status
        end
        message = refusal_text(action, own_pane: own_pane, resumed: resumed, run: run, pane: pane, use: use, paused: paused)
        {code: "pane_bound_to_run", message: message,
         details: {"workspace" => workspace, "pane" => pane, "run" => run, "paused" => paused, "use" => use, "plan_resumed" => resumed}.freeze}.freeze
      end

      # Raises {#refusal} when a going run owns the pane.
      #
      # @param pane [String] a pane id ("%19")
      # @param (see #refusal)
      # @return [nil] when no run owns the pane
      # @raise [Workspace::Error] code `pane_bound_to_run`
      # @raise [Workspace::UsageError] when `pane` is not a pane id
      def refuse_owned!(pane:, workspace:, action:, own_pane: false, resumed: false)
        found = owned(pane: pane)
        return nil unless found
        refused = refusal(found, workspace: workspace, action: action, own_pane: own_pane, resumed: resumed)
        raise Workspace::Error.new(refused[:message], code: refused[:code], details: refused[:details])
      end

      # @param entry [Hash{String=>Object}] a binding
      # @return [Boolean] true when the pane is now in another session or slot, or
      #   tmux can't find it (see {Workspace::PaneBindings#stale?})
      def stale?(entry)
        pane = entry["pane_id"]
        @bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane),
          server_pid: -> { @tmux.server_pid_for_pane(pane) })
      end

      # @param pane [String] a pane id ("%19")
      # @return [Hash{String=>Object}] the binding that was removed
      # @raise [Workspace::Error] code `not_bound` when the pane has none
      def clear(pane:)
        require_binding(pane)
        entry = @bindings.unbind(pane)
        @output.puts "Unbound pane #{pane}."
        entry.merge("packs" => @bindings.packs_for(entry), "plays" => @bindings.plays_for(entry))
      end

      private

      def refusal_text(action, own_pane:, resumed:, run:, pane:, use:, paused:)
        case action
        when :type
          lead = "Pane #{pane} is bound to workflow run #{run}, which owns what is typed into it; nothing was typed."
          lead += " The plan was paused and is set back to active, so the run's agent takes it on its next attempt." if resumed
          "#{lead} Use `#{use}`."
        when :handoff_new
          return "This pane is bound to workflow run #{run}; the run owns its context, so it was not restarted. Finish or record where the step stands, then end your turn; the run checks the step and a retry starts fresh." if own_pane
          "Pane #{pane} is bound to workflow run #{run}; handoff would /clear the run's turn, so nothing was restarted. Use `#{use}`."
        when :handoff_check
          return "This pane is bound to workflow run #{run}, which owns its context; no save-state prompt was sent. Keep working on the step; do not hand off." if own_pane
          "Pane #{pane} is bound to workflow run #{run}; no save-state prompt was sent. Use `#{use}`."
        when :pause
          if paused
            "Pane #{pane} is bound to workflow run #{run}; a plan pause would not stop it, so the plan was left as it is. Run #{run} is already paused: `#{use}`."
          else
            "Pane #{pane} is bound to workflow run #{run}; a plan pause would not stop it, so the plan was left as it is. Use `#{use}`."
          end
        else
          raise ArgumentError, "unknown refusal action #{action.inspect}"
        end
      end

      def require_pane_id(pane)
        raise UsageError, "#{pane.to_s.inspect} is not a pane id (%19)." unless pane.to_s.match?(TmuxPane::PANE_ID)
      end

      def require_binding(pane)
        require_pane_id(pane)
        @bindings.binding_for(pane) || raise(Workspace::Error.new("Pane #{pane} is not bound.", code: "not_bound", details: {"pane" => pane}))
      end
    end
  end
end
