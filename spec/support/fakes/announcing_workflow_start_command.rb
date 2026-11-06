# frozen_string_literal: true

# A workflow start fake that prints a line to +gate+ before answering, as the
# real command prints its routing line.
class AnnouncingWorkflowStartCommand < CLITestHelpers::FakeWorkflowStartCommand
  def initialize(gate, line)
    super()
    @gate = gate
    @line = line
  end

  def call(**kw)
    @gate.puts @line
    super
  end
end
