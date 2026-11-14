# frozen_string_literal: true

require "delegate"

# The engine the simulator plays, with a person who answers the stops it is told of, in order: each answer is
# `{on: CODE, resume: {...}}`, given to {WorkflowEngine#resume} when the run stops on CODE. A refused resume is
# recorded (its code) and the next answer is tried on the same stop. `elapse` moves the simulated clock before the
# author's turn of a step and attempt ends, so the run's time limit can be reached.
class PersonAtTheRun < SimpleDelegator
  # What a spec reads back: the stops answered and the resumes refused.
  CONTROL_METHODS = %i[refused answered].freeze

  attr_reader :refused, :answered

  def initialize(engine, store:, clock:, answers:, elapse: {})
    super(engine)
    @store = store
    @clock = clock
    @answers = answers.dup
    @elapse = elapse.dup
    @refused = []
    @answered = []
  end

  def turn_ended(run_id, pane: nil, **rest)
    run = @store.run(run_id)
    seconds = @elapse.delete([run.current, run.step(run.current).last_attempt&.n]) if pane == Workspace::WorkflowSimulator::PANE
    @clock.advance(seconds) if seconds
    result = __getobj__.turn_ended(run_id, pane: pane, **rest)
    answer(run_id)
    result
  end

  def tick(run_id)
    result = __getobj__.tick(run_id)
    answer(run_id)
    result
  end

  private

  def answer(run_id)
    while (code = @store.run(run_id).reason&.dig("code")) && @answers.first&.fetch(:on) == code
      given = @answers.shift.fetch(:resume, {})
      begin
        __getobj__.resume(run_id, **given)
        @answered << [code, given]
      rescue Workspace::Error => e
        @refused << [code, e.code]
      end
    end
  end
end
