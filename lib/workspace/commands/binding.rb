module Workspace
  module Commands
    # Binds a tmux pane to a workflow run or a PR review, so the SessionStart
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
        located = @locator.locate(workspace, pane)
        entry = @bindings.bind(located.fetch(:id), fields.transform_keys(&:to_s).merge(
          "workspace" => workspace, "session" => located.fetch(:session), "pane_slot" => @tmux.pane_slot(located.fetch(:id))
        ))
        @output.puts "Bound pane #{located.fetch(:id)} to #{entry["kind"]} #{entry["id"]}."
        entry
      end

      # @param pane [String] a pane id ("%19")
      # @return [Hash{String=>Object}] the pane's binding
      # @raise [Workspace::Error] code `not_bound` when the pane has none
      def show(pane:)
        entry = require_binding(pane)
        @output.puts @bindings.context_for(entry)
        entry
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

      def require_binding(pane)
        unless pane.to_s.match?(TmuxPane::PANE_ID)
          raise UsageError, "#{pane.to_s.inspect} is not a pane id (%19)."
        end
        @bindings.binding_for(pane) || raise(Workspace::Error.new("Pane #{pane} is not bound.", code: "not_bound", details: {"pane" => pane}))
      end
    end
  end
end
