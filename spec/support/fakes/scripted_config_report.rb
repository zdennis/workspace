# frozen_string_literal: true

# A config report whose +show+ is answered by a block; the block gets the
# workspace and exactly the keywords the caller passed (+key:+, +scope:+).
class ScriptedConfigReport
  def initialize(&answer)
    @answer = answer
  end

  def show(workspace, **opts)
    @answer.call(workspace, **opts)
  end
end
