# frozen_string_literal: true

# Recording fakes of the collaborators the workflow engine's phase classes take. Each records its calls in
# +calls+ as `[method, *arguments]` and answers what it was given; nothing touches a file, a pane or git.
# `fake_contract_spec` checks that each accepts every call its real class accepts.

# Fake of Workspace::InstructionComposer#compose: answers +text+ and +packs+ as given.
class RecordingComposer
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param text [String]
  # @param packs [Array<String>] the refs of the packs the answer names
  def initialize(text: "composed", packs: [])
    @text = text
    @packs = packs
    @calls = []
  end

  def compose(packs:, cwd:, binding: nil, workflow: nil, step: nil, attempt: nil, skip: [])
    @calls << [:compose, {packs: packs, cwd: cwd, binding: binding, workflow: workflow, step: step, attempt: attempt, skip: skip}]
    {"text" => @text, "packs" => @packs.map { |ref| {"ref" => ref} }}
  end
end

# Fake of Workspace::GitExclude: records each pattern added, and says it is listed once added.
class RecordingGitExclude
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def add(worktree, pattern)
    @calls << [:add, worktree, pattern]
    true
  end

  def listed?(worktree, pattern)
    @calls.include?([:add, worktree, pattern])
  end
end

# Fake of Workspace::WorkflowRunChange over the run Hashes a RecordingRunStore holds: +call+ yields the stored
# Hash and a real Context, keeps the line a block registered in +deliveries+ (it types nothing) and returns the run.
class RecordingRunChange
  CONTROL_METHODS = %i[calls events deliveries].freeze

  attr_reader :calls, :events, :deliveries

  # @param runs [Hash{String=>Hash}] the stored runs by id
  # @param finished [Array<String>] ids whose change raises `run_not_active`, as for a run cancelled meanwhile
  def initialize(runs, finished: [])
    @runs = runs
    @finished = finished
    @calls = []
    @events = []
    @deliveries = []
  end

  def call(run_id, nonblocking: false)
    @calls << [:call, run_id, {nonblocking: nonblocking}]
    raise Workspace::Error.new("run #{run_id} has ended", code: "run_not_active") if @finished.include?(run_id)
    stored = @runs.fetch(run_id)
    ctx = Workspace::WorkflowRunChange::Context.new
    yield stored, ctx
    @deliveries << ctx.delivery if ctx.delivery
    stored
  end

  def event(run, type, data = {})
    @events << [Workspace::WorkflowRun.from_h(run).id, type, data]
  end
end

# Fake of the Workspace::WorkflowRunStore calls the phases make: +create+ runs the check, gives the next id and keeps
# the run in +runs+; +on_checkout+, +parked_on+ and +backoff_on+ answer the run Hash scripted for the path or pane, as
# a WorkflowRun (+backoff_on+ only while its +same_pane+ says so); +going?+ is true for the ids given; +record_event+
# keeps each history line in +events+.
class RecordingRunStore
  CONTROL_METHODS = %i[calls runs events].freeze

  attr_reader :calls, :runs, :events

  # @param on_checkout [Hash{String=>Hash}] the run going on each checkout path
  # @param ids [Array<String>] the ids +create+ hands out, in order
  # @param going [Array<String>] the ids of the runs still going
  # @param parked_on [Hash{String=>Hash}] the run whose park waits for each pane
  # @param backoff_on [Hash{String=>Hash}] the run whose retry or budget hold waits for each pane
  def initialize(on_checkout: {}, ids: %w[wr_1 wr_2], going: [], parked_on: {}, backoff_on: {})
    @on_checkout = on_checkout
    @ids = ids.dup
    @going = going
    @parked_on = parked_on
    @backoff_on = backoff_on
    @runs = {}
    @calls = []
    @events = []
  end

  def run(id)
    @calls << [:run, id]
    Workspace::WorkflowRun.from_h(@runs.fetch(id))
  end

  def going?(id)
    @calls << [:going?, id]
    @going.include?(id)
  end

  def parked_on(pane, except:, now:)
    @calls << [:parked_on, pane, {except: except, now: now}]
    found = @parked_on[pane]
    (found && found["id"] != except) ? Workspace::WorkflowRun.from_h(found) : nil
  end

  def backoff_on(pane, except:, same_pane:)
    @calls << [:backoff_on, pane, {except: except}]
    found = @backoff_on[pane]
    return nil unless found && found["id"] != except
    same_pane.call(pane, (found["backoff"] || found["budget_hold"] || {})["identity"]) ? Workspace::WorkflowRun.from_h(found) : nil
  end

  def record_event(id, type, data = {})
    @events << [id, type, data]
  end

  def create(run, check = nil)
    @calls << [:create, run]
    check&.call
    run = {"id" => @ids.shift}.merge(run)
    yield run if block_given?
    @runs[run["id"]] = run
  end

  def on_checkout(path)
    @calls << [:on_checkout, path]
    found = @on_checkout[path]
    found && Workspace::WorkflowRun.from_h(found)
  end
