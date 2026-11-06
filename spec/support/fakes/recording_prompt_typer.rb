# frozen_string_literal: true

# Types through a real PromptTyper, recording each +type+ call; +answer_with+
# makes it answer a canned result (without typing) until +reset_answer+.
class RecordingPromptTyper
  attr_reader :calls

  def initialize(typer)
    @typer = typer
    @calls = []
    @answer = nil
  end

  def type(**kwargs)
    @calls << kwargs
    @answer || @typer.type(**kwargs)
  end

  def check(...) = @typer.check(...)

  def answer_with(result)
    @answer = result
  end

  def reset_answer
    @answer = nil
  end
end
