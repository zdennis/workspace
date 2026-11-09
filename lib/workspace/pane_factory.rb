# frozen_string_literal: true

module Workspace
  # Looks one pane of a session up and builds its {Pane}. The answer is a Pane, +:gone+ or
  # +:unlisted+, so each desk keeps its own refusal for each case.
  class PaneFactory
    # @param tmux [Tmux]
    # @param session_name [String]
    def initialize(tmux:, session_name:)
      @tmux = tmux
      @session_name = session_name
    end

    # @param pane_id [Object] the id a message named
    # @return [Pane, Symbol] the Pane, keeping the row found; +:gone+ for an id that is not a
    #   String or that the session does not list; +:unlisted+ when tmux listed no pane at all
    #   (it failed, or the session is gone), which must not read as every pane gone
    def call(pane_id)
      return :gone unless pane_id.is_a?(String)

      rows = @tmux.pane_details(@session_name, window: nil)
      return :unlisted if rows.empty?

      row = rows.find { |detail| detail[:id] == pane_id }
      return :gone unless row

      Pane.new(tmux: @tmux, session_name: @session_name, id: pane_id, row: row)
    end

    # Builds the pane of an id the caller already knows, with no tmux call: the desks use it where
    # they read a screen or type, so those paths make the calls they made before panes existed.
    #
    # @param pane_id [Object]
    # @param row [Hash, nil] the pane's row, when the caller has it
    # @return [Pane, Symbol] the Pane, or +:gone+ for anything that is not a tmux pane id
    def for(pane_id, row: nil)
      return :gone unless pane_id.is_a?(String) && Pane::ID_FORMAT.match?(pane_id)

      Pane.new(tmux: @tmux, session_name: @session_name, id: pane_id, row: row)
    end
  end
end