end

# Fake of Workspace::WorkflowPrompt: answers fixed text and packs, and the paths the real one would give.
class RecordingWorkflowPrompt
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param text [String]
  # @param packs [Array<String>] the refs of the packs the answer names
  def initialize(text: "composed", packs: [])
    @text = text
    @packs = packs
    @calls = []
  end

  def artifacts_dir(worktree, run_id) = File.join(worktree, ".workflow", run_id)

  def compose(run, step, context, binding: nil)
    @calls << [:compose, Workspace::WorkflowRun.from_h(run), step["id"], context, binding]
    {"text" => @text, "packs" => @packs.map { |ref| {"ref" => ref} }}
  end

  def prompt_path(run, step, attempt_number)
    File.join(Workspace::WorkflowRun.from_h(run).artifacts_dir, "steps", "#{step["id"]}.#{attempt_number}.prompt.md")
  end

  def step_binding(run, step, attempt_number, path)
    {"kind" => "run", "id" => Workspace::WorkflowRun.from_h(run).id, "step" => step["id"], "attempt" => attempt_number, "instructions" => path}
  end

  def write(run, step, attempt_number, context)
    path = prompt_path(run, step, attempt_number)
    @calls << [:write, path, context]
    [path, compose(run, step, context, binding: step_binding(run, step, attempt_number, path))]
  end
end

# Fake of Workspace::WorkflowDispatch for the phases above it: +dispatch+ registers a line naming the run's step on
# +ctx+ and returns the run as it was given; +check_pane+ refuses the panes it was told are busy; +release+ records
# the run's id; +drop_park+ returns the run without its park.
class RecordingDispatch
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param busy [Array<String>] the panes +check_pane+ refuses with `pane_has_run`
  def initialize(busy: [])
    @busy = busy
    @calls = []
  end

  def dispatch(run, ctx:, context: nil, budgeted: true, retry_of: nil)
    run = Workspace::WorkflowRun.from_h(run)
    @calls << [:dispatch, run.id, {context: context, budgeted: budgeted, retry_of: retry_of}]
    ctx.deliver("step" => run.current)
    run
  end

  def check_pane(pane, run_id: nil)
    @calls << [:check_pane, pane, {run_id: run_id}]
    raise Workspace::Error.new("Pane #{pane} is busy.", code: "pane_has_run", details: {"pane" => pane}) if @busy.include?(pane)
  end

  def release(run)
    @calls << [:release, Workspace::WorkflowRun.from_h(run).id]
  end

  def drop_park(run, how, extra = {})
    run = Workspace::WorkflowRun.from_h(run)
    @calls << [:drop_park, run.id, how, extra]
    run.drop_park
  end
end

# Fake of Workspace::RunResources: +acquire+ answers the result it was given (everything taken by default),
# +release+ the names it was given.
class RecordingRunResources
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param acquired [Hash] what +acquire+ answers, merged over a result that took nothing and waits for nothing
  # @param released [Array<String>] the lock names +release+ gives up
  def initialize(acquired: {}, released: [])
    @acquired = {status: :ok, acquired: [], released: [], handed_over: [], waiting: nil}.merge(acquired)
    @released = released
    @calls = []
  end

  def acquire(run_id:, step:, uses:, worktree:, workflow: nil, workspace: nil, pane: nil)
    @calls << [:acquire, {run_id: run_id, step: step, uses: uses, worktree: worktree, workflow: workflow, workspace: workspace, pane: pane}]
    @acquired
  end

  def release(run_id:, worktree:, names: nil)
    @calls << [:release, {run_id: run_id, worktree: worktree, names: names}]
    @released
  end
end

# Fake of the Workspace::WorkflowPanes calls the phases make: bindings, pane runs and gone panes as scripted, a +kick+
# that answers what it was given, and the calls that change or ask about a pane kept in +calls+.
class RecordingWorkflowPanes
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param bound [Hash{String=>String}] the pane each run id is bound to
  # @param runs_on [Hash{String=>String}] the run id each pane is bound to
  # @param dead [Array<String>] run ids whose binding was made for another pane
  # @param kick [Hash] what +kick+ answers
  # @param same [Boolean] what +same_pane?+ answers
  # @param gone [Array<String>] the panes tmux no longer has
  def initialize(bound: {}, runs_on: {}, dead: [], kick: {ok: true}, same: true, gone: [])
    @bound = bound
    @runs_on = runs_on
    @dead = dead
    @gone = gone
    @kick = kick
    @same = same
    @calls = []
  end

  def pane_of(run_id) = @bound[run_id]

  def run_on(pane) = @runs_on[pane]

  def alive?(run_id) = !@dead.include?(run_id)

  def pane_gone?(pane) = @gone.include?(pane)

  def identity(run_id) = "identity-of-#{run_id}"

  def same_pane?(pane, identity)
    @calls << [:same_pane?, pane, identity]
    @same
  end

  def bind(workspace:, pane:, run_id:, step:, attempt:, instructions:, artifacts:)
    @calls << [:bind, {workspace: workspace, pane: pane, run_id: run_id, step: step, attempt: attempt, instructions: instructions, artifacts: artifacts}]
    true
  end

  def unbind(run_id)
    @calls << [:unbind, run_id]
    true
  end

  def kick(workspace:, pane:, text:, fresh:, run_id: nil)
    @calls << [:kick, {workspace: workspace, pane: pane, text: text, fresh: fresh, run_id: run_id}]
    @kick
  end
