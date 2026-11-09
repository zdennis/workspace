# frozen_string_literal: true

# A fake event log that notes each record call in a shared order list.
class OrderRecordingEventLog < CLITestHelpers::FakeEventLog
  def initialize(order:)
    super()
    @order = order
  end

  def record(**)
    @order << :event
    super
  end
end
