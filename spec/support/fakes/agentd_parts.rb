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

# Fake of Workspace::PipelineConfig: the stages given for each workspace (nil: no pipeline).
class RecordingPipelineConfig
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param stages [Hash{String=>Array<Hash>}] workspace name to its stages (+:pane_index+, +:role+, +:timeout+)
  def initialize(stages: {})
    @stages = stages
    @calls = []
  end

  def stages_for(name)
    @calls << [:stages_for, name]
    @stages[name]
  end

  def pipeline?(name)
    @calls << [:pipeline?, name]
    !@stages[name].nil?
  end
end

# Fake of Workspace::PipelineState held in memory: the entries a work item moves through, in the shape the
# real one keeps (a started item sits at its workspace's first stage of +stages+).
class RecordingPipelineState
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param stages [Array<Hash>] the stages a started item's first stage is read from
  # @param entries [Array<Hash>] entries already in flight, as a previous daemon left them
  def initialize(stages: [], entries: [])
    @stages = stages
    @entries = entries.to_h { |entry| [entry[:work_item_ref], entry.dup] }
    @calls = []
  end

  def start(work_item_ref:, workspace_name:, dispatch_id:, sentinel_token: nil, deadline: nil)
    @calls << [:start, work_item_ref]
    stage = @stages.first
    @entries[work_item_ref] = {work_item_ref: work_item_ref, workspace_name: workspace_name, dispatch_id: dispatch_id,
                               pane_index: stage ? stage[:pane_index] : 0, phase: stage && stage[:role],
                               sentinel_token: sentinel_token, deadline: deadline}
  end

  def current(work_item_ref) = @entries[work_item_ref]

  def advance(work_item_ref:, to_stage:, sentinel_token: nil, deadline: nil)
    @calls << [:advance, work_item_ref, to_stage[:role]]
    entry = @entries[work_item_ref]
    entry&.merge!(pane_index: to_stage[:pane_index], phase: to_stage[:role], sentinel_token: sentinel_token, deadline: deadline)
  end

  def deadline(work_item_ref) = @entries[work_item_ref]&.dig(:deadline)

  def complete(work_item_ref:)
    @calls << [:complete, work_item_ref]
    @entries.delete(work_item_ref)
  end

  def in_flight_refs = @entries.keys

  def in_flight
    @entries.values.map { |entry| {"work_item_ref" => entry[:work_item_ref], "dispatch_id" => entry[:dispatch_id], "phase" => entry[:phase]} }
  end
end

# Fake of Workspace::WorkCoordinatorClient: records registrations and reports, answers +register_reply+ and
# the +replies+ in turn (the last repeating), and raises Workspace::Error for the first +register_failures+
# registrations and the first +failures+ reports.
class RecordingCoordinatorClient
  CONTROL_METHODS = %i[calls reports registrations replies= register_reply= register_failures=].freeze

  attr_reader :calls, :status_socket_path
  attr_writer :replies, :register_reply, :register_failures

  # @param register_reply [Hash] what each +register+ answers
  # @param replies [Array<Hash>] what the reports answer in turn
  # @param failures [Integer] how many reports fail before one is answered
  # @param register_failures [Integer] how many registrations fail before one is answered
  def initialize(register_reply: {"ok" => true, "epoch" => "wc-1"}, replies: [{"ok" => true}], failures: 0, register_failures: 0,
    status_socket_path: "/tmp/wc-status.sock")
    @register_reply = register_reply
    @replies = replies.dup
    @failures = failures
    @register_failures = register_failures
    @status_socket_path = status_socket_path
    @calls = []
  end

  def register(name:, socket:, pipeline:, epoch:, in_flight: [], pid: Process.pid)
    @calls << [:register, {name: name, socket: socket, pipeline: pipeline, epoch: epoch, in_flight: in_flight}]
    if @register_failures.positive?
      @register_failures -= 1
      raise Workspace::Error, "connection refused"
    end
    @register_reply
  end

  def deregister(name:)
    @calls << [:deregister, name]
    {"ok" => true}
  end

  def report_status(payload)
    @calls << [:report_status, payload]
    if @failures.positive?
      @failures -= 1
      raise Workspace::Error, "connection refused"
    end
    (@replies.size > 1) ? @replies.shift : @replies.first
  end

  def reports = @calls.select { |call| call.first == :report_status }.map(&:last)

  def registrations = @calls.select { |call| call.first == :register }.map(&:last)
end

# Fake of Workspace::SentinelPoller: keeps the callbacks +start+ is given and runs none on its own, so a spec
# finishes, fails or times out the stage by hand.
class RecordingSentinelPoller
  CONTROL_METHODS = %i[session_name pane token deadline complete report_error time_out stopped?].freeze

  attr_reader :session_name, :pane, :token, :deadline

  def initialize(session_name:, pane:, token:, deadline:)
    @session_name = session_name
    @pane = pane
    @token = token
    @deadline = deadline
    @stopped = false
  end

  def start(on_error: nil, on_timeout: nil, &on_complete)
    @on_error = on_error
    @on_timeout = on_timeout
    @on_complete = on_complete
    self
  end

  def stop
    @stopped = true
  end

  def stopped? = @stopped

  # Runs the completion callback as a poller that saw the sentinel does.
  def complete(summary) = @on_complete.call(summary)

  def report_error(message) = @on_error.call(message)

  def time_out = @on_timeout.call
end