end

# Fake of Workspace::WorkflowAttemptRecord#start and #finish: the attempt as given, with a stand-in hash of the
# composed text at its start and an empty +outputs+ at its end.
class RecordingAttemptRecord
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def start(run:, attempt:, composed:)
    @calls << [:start, Workspace::WorkflowRun.from_h(run).id, attempt["n"]]
    Workspace::WorkflowRun::Attempt.from_h(attempt.merge("prompt_sha256" => "sha256-of-#{composed["text"]}"))
  end

  def finish(run:, step:, attempt:)
    @calls << [:finish, Workspace::WorkflowRun.from_h(run).id, step["id"], attempt["n"]]
    Workspace::WorkflowRun::Attempt.from_h(attempt.merge("outputs" => []))
  end
end

# Fake of Workspace::WorkflowLogTail: a block naming the log and the line count it was asked for.
class RecordingLogTail
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def block(path, lines:)
    @calls << [:block, path, {lines: lines}]
    "the last #{lines} lines of #{path}"
  end
end

# Fake of Workspace::WorkflowProgress#pass_step and #fail_step for the evaluation phase: records the step and the
# failure, and returns the run with the current step marked passed or failed (nothing else happens to it).
class RecordingProgress
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def pass_step(run, ctx:)
    @calls << [:pass_step, Workspace::WorkflowRun.from_h(run).current]
    marked(run, "passed")
  end

  def fail_step(run, failure, ctx:)
    @calls << [:fail_step, Workspace::WorkflowRun.from_h(run).current, failure]
    marked(run, "failed")
  end

  private

  def marked(run, state)
    hash = Workspace::WorkflowRun.from_h(run).to_mutable_h
    hash["steps"][hash["current"]]["state"] = state
    Workspace::WorkflowRun.from_h(hash)
  end
end

# Fake of Workspace::WorkflowCheck#call: answers the result it was given, after asking +stop_when+ once (kept in
# +stop_answers+), and records the command it was asked to run.
class RecordingChecker
  CONTROL_METHODS = %i[calls stop_answers].freeze

  attr_reader :calls, :stop_answers

  # @param result [Hash] what +call+ answers (`exit_code:`, `timed_out:`, `error:`)
  def initialize(result: {exit_code: 0, timed_out: false, error: nil})
    @result = result
    @calls = []
    @stop_answers = []
  end

  def call(cwd:, timeout:, log:, command: nil, argv: nil, stop_when: nil, env: {})
    @calls << [:call, {command: command, cwd: cwd, timeout: timeout, log: log, env: env}]
    @stop_answers << stop_when&.call
    @result
  end
end

# Fake of Workspace::WorkflowRequire#check and #run_outside: +check+ answers the scripted results in order (nil once
# they run out), +run_outside+ the one it was given.
class RecordingRequire
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param checks [Array<Hash, nil>] what each +check+ call answers
  # @param outside [Hash] what +run_outside+ answers ("record" and "unmet")
  def initialize(checks: [], outside: {"record" => {}, "unmet" => nil})
    @checks = checks.dup
    @outside = outside
    @calls = []
  end

  def check(run:, step:, attempt:, from: 0)
    @calls << [:check, step["id"], attempt["n"], {from: from}]
    @checks.shift
  end

  def run_outside(pending, cwd:, env: {}, stop_when: nil)
    @calls << [:run_outside, pending, {cwd: cwd}]
    @outside
  end
end

# Fake of Workspace::WorkflowGuard#check and #config_change: answers what it was given.
class RecordingGuard
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param found [Hash, nil] what +check+ answers
  # @param config [Hash, nil] what +config_change+ answers
  def initialize(found: nil, config: nil)
    @found = found
    @config = config
    @calls = []
  end

  def check(worktree, base, scope)
    @calls << [:check, worktree, scope]
    @found
  end

  def config_change(worktree, base, seen: nil)
    @calls << [:config_change, worktree, {seen: seen}]
    @config
  end
end

# Fake of Workspace::CommandsConfig#for_project: the project's commands as given.
class RecordingCommandsConfig
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param commands [Hash{Symbol=>String}] e.g. `{test: "rake"}`
  def initialize(commands = {})
    @commands = commands
    @calls = []
  end

  def for_project(workspace)
    @calls << [:for_project, workspace]
    @commands
  end
end

# Fake of Workspace::InboxStore#upsert: keeps each record and its +reopen+ in +calls+.
class RecordingInbox
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def upsert(record, reopen: false)
    @calls << [:upsert, record, {reopen: reopen}]
    record
  end
end
