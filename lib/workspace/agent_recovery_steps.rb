# frozen_string_literal: true

module Workspace
  # Picks the runner of steps 2 to 5 for each kind of recovery attempt on the
  # {Workspace::AgentRecoveryDesk}'s behalf. With no runner given it keeps the
  # desk's own.
  class AgentRecoverySteps
    # @param restart [#call, nil] fixed runner for a restart attempt, given an attempt and answering
    #   +[outcome, agent]+; nil keeps the desk's own
    # @param typed [#call, nil] the same for a typed attempt
    # @return [Workspace::AgentRecoverySteps]
    def self.running(restart: nil, typed: nil) = new(restart: restart, typed: typed)

    # @param restart [#call, nil] see {.running}
    # @param typed [#call, nil] see {.running}
    def initialize(restart: nil, typed: nil)
      @restart = restart
      @typed = typed
    end

    # @param own [#call] the desk's own restart runner
    # @return [#call] the runner for a restart attempt
    def restart_runner(own) = @restart || own

    # @param own [#call] the desk's own typed runner
    # @return [#call] the runner for a typed attempt
    def typed_runner(own) = @typed || own
  end
end
