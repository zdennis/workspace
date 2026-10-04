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
      def initialize(bindings:, locator:, tmux:, output: $stdout)
        @bindings = bindings
        @locator = locator
        @tmux = tmux
        @output = output
      end

      # Binds a pane of the workspace's tmux session.
      #
      # @param workspace [String]
      # @param pane [String] a pane id ("%19") or "window.pane" ("0.1"); stored by pane id
      # @param fields [Hash{String=>Object}] see {Workspace::PaneBindings#bind}
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
        @bindings.bind(located.fetch(:id), fields.transform_keys(&:to_s).merge(
          "workspace" => workspace, "session" => located.fetch(:session), "pane_slot" => @tmux.pane_slot(located.fetch(:id))
        ))
      end

      # Prints what the agent is told, and says so when the binding is stale.
      #
      # @param pane [String] a pane id ("%19")
      # @return [Hash{String=>Object}] the pane's binding, plus "stale" (see {#stale?})
      # @raise [Workspace::Error] code `not_bound` when the pane has none
      def show(pane:)
        entry = require_binding(pane)
        stale = stale?(entry)
        @output.puts @bindings.context_for(entry)
        if stale
          @output.puts "Stale: pane #{pane} is no longer at #{entry["pane_slot"] || entry["session"]}, where it was bound, " \
            "so the agent in it is not reminded. Bind it again, or clear it."
        end
        entry.merge("stale" => stale)
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

      # @param entry [Hash{String=>Object}] a binding
      # @return [Boolean] true when the pane is now in another session or slot, or
      #   tmux can't find it (see {Workspace::PaneBindings#stale?})
      def stale?(entry)
        pane = entry["pane_id"]
        @bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane))
      end

      # @param pane [String] a pane id ("%19")
      # @return [Hash{String=>Object}] the binding that was removed
      # @raise [Workspace::Error] code `not_bound` when the pane has none
      def clear(pane:)
        require_binding(pane)
        entry = @bindings.unbind(pane)
        @output.puts "Unbound pane #{pane}."
        entry
      end

      private

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
