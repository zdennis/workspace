# frozen_string_literal: true

# A callable collaborator (a restart, a runner) whose +call(**kwargs)+ runs the given block.
class ScriptedCall
  def initialize(&on_call)
    @on_call = on_call
  end

  def call(**kwargs)
    @on_call.call(**kwargs)
  end
end
