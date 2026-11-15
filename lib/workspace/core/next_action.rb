# frozen_string_literal: true

module Workspace
  # The one builder of the `{action, args, needs}` entries that status documents
  # carry as next actions. With `needs` empty, `workspace <action> <args>` can be
  # run as it stands; each entry of `needs` names a value the person supplies
  # (`name`) and the flag to pass it with (`flag`, nil for a positional value).
  module NextAction
    # @param name [String] the command, such as "workflow resume"
    # @param args [Array<String>] arguments that follow the command
    # @param needs [Array<Hash>] values the person must supply (see {.need})
    # @param why [String, nil] why this action is offered; the "why" key is left out when nil
    # @return [Hash] `{"action", "args", "needs"}`, plus `"why"` when given
    def self.build(name, *args, needs: [], why: nil)
      entry = {"action" => name, "args" => args, "needs" => needs}
      entry["why"] = why if why
      entry
    end

    # @param name [String] what the person supplies
    # @param flag [String, nil] the flag that carries it, nil for a positional value
    # @param extra [Hash{String => Object}] further string-keyed members, such as "min" and "suggested"
    # @return [Hash] `{"name", "flag"}` merged with `extra`
    def self.need(name, flag, **extra)
      {"name" => name, "flag" => flag}.merge(extra)
    end
  end
end
