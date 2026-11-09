# frozen_string_literal: true

# FakeWorkflowPanes whose kick raises the given error (an Interrupt, say) until it is cleared with nil.
class InterruptibleWorkflowPanes < FakeWorkflowPanes
  attr_accessor :kick_error

  def kick(**args)
    raise kick_error if kick_error

    super
  end
end
