# frozen_string_literal: true

require "json"

# Recording fakes of the collaborators Workspace::RecoveryIntake works through. Each appends its calls to
# +calls+ as `[method, *arguments]`, an Array several fakes may share so a spec reads the order of the calls
# across them; nothing starts a process or reads a file. `fake_contract_spec` checks that each accepts every
# call its real class accepts.

# Fake of Workspace::AgentRecoveryStore over a Hash in memory: +update+ yields the entry or an empty Hash,
# drops an entry left empty, and answers a copy of what it stored, as the file store does.
class RecordingRecoveryStore
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param entries [Hash{String=>Hash}] the entries held at the start
  def initialize(entries: {}, calls: [])
    @entries = entries.transform_values { |entry| copy(entry) }
    @calls = calls
  end

  def put(pane_id, entry)
    @calls << [:put, pane_id]
    @entries[pane_id] = copy(entry)
    copy(entry)
  end

  def get(pane_id)
    @calls << [:get, pane_id]
    @entries.key?(pane_id) ? copy(@entries[pane_id]) : nil
  end

  def update(pane_id)
    @calls << [:update, pane_id]
    entry = @entries.key?(pane_id) ? copy(@entries[pane_id]) : {}
    yield entry
    if entry.empty?
      @entries.delete(pane_id)
      return nil
    end
    @entries[pane_id] = copy(entry)
    copy(entry)
  end

  def entries
    @calls << [:entries]
    @entries.transform_values { |entry| copy(entry) }
  end

  private

  def copy(entry) = JSON.parse(JSON.generate(entry))
end

# Fake of Workspace::RecoveryFacts#live_agent: answers the agent given for each pane id, nil for any other.
class RecordingAgentFacts
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param agents [Hash{String=>Hash}] pane id to the agent found in it
  def initialize(agents: {}, calls: [])
    @agents = agents
    @calls = calls
  end

  def live_agent(pane_id)
    @calls << [:live_agent, pane_id]
    @agents[pane_id]
  end
end
