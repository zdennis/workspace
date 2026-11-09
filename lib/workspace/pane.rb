# frozen_string_literal: true

module Workspace
  # One tmux pane of one session, as the agent daemon's desks see it: they ask the pane to
  # capture, type, press a key and describe itself, and pass no session name or pane id.
  # +Tmux+ stays the adapter underneath. Not to be confused with {TmuxPane}, which resolves a
  # pane spec given on a command line.
  class Pane
    ID_FORMAT = /\A%\d+\z/

    attr_reader :id

    # @param tmux [Tmux]
    # @param session_name [String] the tmux session the pane belongs to
    # @param id [String] a tmux pane id such as "%23"
    # @param row [Hash, nil] the pane's row from +Tmux#pane_details+ already read; the first
    #   {#details} answers from it, so a lookup that listed the panes costs no second call
    # @raise [ArgumentError] when +id+ is not a tmux pane id
    def initialize(tmux:, session_name:, id:, row: nil)
      raise ArgumentError, "not a tmux pane id: #{id.inspect}" unless id.is_a?(String) && ID_FORMAT.match?(id)

      @tmux = tmux
      @session_name = session_name
      @id = id
      @row = row
    end

    # @return [String, nil] the screen as plain text, nil when tmux could not read it
    def capture
      @tmux.capture_screen(@id)
    end

    # @return [String, nil] the screen with its styling, nil when tmux could not read it
    def capture_styled
      @tmux.capture_screen_styled(@id)
    end

    # @return [Tmux::Delivery]
    def deliver(text, enter: true)
      @tmux.deliver(@session_name, @id, text, enter: enter)
    end

    # @param key [String] a tmux key name such as "C-u" or "Enter"
    # @return [Boolean]
    def send_key(key)
      @tmux.send_key(@session_name, @id, key)
    end

    # @return [Hash, nil] this pane's row of +Tmux#pane_details+, nil when the session no
    #   longer lists it. The first call answers from the row the pane was built with, if any.
    def details
      row, @row = @row, nil
      return row if row

      @tmux.pane_details(@session_name, window: nil).find { |detail| detail[:id] == @id }
    end

    # @return [String, nil] the pid of the tmux server the pane lives in, nil when it is gone
    def server_pid
      @tmux.server_pid_for_pane(@id)
    end

    # @return [String, nil, Symbol] the command the pane was started with, nil when it had none,
    #   +:gone+ when tmux's list of start commands has no row for it
    def start_command
      row = @tmux.pane_start_commands(@session_name).find { |candidate| candidate[:id] == @id }
      row ? row[:start_command] : :gone
    end

    # @return [Boolean] whether tmux says the pane's session no longer exists
    def session_gone?
      @tmux.session_gone?(@session_name)
    end
  end
end
