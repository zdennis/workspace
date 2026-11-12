# frozen_string_literal: true

# Recording fakes of the collaborators Workspace::RecoveryFacts reads through. Each appends its calls to
# +calls+ as `[method, *arguments]`, an Array several fakes may share so a spec reads the order of the reads
# across them, and answers what it was given; nothing starts a process or reads a file.
# `fake_contract_spec` checks that each accepts every call its real class accepts.

# Fake of Workspace::ProcessTree#snapshot: answers +snapshot+, or raises +error+.
class RecordingProcessTree
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param snapshot [Object] what each read answers
  # @param error [Exception, nil] raised by +snapshot+, as a `ps` that failed
  def initialize(snapshot: :tree, error: nil, calls: [])
    @snapshot = snapshot
    @error = error
    @calls = calls
  end

  def snapshot
    @calls << [:snapshot]
    raise @error if @error
    @snapshot
  end
end

# Fake of the Workspace::AgentStopper reads: the agent under a pane pid, and the process-group answers.
class RecordingRecoveryStopper
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param agents [Hash{Integer=>Hash}] pane pid to the agent found under it
  # @param foreground [Boolean] what +foreground?+ answers
  # @param clear [Boolean] what +pane_clear?+ answers
  def initialize(agents: {}, foreground: true, clear: true, calls: [])
    @agents = agents
    @foreground = foreground
    @clear = clear
    @calls = calls
  end

  def find_agent(pane_pid:, detector:, tree:)
    @calls << [:find_agent, pane_pid, tree]
    @agents[pane_pid]
  end

  def foreground?(pid:, pane_pid:)
    @calls << [:foreground?, pid, pane_pid]
    @foreground
  end

  def pane_clear?(pane_pid:, command:, detector:, tree:)
    @calls << [:pane_clear?, pane_pid, command, tree]
    @clear
  end
end

# Fake of the Workspace::SessionLedger reads: a session's last start, and the record open in a pane.
class RecordingRecoveryLedger
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param starts [Hash{String=>String}] session id to its last SessionStart time
  # @param open_record [Hash, nil] what +read_open_record+ answers
  # @param error [Exception, nil] raised by +read_open_record+
  def initialize(starts: {}, open_record: nil, error: nil, calls: [])
    @starts = starts
    @open_record = open_record
    @error = error
    @calls = calls
  end

  def last_start_at(session_id)
    @calls << [:last_start_at, session_id]
    @starts[session_id]
  end

  def read_open_record(pane_id:, tmux_server:)
    @calls << [:read_open_record, pane_id, tmux_server]
    raise @error if @error
    @open_record
  end
end

# Fake of Workspace::TranscriptSummary#last_turn_record: answers +record+ for every path.
class RecordingTurnTranscript
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param record [Hash, nil]
  def initialize(record: nil, calls: [])
    @record = record
    @calls = calls
  end

  def last_turn_record(path)
    @calls << [:last_turn_record, path]
    @record
  end
end

# Fake of the Workspace::SessionMonitor reads a recovery check makes: delivery facts and running sub-agents.
class RecordingRecoveryMonitor
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param delivery_facts [Hash, nil] what +delivery_facts+ answers
  # @param running [Integer, nil] what +running_subagents+ answers
  def initialize(delivery_facts: nil, running: 0, calls: [])
    @delivery_facts = delivery_facts
    @running = running
    @calls = calls
  end

  def delivery_facts(pane_id)
    @calls << [:delivery_facts, pane_id]
    @delivery_facts
  end

  def running_subagents(pane_id)
    @calls << [:running_subagents, pane_id]
    @running
  end
end

# Fake of Workspace::PromptTyper#check: answers the refusal given for an +exact:+ check, and +refusal+ otherwise.
class RecordingInputCheck
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param refusal [Symbol, nil] what a plain check answers; nil means the input line is free
  # @param exact_refusal [Symbol, nil] what a check with +exact:+ answers
  def initialize(refusal: nil, exact_refusal: nil, calls: [])
    @refusal = refusal
    @exact_refusal = exact_refusal
    @calls = calls
  end

  def check(pane_id, pasted: nil, exact: nil)
    @calls << [:check, pane_id, {pasted: pasted, exact: exact}.compact]
    exact ? @exact_refusal : @refusal
  end
end
