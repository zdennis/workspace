# frozen_string_literal: true

# Recording fakes of the collaborators the agent daemon's desks take. Each records its calls in +calls+ as
# `[method, *arguments]` and answers what it was given; nothing touches a pane, a thread or a file.
# `fake_contract_spec` checks that each accepts every call its real class accepts.

# Fake of the Workspace::SessionMonitor reads a restart checks: each pane's kind, agent pid and delivery
# facts as given. +rescan_pane+ moves a pane to its +rescanned+ kind, as an agent started since the last scan.
class RecordingRestartMonitor
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param kinds [Hash{String=>String}] pane id to the kind the monitor knows
  # @param rescanned [Hash{String=>String}] pane id to the kind a rescan finds
  # @param agent_pids [Hash{String=>Integer}]
  # @param delivery_facts [Hash{String=>Hash}]
  def initialize(kinds: {}, rescanned: {}, agent_pids: {}, delivery_facts: {})
    @kinds = kinds.dup
    @rescanned = rescanned
    @agent_pids = agent_pids
    @delivery_facts = delivery_facts
    @calls = []
  end

  def pane_kind(pane_id)
    @calls << [:pane_kind, pane_id]
    @kinds[pane_id]
  end

  def rescan_pane(pane_id)
    @calls << [:rescan_pane, pane_id]
    @kinds[pane_id] = @rescanned[pane_id] if @rescanned.key?(pane_id)
    nil
  end

  def agent_pid(pane_id)
    @calls << [:agent_pid, pane_id]
    @agent_pids[pane_id]
  end

  def delivery_facts(pane_id)
    @calls << [:delivery_facts, pane_id]
    @delivery_facts[pane_id]
  end
end

# Fake of Workspace::ContextReader#read: answers +reading+ for every pane.
class RecordingContextReader
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param reading [Hash] what each read answers (+:pct+, +:error+, +:updated_at+)
  def initialize(reading: {pct: 40, error: nil, updated_at: Time.utc(2026, 11, 11)})
    @reading = reading
    @calls = []
  end

  def read(pane_id:, agent_pid: nil, current_session_id: nil, kind: nil)
    @calls << [:read, {pane_id: pane_id, agent_pid: agent_pid, current_session_id: current_session_id, kind: kind}]
    @reading
  end
end

# Fake of Workspace::RestartRegistry: a pane listed in +held+ is refused, any other is claimed once; a started
# worker's block is kept in +workers+, not run, so a spec runs it by hand (or never). +start_worker+ raises
# +fail_start+ when given, as a thread that could not be made.
class RecordingRestartRegistry
  CONTROL_METHODS = %i[calls workers].freeze

  attr_reader :calls, :workers

  # @param held [Array<String>] pane ids another claim holds
  # @param fail_start [Exception, nil] raised by +start_worker+
  def initialize(held: [], fail_start: nil)
    @held = held.dup
    @fail_start = fail_start
    @calls = []
    @workers = {}
  end

  def claim_pending(pane_id)
    @calls << [:claim_pending, pane_id]
    return false if @held.include?(pane_id)
    @held << pane_id
    true
  end

  def start_worker(pane_id, &work)
    @calls << [:start_worker, pane_id]
    raise @fail_start if @fail_start
    @workers[pane_id] = work
  end

  def abandon_pending(pane_id)
    @calls << [:abandon_pending, pane_id]
    @held.delete(pane_id)
  end
end

# Fake of Workspace::RestartRunner#run: records each run and types nothing.
class RecordingRestartRunner
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def run(started, prompt, force, timeout, client, run_id: nil)
    @calls << [:run, started, prompt, force, timeout, client, {run_id: run_id}]
    nil
  end
end
