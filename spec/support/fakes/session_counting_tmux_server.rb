# frozen_string_literal: true

# A fake tmux server that counts how often its sessions were listed.
class SessionCountingTmuxServer < CLITestHelpers::FakeTmuxServer
  attr_reader :sessions_calls

  def initialize(...)
    super
    @sessions_calls = 0
  end

  def sessions
    @sessions_calls += 1
    super
  end
end
