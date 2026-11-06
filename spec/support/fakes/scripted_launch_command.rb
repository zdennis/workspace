# frozen_string_literal: true

# A launch command that records each call and answers it with a block.
class ScriptedLaunchCommand
  attr_reader :calls

  def initialize(&answer)
    @calls = []
    @answer = answer
  end

  def call(projects, **opts)
    @calls << [projects, opts]
    @answer.call(projects, **opts)
  end
end
