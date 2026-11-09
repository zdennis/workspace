# frozen_string_literal: true

# The shared fake of Workspace::Pane: one in-memory pane that records what the desks type and press.
# It answers from a FakeTmux, so the screen, delivery and details scripting is FakeTmux's and not
# copied here. `fake_contract_spec` checks that it accepts every call a Pane accepts.
#
#   FakePane.new                                          # "%1", a blank screen, every delivery submitted
#   FakePane.new(id: "%18", screens: ["❯ "], row: {id: "%18", window: 0, index: 1, pid: 77})
#   pane = FakePane.new(statuses: [:pasted, :submitted]); pane.deliver("hi"); pane.deliveries
class FakePane
  CONTROL_METHODS = %i[tmux deliveries keys].freeze

  attr_reader :id, :tmux

  # @param tmux [FakeTmux, nil] a FakeTmux to share; the other keywords build one when it is nil
  # @param row [Hash, nil] this pane's `details` (default: a row with just its id)
  # @param tmux_options [Hash] FakeTmux keywords: `screens`, `styled_screens`, `server_pid`, `session_gone`...
  def initialize(id: "%1", session_name: "app", tmux: nil, row: nil, start_command: nil, **tmux_options)
    @id = id
    @session_name = session_name
    @row = row
    @tmux = tmux || FakeTmux.new(start_commands: [{window: 0, index: 1, id: id, start_command: start_command}], **tmux_options)
  end

  # What was delivered, in order: `{text:, enter:}`.
  def deliveries = @tmux.sent_keys.map { |sent| sent.slice(:text, :enter) }

  # The keys pressed, in order.
  def keys = @tmux.sent_key_names.map { |sent| sent[:key] }

  def capture = @tmux.capture_screen(@id)

  def capture_styled = @tmux.capture_screen_styled(@id)

  def deliver(text, enter: true) = @tmux.deliver(@session_name, @id, text, enter: enter)

  def send_key(key) = @tmux.send_key(@session_name, @id, key)

  def details = @row

  def server_pid = @tmux.server_pid_for_pane(@id)

  def start_command
    row = @tmux.pane_start_commands(@session_name).find { |candidate| candidate[:id] == @id }
    row ? row[:start_command] : :gone
  end

  def session_gone? = @tmux.session_gone?(@session_name)
end

# The shared fake of Workspace::PaneFactory: answers the FakePane it holds for an id, `:gone` for
# anything else, or `:unlisted` when it was told tmux lists nothing.
class FakePaneFactory
  CONTROL_METHODS = %i[panes].freeze

  attr_reader :panes

  # @param panes [Array<FakePane>] the panes the session lists
  # @param unlisted [Boolean] tmux lists no pane at all
  def initialize(panes: [], unlisted: false)
    @panes = panes
    @unlisted = unlisted
  end

  # The listed pane with this id, else a pane of its own, as the real one builds without listing.
  def for(pane_id, row: nil)
    return :gone unless pane_id.is_a?(String) && pane_id.match?(/\A%\d+\z/)

    @panes.find { |pane| pane.id == pane_id } || FakePane.new(id: pane_id, row: row)
  end

  def call(pane_id)
    return :gone unless pane_id.is_a?(String)
    return :unlisted if @unlisted || @panes.empty?

    @panes.find { |pane| pane.id == pane_id } || :gone
  end
end
