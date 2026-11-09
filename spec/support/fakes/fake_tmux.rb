# frozen_string_literal: true

# The shared fake of Workspace::Tmux. It records the calls specs read back and answers from data the
# example gives it; nothing starts a process. `fake_contract_spec` checks that it accepts every call
# the real class accepts.
#
#   FakeTmux.new                                    # a quiet server: no sessions, no panes
#   FakeTmux.new(screens: ["❯ "], details: [{id: "%18", window: 0, index: 1}], session_name: "app")
#   FakeTmux.new(sessions: ["ws-alpha"], session_names: {"alpha" => "ws-alpha"})
class FakeTmux
  # Methods that only read or script the fake, so the real class has nothing to compare them with.
  CONTROL_METHODS = %i[
    sent_keys sent_key_names captured_output captured_output= pane_indexes pane_indexes= delivery_status delivery_status=
    delivered texts details details= screens screens= screen_script screen_script= on_deliver on_deliver= on_details
    on_details= statuses statuses= capture_calls sessions_calls sessions_strict_args styled_screens styled_screens=
    server_pid server_pid= start_commands start_commands= session_gone session_gone=
  ].freeze

  attr_reader :sent_keys, :sent_key_names, :capture_calls, :sessions_calls, :sessions_strict_args
  attr_accessor :styled_screens, :server_pid, :start_commands, :session_gone, :captured_output, :pane_indexes, :delivery_status, :details, :screens, :screen_script, :on_deliver,
    :on_details, :statuses

  # @param sessions [Array<String>] what `sessions` lists
  # @param sessions_error [Exception, nil] raised by `sessions`
  # @param session_name [String, nil] the one name `session_name_for` gives every config (default: the config)
  # @param session_names [Hash{String=>String}] a name per config, before `session_name`
  # @param sockets [Hash{String=>String}] `custom_socket_option` per config
  # @param details [Array<Hash>, nil] what `pane_details` lists (`window: nil` lists all, else one window); nil lists none
  # @param strict_windows [Boolean] `pane_details` refuses a call that does not ask for every window
  # @param screens [Array<String>] the screens `capture_screen` shows in turn, the last one repeating
  # @param styled_screens [Array<String>, nil] the answers of `capture_screen_styled` in turn, the last repeating (default: `screens`)
  # @param server_pid [String, nil] what `server_pid_for_pane` answers
  # @param start_commands [Array<Hash>] what `pane_start_commands` lists
  # @param session_gone [Boolean] what `session_gone?` answers
  # @param captures [Array<String>, nil] the answers of `capture_pane` in turn, the last repeating (default: `captured_output`)
  def initialize(sessions: [], sessions_error: nil, session_name: nil, session_names: {}, sockets: {}, details: nil,
    strict_windows: false, screens: [""], captures: nil, styled_screens: nil, server_pid: "4242", start_commands: [], session_gone: false)
    @sessions = sessions
    @sessions_error = sessions_error
    @session_name = session_name
    @session_names = session_names
    @sockets = sockets
    @details = details
    @strict_windows = strict_windows
    @screens = screens.dup
    @captures = captures&.dup
    @styled_screens = styled_screens&.dup
    @server_pid = server_pid
    @start_commands = start_commands
    @session_gone = session_gone
    @sent_keys = []
    @sent_key_names = []
    @captured_output = ""
    @pane_indexes = [0, 1, 2]
    @delivery_status = :submitted
    @statuses = []
    @capture_calls = 0
    @sessions_calls = 0
    @sessions_strict_args = []
    @mutex = Mutex.new
  end

  def sessions(strict: false)
    @sessions_strict_args << strict
    @sessions_calls += 1
    raise @sessions_error if @sessions_error
    @sessions
  end

  def start_server = nil

  def kill_session(_name, project: nil, socket: nil) = nil

  def custom_socket_option(config_name) = @sockets[config_name]

  def rename_window(_session, _index, _name) = nil

  def resize_pane(_session, _pane, _size) = true

  def capture_layout(_session, **_opts) = "layout-string"

  def apply_layout(_session, _layout, **_opts) = true

  def send_key(session, pane, key_name)
    sent_key_names << {session: session, pane: pane, key: key_name}
    true
  end

  def capture_pane(_session, _pane, **_opts)
    @mutex.synchronize do
      @capture_calls += 1
      next @captured_output unless @captures
      (@captures.size > 1) ? @captures.shift : @captures.first
    end
  end

  def capture_screen(_target)
    return @screen_script.call if @screen_script

    (@screens.size > 1) ? @screens.shift : @screens.first
  end

  def capture_screen_styled(target)
    return capture_screen(target) unless @styled_screens

    (@styled_screens.size > 1) ? @styled_screens.shift : @styled_screens.first
  end

  def server_pid_for_pane(_pane_id, timeout: nil) = @server_pid

  def pane_start_commands(_session) = @start_commands

  def session_gone?(_name) = @session_gone

  def send_keys(session, pane, text, enter: true)
    deliver(session, pane, text, enter: enter).ok?
  end

  # Records the send; the outcome is the next of `statuses`, else `delivery_status`.
  def deliver(session, pane, text, enter: true)
    sent_keys << {session: session, pane: pane, text: text, enter: enter}
    @on_deliver&.call(text)
    status = @statuses.shift || delivery_status
    Workspace::Tmux::Delivery.new(status: status, message: "fake #{status}")
  end

  # The sends in the shape the restart specs read.
  def delivered = sent_keys.map { |sent| {session: sent[:session], target: sent[:pane], text: sent[:text]} }

  def texts = sent_keys.map { |sent| sent[:text] }

  def panes(_session, **_opts) = @pane_indexes

  def find_pane_by_title(_session, _pattern, **_opts) = nil

  def pane_details(_session, window: "0")
    raise ArgumentError, "expected every window" if @strict_windows && !window.nil?
    @on_details&.call
    return [] unless @details

    window.nil? ? @details : @details.select { |detail| detail[:window] == window.to_i }
  end

  def find_claude_pane(_session, **_opts) = 1

  def split_window(_session, **_opts) = 3

  def command_for(_project, **_opts) = "tmuxinator start test --attach"

  def session_name_for(config_name) = @session_names.fetch(config_name) { @session_name || config_name }

  def reattach_or_start(session, start)
    "tmux -CC attach -t #{session} || tmux has-session -t #{session} 2>/dev/null || #{start}"
  end
end
