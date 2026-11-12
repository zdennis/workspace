# frozen_string_literal: true

# Recording fakes of the collaborators Workspace::RecoveryConfirmer works through, beside
# RecordingRecoveryStore and RecordingRecoveryMonitor. Each appends its calls to +calls+ as
# `[method, *arguments]`, an Array several fakes may share so a spec reads the order of the calls across
# them; nothing starts a process or reads a file. `fake_contract_spec` checks that each accepts every call
# its real class accepts.

# Fake of the Workspace::RecoveryFacts reads the confirmer makes. Each answers what it was given; +agents+
# is keyed on the pane pid of the detail given, as the stopper finds an agent under a pane.
class RecordingConfirmerFacts
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param details [Hash{String=>Hash, Symbol}] pane id to its details, or +:unknown+; a missing id is nil
  # @param agents [Hash{Integer=>Hash}] pane pid to the agent found under it
  # @param tree [Object, nil] what +tree+ answers, and the tree +agent+ reads; nil when the table can't be read
  # @param ledger [Hash, Symbol, nil] what +ledger_session+ answers
  # @param transcript [Hash, nil] what +transcript_error+ answers
  def initialize(details: {}, agents: {}, tree: :tree, ledger: nil, transcript: nil, calls: [])
    @details = details
    @agents = agents
    @tree = tree
    @ledger = ledger
    @transcript = transcript
    @calls = calls
  end

  def pane_detail(pane_id)
    @calls << [:pane_detail, pane_id]
    @details[pane_id]
  end

  def tree
    @calls << [:tree]
    @tree
  end

  def agent(detail)
    @calls << [:agent, detail]
    @tree && Workspace::RecoveryFacts::Agent.new(found: @agents[detail[:pid]], tree: @tree)
  end

  def live_agent(pane_id)
    @calls << [:live_agent, pane_id]
    detail = @details[pane_id]
    (detail.is_a?(Hash) && @tree) ? @agents[detail[:pid]] : nil
  end

  def ledger_session(pane_id)
    @calls << [:ledger_session, pane_id]
    @ledger
  end

  def transcript_error(entry)
    @calls << [:transcript_error, entry["session_id"]]
    @transcript
  end
end

# Fake of Workspace::RecoveryStopMarker#clear.
class RecordingStopMarker
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize(calls: [])
    @calls = calls
  end

  def clear(session_id)
    @calls << [:clear_marker, session_id]
  end
end

# Fake of Workspace::EventLog#record: keeps each line as `[type, project, data]` in +lines+.
class RecordingRecoveryEventLog
  CONTROL_METHODS = %i[calls lines].freeze

  attr_reader :calls, :lines

  def initialize(calls: [])
    @calls = calls
    @lines = []
  end

  def record(type:, project:, data: {})
    @calls << [:record, type]
    @lines << [type, project, data]
  end
end
