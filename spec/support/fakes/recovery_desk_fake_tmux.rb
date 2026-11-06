# frozen_string_literal: true

require_relative "../cli_test_helpers"

# A tmux whose one pane shows a screen that a delivery with Enter empties and
# one without Enter fills, for the agent recovery desk's specs.
class RecoveryDeskFakeTmux < CLITestHelpers::FakeTmux
  attr_accessor :details, :screen, :scripted, :start_commands, :on_deliver, :gone, :on_details

  def initialize(screen)
    super()
    @screen = screen
    @empty = screen
    @details = [{id: "%5", window: 0, index: 1, pid: 10, command: "claude"}]
    @start_commands = [{window: 0, index: 1, id: "%5", start_command: nil}]
  end

  def pane_details(_session, window: "0")
    raise ArgumentError, "expected every window" unless window.nil?
    on_details&.call
    @details
  end

  def session_gone?(_session) = @gone == true

  def pane_start_commands(_session) = @start_commands

  def server_pid_for_pane(pane_id, timeout: nil) = (@details.any? { |detail| detail[:id] == pane_id }) ? "77" : nil

  def capture_screen(_pane_id) = @scripted ? @scripted.call : @screen

  def capture_screen_styled(pane_id) = capture_screen(pane_id)

  def deliver(session, pane, text, enter: true)
    @screen = enter ? @empty : @screen.sub(/❯ \n\z/, "❯ #{text}\n────────\n")
    sent_keys << {session: session, pane: pane, text: text, enter: enter}
    on_deliver&.call(text)
    Workspace::Tmux::Delivery.new(status: enter ? :submitted : :pasted, message: "fake")
  end
end
