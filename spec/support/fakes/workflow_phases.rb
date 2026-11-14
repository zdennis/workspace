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
  # @param answer [Hash, nil] answered as it is in place of the text and packs, as a composer that hashes its packs does
  def initialize(text: "composed", packs: [], answer: nil)
    @text = text
    @packs = packs
    @answer = answer
    @calls = []
  end

  def compose(packs:, cwd:, binding: nil, workflow: nil, step: nil, attempt: nil, skip: [])
    @calls << [:compose, {packs: packs, cwd: cwd, binding: binding, workflow: workflow, step: step, attempt: attempt, skip: skip}]
    @answer || {"text" => @text, "packs" => @packs.map { |ref| {"ref" => ref} }}
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

# Fake of Workspace::WorkflowRunChange over the run Hashes a RecordingRunStore holds: +call+ yields the stored run
# as a frozen WorkflowRun and a real Context, writes the run the block returns (the one read for nil) back into the Hash,
# keeps the line a block registered in +deliveries+ (it types nothing), the review round in +reviews+, the ended round whose
# revision is computed again in +review_ends+ and the window to close in +closes+, and returns the run;
# a +nonblocking+ call on a run it was told is busy answers nil without yielding.
class RecordingRunChange
  CONTROL_METHODS = %i[calls events deliveries reviews review_ends closes].freeze

  attr_reader :calls, :events, :deliveries, :reviews, :review_ends, :closes

  # @param runs [Hash{String=>Hash}] the stored runs by id
  # @param finished [Array<String>] ids whose change raises `run_not_active`, as for a run cancelled meanwhile
  # @param busy [Array<String>] ids another process is changing, so a +nonblocking+ call answers nil
  # @param raises [Hash{Integer=>Exception}] the error the Nth +call+ (from 1) raises before reading, as for a run
  #   file that can't be read or written
  # @param raises_after [Hash{Integer=>Exception}] the error the Nth +call+ raises once its run is stored, as for a
  #   signal that comes just after a change commits
  # A block that raises leaves the stored run as it was, as the real store writes only when the block returns.
  def initialize(runs, finished: [], busy: [], raises: {}, raises_after: {})
    @runs = runs
    @finished = finished
    @busy = busy
    @raises = raises
    @raises_after = raises_after
    @calls = []
    @events = []
    @deliveries = []
    @reviews = []
    @review_ends = []
    @closes = []
  end

  def call(run_id, nonblocking: false)
    @calls << [:call, run_id, {nonblocking: nonblocking}]
    raise @raises[@calls.size] if @raises.key?(@calls.size)
    raise Workspace::Error.new("run #{run_id} has ended", code: "run_not_active") if @finished.include?(run_id)
    return nil if nonblocking && @busy.include?(run_id)
    stored = @runs.fetch(run_id)
    ctx = Workspace::WorkflowRunChange::Context.new
    read = Workspace::WorkflowRun.from_h(stored)
    changed = yield(read, ctx) || read
    raise TypeError, "a run change's block returned #{changed.class}, not a WorkflowRun" unless changed.is_a?(Workspace::WorkflowRun)
    stored.replace(changed.thawed)
    @deliveries << ctx.delivery if ctx.delivery
    @reviews << ctx.review if ctx.review
    @review_ends << ctx.review_end if ctx.review_end
    @closes << ctx.close_review if ctx.close_review
    ctx.after_locks.each do |each|
      each.call(changed)
    rescue
      nil
    end
    raise @raises_after[@calls.size] if @raises_after.key?(@calls.size)
    changed
  end

  def event(run, type, data = {})
    @events << [Workspace::WorkflowRun.from_h(run).id, type, data]
  end
end

# Fake of the Workspace::WorkflowRunStore calls the phases make: +create+ runs the check, gives the next id and keeps
# the run in +runs+; +on_checkout+, +parked_on+ and +backoff_on+ answer the run Hash scripted for the path or pane, as
# a WorkflowRun (+backoff_on+ only while its +same_pane+ says so); +going?+ is true for the ids given; +going+ answers every
# run it holds that has not finished; +record_event+ keeps each history line in +events+.
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

  # A fixed stamp, as the real store's digest of its directory.
  def stamp = "st0re"

  def stamps = [stamp]

  def going?(id)
    @calls << [:going?, id]
    @going.include?(id)
  end

  def going
    @calls << [:going]
    @runs.values.reject { |run| Workspace::WorkflowRunStore::TERMINAL_STATES.include?(run["state"]) }.map { |run| Workspace::WorkflowRun.from_h(run) }
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
    same_pane.call(pane, (found["backoff"] || found["budget_hold"] || found["timeout_hold"] || {})["identity"]) ? Workspace::WorkflowRun.from_h(found) : nil
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

  def review_path(run, step, attempt_number, round, rerun: nil)
    tag = rerun ? ".rerun#{rerun}" : ""
    File.join(Workspace::WorkflowRun.from_h(run).artifacts_dir, "steps", "#{step["id"]}.#{attempt_number}.r#{round}#{tag}.review.md")
  end

  def review_text(run, step, attempt_number, round, revision, only: nil, rerun: nil)
    @calls << [:review_text, Workspace::WorkflowRun.from_h(run), step["id"], attempt_number, round, revision, {only: only, rerun: rerun}]
    {"path" => review_path(run, step, attempt_number, round, rerun: only ? rerun : nil), "text" => "review prompt", "packs" => []}
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
# +ctx+ and returns the run as it was given (with +appends+, with a new attempt on the current step and no reason);
# +check_pane+ refuses the panes it was told are busy; +release+ records
# the run's id; +drop_park+ returns the run without its park; +hold_round+ and +hold_round_lock+ hold a round as told.
class RecordingDispatch
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param busy [Array<String>] the panes +check_pane+ refuses with `pane_has_run`
  # @param appends [Boolean] whether +dispatch+ starts a new attempt, as a delivered line does
  # @param holds [String, nil] the reason +hold_round+ holds a round with (`budget_spent` or `run_timed_out`); nil lets it start
  # @param lock_waits [String, nil] the lock +hold_round_lock+ makes a round wait for (`waiting_lock`); nil: the round holds its locks
  def initialize(busy: [], appends: false, holds: nil, lock_waits: nil)
    @busy = busy
    @appends = appends
    @holds = holds
    @lock_waits = lock_waits
    @calls = []
  end

  def hold_round_lock(run, round:, step_state:)
    run = Workspace::WorkflowRun.from_h(run)
    @calls << [:hold_round_lock, run.id, {round: round, step_state: step_state}]
    return nil unless @lock_waits
    Workspace::WorkflowRun.from_h(run.thawed.merge("state" => "waiting",
      "reason" => {"code" => "waiting_lock", "since" => "2026-11-10T12:00:00Z", "details" => {"resource" => @lock_waits, "step" => run.current, "review_round" => round}}))
  end

  def hold_round(run, round:)
    run = Workspace::WorkflowRun.from_h(run)
    @calls << [:hold_round, run.id, {round: round}]
    return nil unless @holds
    hold = (@holds == "run_timed_out") ? "timeout_hold" : "budget_hold"
    Workspace::WorkflowRun.from_h(run.thawed.merge("state" => "waiting", hold => {"review_round" => round},
      "reason" => {"code" => @holds, "since" => "2026-11-10T12:00:00Z", "details" => {"step" => run.current, "review_round" => round}}))
  end

  def dispatch(run, ctx:, context: nil, budgeted: true, retry_of: nil)
    run = Workspace::WorkflowRun.from_h(run)
    @calls << [:dispatch, run.id, {context: context, budgeted: budgeted, retry_of: retry_of}]
    ctx.deliver("step" => run.current)
    return run unless @appends
    hash = run.thawed
    attempts = hash["steps"][hash["current"]]["attempts"]
    attempts << {"n" => attempts.size + 1}
    Workspace::WorkflowRun.from_h(hash.merge("reason" => nil))
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
  # @param error [Exception, nil] raised by +acquire+, as for a lock store that can't be read
  def initialize(acquired: {}, released: [], error: nil)
    @acquired = {status: :ok, acquired: [], released: [], handed_over: [], waiting: nil}.merge(acquired)
    @released = released
    @error = error
    @calls = []
  end

  def acquire(run_id:, step:, uses:, worktree:, workflow: nil, workspace: nil, pane: nil)
    @calls << [:acquire, {run_id: run_id, step: step, uses: uses, worktree: worktree, workflow: workflow, workspace: workspace, pane: pane}]
    raise @error if @error
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
  CONTROL_METHODS = %i[calls gone_checks].freeze

  attr_reader :calls

  # @return [Array<Array>] each +pane_gone?+ asked: the pane and the workspace it named
  attr_reader :gone_checks

  # @param bound [Hash{String=>String}] the pane each run id is bound to
  # @param runs_on [Hash{String=>String}] the run id each pane is bound to as its author
  # @param reviewing [Hash{String=>String}] the run id each review pane is bound to
  # @param dead [Array<String>] run ids whose binding was made for another pane
  # @param kick [Hash] what +kick+ answers
  # @param same [Boolean] what +same_pane?+ answers
  # @param gone [Array<String>] the panes tmux no longer has
  # @param restarted [Array<String>] the review panes whose tmux server was restarted since the round recorded it
  # @param no_daemon [Boolean] +require_daemon+ refuses with `no_daemon`
  # @param on_kick [#call, nil] called with +kick+'s keywords before it answers, as when something else happens while
  #   the line is typed
  def initialize(bound: {}, runs_on: {}, dead: [], kick: {ok: true}, same: true, gone: [], restarted: [], reviewing: {}, no_daemon: false, on_kick: nil, turn_over: [], rows: {})
    @restarted = restarted
    @no_daemon = no_daemon
    @on_kick = on_kick
    @turn_over = turn_over
    @rows = rows
    @reviewing = reviewing
    @bound = bound
    @runs_on = runs_on
    @dead = dead
    @gone = gone
    @kick = kick
    @same = same
    @calls = []
    @gone_checks = []
  end

  def pane_of(run_id) = @bound[run_id]

  def run_on(pane) = @runs_on[pane]

  def bound_on(pane)
    return {run_id: @runs_on[pane], role: "author"} if @runs_on[pane]
    {run_id: @reviewing[pane], role: "reviewer"} if @reviewing[pane]
  end

  def alive?(run_id) = !@dead.include?(run_id)

  def pane_gone?(pane, workspace: nil)
    @gone_checks << [pane, workspace]
    @gone.include?(pane)
  end

  # Whether +pane+'s turn is proven over: listed in +turn_over+.
  def main_turn_over?(_workspace, pane) = @turn_over.include?(pane)

  def daemon_running?(_workspace) = !@no_daemon

  # The daemon's row of +pane+, from +rows+; nil for one it does not list.
  def pane_row(_workspace, pane) = @rows[pane]

  def identity(run_id) = "identity-of-#{run_id}"

  def same_pane?(pane, identity)
    @calls << [:same_pane?, pane, identity]
    @same
  end

  def bind(workspace:, pane:, run_id:, step:, attempt:, instructions:, artifacts:, role: nil, round: nil, relative_to: nil)
    fields = {workspace: workspace, pane: pane, run_id: run_id, step: step, attempt: attempt, instructions: instructions, artifacts: artifacts}
    fields.merge!(role: role, round: round, relative_to: relative_to) if role
    @calls << [:bind, fields]
    true
  end

  # Raises `no_daemon` when it was told the daemon can't be started.
  def require_daemon(workspace)
    @calls << [:require_daemon, workspace]
    raise Workspace::Error.new("Could not start the agent daemon for '#{workspace}'.", code: "no_daemon", details: {"workspace" => workspace}) if @no_daemon
  end

  def close_review(workspace, run_id, step: nil, round: nil)
    @calls << [:close_review, workspace, run_id, round ? {step: step, round: round} : {step: step}]
    []
  end

  # :gone for a pane in +gone+, :server_restarted for one in +restarted+, else :live.
  def review_pane_state(workspace, pane, server_pid)
    @calls << [:review_pane_state, workspace, pane, server_pid]
    return :gone if @gone.include?(pane)
    @restarted.include?(pane) ? :server_restarted : :live
  end

  def unbind(run_id, role: nil, pane: nil)
    given = {role: role, pane: pane}.compact
    @calls << (given.empty? ? [:unbind, run_id] : [:unbind, run_id, given])
    true
  end

  def kick(workspace:, pane:, text:, fresh:, run_id: nil)
    @calls << [:kick, {workspace: workspace, pane: pane, text: text, fresh: fresh, run_id: run_id}]
    @on_kick&.call(workspace: workspace, pane: pane, text: text, fresh: fresh, run_id: run_id)
    @kick
  end
end

# Fake of Workspace::WorkflowAttemptRecord#start, #finish, #abandon and #finish_round: the attempt as given, with a stand-in hash of the
# composed text at its start and an empty +outputs+ at its end; +abandon+ marks the current step's last attempt
# `cancelled` when it is still open (no `ended_at`); +finish_round+ answers the round's number, pane and times with
# the usage it was given and, for a round that read verdicts, its rows with `isolation` and the evidence it was given.
class RecordingAttemptRecord
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param round_usage [Hash, nil] the usage +finish_round+ records
  # @param round_evidence [Array<Hash>] the verdict copies +finish_round+ answers for a round that read verdicts
  def initialize(round_usage: nil, round_evidence: [])
    @round_usage = round_usage
    @round_evidence = round_evidence
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

  def abandon(run)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    @calls << [:abandon, hash["id"]]
    last = hash["steps"][hash["current"]]["attempts"].last
    if last && !last["ended_at"]
      last["outcome"] = "cancelled"
      last["ended_at"] = "2026-11-10T12:00:00Z"
    end
    Workspace::WorkflowRun.from_h(hash)
  end

  def finish_round(run:, round:)
    @calls << [:finish_round, Workspace::WorkflowRun.from_h(run).id, round["round"]]
    {"round" => round["round"], "pane" => round["pane"], "started_at" => round["started_at"], "ended_at" => round["ended_at"] || "2026-11-10T12:00:00Z",
     "session" => nil, "agent" => nil, "usage" => @round_usage}.tap do |record|
      next unless round["reviews"].is_a?(Array)
      record["reviews"] = round["reviews"].map { |row| row.merge("isolation" => "review_pane") }
      record["evidence"] = @round_evidence
    end
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

  def writeup(path)
    @calls << [:writeup, path]
    "the write-up at #{path}"
  end
end

# Fake of Workspace::WorkflowProgress for the evaluation and decision phases: +pass_step+ and +fail_step+ mark the
# current step passed or failed, +decide_review+ marks it with the tally's outcome, +advance+ answers the run as given, +finish+ sets the run's end state,
# +restart_review+ marks the step's round restarted, +end_round+ takes the step's round off (registering the window to
# close on +ctx+ when +close+), +start_retry+ moves the run to the wait's step, +hold_retry+ marks the wait blocked with the problem's message as
# the reason, and +retry_pane_problem+ answers the problem it was given. Each records its call; +finished+ keeps
# each run +finish+ was given, as a WorkflowRun.
class RecordingProgress
  CONTROL_METHODS = %i[calls finished].freeze

  attr_reader :calls, :finished

  # @param pane_problem [Hash{Symbol=>String}, nil] what +retry_pane_problem+ answers
  # @param review [Hash, nil] the review round +pass_step+ registers on its context
  def initialize(pane_problem: nil, review: nil)
    @pane_problem = pane_problem
    @review = review
    @calls = []
    @finished = []
  end

  def pass_step(run, ctx:)
    @calls << [:pass_step, Workspace::WorkflowRun.from_h(run).current]
    ctx.review(@review) if @review
    marked(run, "passed")
  end

  # Marks the last attempt `overridden` and the step passed, as the real one does before its gate or next step.
  def pass_overridden(run, ctx:)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    @calls << [:pass_overridden, hash["current"]]
    hash["steps"][hash["current"]]["attempts"].last["outcome"] = "overridden"
    marked(hash.merge("reason" => nil), "passed")
  end

  def fail_step(run, failure, ctx:)
    @calls << [:fail_step, Workspace::WorkflowRun.from_h(run).current, failure]
    marked(run, "failed")
  end

  def decide_review(run, tally, ctx:)
    @calls << [:decide_review, Workspace::WorkflowRun.from_h(run).current, tally]
    marked(run, {approved: "passed", rejected: "failed"}.fetch(tally[:outcome], "reviewing"))
  end

  def advance(run, ctx:)
    @calls << [:advance, Workspace::WorkflowRun.from_h(run).current]
    Workspace::WorkflowRun.from_h(run)
  end

  def restart_review(run, ctx:)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    @calls << [:restart_review, hash["current"]]
    ctx.review({"step" => hash["current"]})
    hash["steps"][hash["current"]]["review"] = {"restarted" => true}
    Workspace::WorkflowRun.from_h(hash.merge("reason" => nil))
  end

  # Registers the round on +ctx+ and counts one more of its `redeliveries`, as the real one does.
  def redeliver_round(run, ctx:, new_server: false)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    @calls << (new_server ? [:redeliver_round, hash["current"], {new_server: true}] : [:redeliver_round, hash["current"]])
    round = hash["steps"][hash["current"]]["review"]
    round.reject! { |key, _| %w[pane window server_pid].include?(key) } if new_server
    round.merge!("delivery" => "delivering", "redeliveries" => round["redeliveries"].to_i + 1).delete("failure")
    ctx.review({"step" => hash["current"], "round" => round["round"]})
    Workspace::WorkflowRun.from_h(hash)
  end

  def end_round(run, how:, ctx:, close: true)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    @calls << [:end_round, hash["current"], {how: how, close: close}]
    round = hash["steps"][hash["current"]].delete("review")
    ctx.close_review({"step" => hash["current"], "round" => round&.fetch("round", nil)}) if close
    Workspace::WorkflowRun.from_h(hash)
  end

  def finish(run, state, ctx: nil)
    @finished << Workspace::WorkflowRun.from_h(run)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    @calls << [:finish, hash["id"], state]
    Workspace::WorkflowRun.from_h(hash.merge("state" => state))
  end

  def start_retry(run, waiting = nil, ctx:, proven: false, budgeted: true)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    waiting ||= hash.delete("backoff")
    @calls << [:start_retry, hash["current"], waiting, {proven: proven, budgeted: budgeted}]
    Workspace::WorkflowRun.from_h(hash.merge("current" => waiting["to"], "reason" => nil))
  end

  def hold_retry(run, waiting, problem, pane: nil)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    @calls << [:hold_retry, hash["current"], problem, {pane: pane}]
    Workspace::WorkflowRun.from_h(hash.merge("backoff" => waiting.merge("blocked" => problem[:code]),
      "reason" => {"code" => "waiting_you", "details" => {"message" => "#{problem[:message]}."}}))
  end

  def retry_pane_problem(run, waiting, proven: false, pane: nil)
    @calls << [:retry_pane_problem, Workspace::WorkflowRun.from_h(run).current, {proven: proven, pane: pane}]
    @pane_problem
  end

  private

  def marked(run, state)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    hash["steps"][hash["current"]]["state"] = state
    Workspace::WorkflowRun.from_h(hash)
  end
end

# Fake of Workspace::WorkflowReviewTally#call, #open_round and #ensure_round: answers the outcome it was given and records the step
# and round it was asked about; +open_round+ answers +opened+ (nil: the directory was made), +ensure_round+ +ensured+.
class RecordingReviewTally
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param outcome [Symbol] :approved, :rejected or :incomplete
  # @param reviews [Array<Hash>] the review rows it answers
  # @param problem [String, nil] why an incomplete round is incomplete
  # @param opened [Hash, nil] what +open_round+ answers (:code and :problem when the directory could not be made for the round)
  # @param ensured [Hash, nil] what +ensure_round+ answers (nil: the directory is there)
  # @param on_ensure [#call, nil] called before +ensure_round+ answers, as when another process acts meanwhile
  def initialize(outcome: :approved, reviews: [], problem: nil, opened: nil, ensured: nil, on_ensure: nil)
    @on_ensure = on_ensure
    @answer = {outcome: outcome, reviews: reviews, problem: problem}.compact
    @opened = opened
    @ensured = ensured
    @calls = []
  end

  def open_round(run:, round:)
    @calls << [:open_round, Workspace::WorkflowRun.from_h(run).id, round]
    @opened
  end

  def ensure_round(run:, round:)
    @calls << [:ensure_round, Workspace::WorkflowRun.from_h(run).id, round]
    @on_ensure&.call
    @ensured
  end

  def call(run:, step:, round:)
    @calls << [:call, Workspace::WorkflowRun.from_h(run).id, step["id"], round]
    @answer
  end
end

# Fake of Workspace::WorkflowReviewRevision#call: answers each scripted answer in turn (the last again once they run out),
# after asking +stop_when+ once (kept in +stop_answers+), and records the step it was asked about.
class RecordingReviewRevision
  CONTROL_METHODS = %i[calls stop_answers].freeze

  attr_reader :calls, :stop_answers

  # @param answers [Array<Hash>] what each +call+ answers (`revision:` and `problem:`)
  def initialize(*answers)
    @answers = answers.empty? ? [{revision: "rev1", problem: nil}] : answers
    @calls = []
    @stop_answers = []
  end

  def call(run:, step:, stop_when: nil)
    @calls << [:call, Workspace::WorkflowRun.from_h(run).id, step["id"]]
    @stop_answers << stop_when&.call
    (@answers.size > 1) ? @answers.shift : @answers.first
  end
end

# Fake of Workspace::WorkflowReviewSummary: answers the summary it was given for each +write+, and records each
# +write+ and +notify+ with the run's reason code as it was when notified.
class RecordingReviewSummary
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param written [Hash{String=>String}] what each +write+ answers ("path" and "sha256", or "problem")
  def initialize(written = {"path" => "/runs/wr_1/reviews/plan.1.r1/summary.md", "sha256" => "s" * 64})
    @written = written
    @calls = []
  end

  def write(run, round:, outcome:, decided:, reviews:, problem: nil)
    @calls << [:write, run["current"], {round: round, outcome: outcome, decided: decided, reviews: reviews, problem: problem}]
    @written
  end

  def notify(run, step:, attempt:, round:, outcome:, summary:)
    @calls << [:notify, step, {attempt: attempt, round: round, outcome: outcome, summary: summary, reason: run.dig("reason", "code")}]
    "created"
  end
end

# Fake of Workspace::WorkflowRoundRerun#check_revision: records each round it is asked about and answers what it was
# given (`{}` delivers the round as registered, `{revision:}` with that revision, `{run:}` stops it).
class RecordingRoundRerun
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param answer [Hash{Symbol=>Object}] what each +check_revision+ answers
  def initialize(answer = {})
    @answer = answer
    @calls = []
  end

  def check_revision(run_id, review)
    @calls << [:check_revision, run_id, review]
    @answer
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

  def call(cwd:, timeout:, log:, command: nil, argv: nil, stop_when: nil, env: {}, err_log: nil)
    @calls << [:call, {command: command, cwd: cwd, timeout: timeout, log: log, env: env}.merge(err_log ? {err_log: err_log} : {})]
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

# Fake of Workspace::WorkflowGuard#check, #config_change, #head, #tree_digest, #round_snapshot and #round_check: answers what it was given
# (+head+ and +tree_digest+ answer the current value of +heads+ and +trees+, which a spec may change).
class RecordingGuard
  CONTROL_METHODS = %i[calls heads trees].freeze

  attr_reader :calls, :heads, :trees

  # @param found [Hash, nil] what +check+ answers
  # @param config [Hash, nil] what +config_change+ answers
  # @param head [String, nil] what +head+ answers
  # @param tree [String, nil] what +tree_digest+ answers
  # @param unread [Array<String>] the parts +base+ could not read ("head", "hooks_sha256", "hidden_sha256")
  # @param round_found [Hash, nil] what +round_check+ answers
  def initialize(found: nil, config: nil, head: "a" * 40, tree: "t" * 64, unread: [], round_found: nil)
    @found = found
    @round_found = round_found
    @unread = unread
    @config = config
    @heads = [head]
    @trees = [tree]
    @calls = []
  end

  def head(worktree)
    @calls << [:head, worktree]
    @heads.last
  end

  def tree_digest(worktree, base: nil)
    @calls << [:tree_digest, worktree]
    @trees.last
  end

  def check(worktree, base, scope)
    @calls << [:check, worktree, scope]
    @found
  end

  def round_snapshot(worktree, base: nil)
    @calls << [:round_snapshot, worktree]
    {"head" => @heads.last, "tree_sha256" => @trees.last}
  end

  def round_check(worktree, snapshot, base: nil)
    @calls << [:round_check, worktree, snapshot]
    @round_found
  end

  # The last of +heads+ as the base commit, with a fixed snapshot (+unread+ names the parts given as unreadable, as
  # nil); with +accept_tree+, the last of +trees+ as `accepted_tree_sha256`, listed as unread when nil (neither on an unborn branch, +head+ nil).
  def base(worktree, accept_tree: false)
    @calls << [:base, worktree, {accept_tree: accept_tree}]
    guard = {"config_sha256" => "c", "hooks_sha256" => "h", "hidden_sha256" => "x"}
    @unread.each { |key| guard[key] = nil if guard.key?(key) }
    unborn = @heads.last.nil? && !@unread.include?("head")
    guard["accepted_tree_sha256"] = @trees.last if accept_tree && @trees.last && !unborn
    unread = @unread.dup
    unread << "accepted_tree_sha256" if accept_tree && !@trees.last && !unborn
    {"base_sha" => @unread.include?("head") ? nil : @heads.last, "base_guard" => guard, "unread" => unread}
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
    Workspace::InboxStore::Upsert.new(record, "created")
  end
end

# Fake of Workspace::WorkflowEvaluation#evaluate, #review_ended, #finish_check and #finish_follow_ups for the decision and recovery
# phases: +evaluate+ registers the check it was given on +ctx+ and answers the run as given (with the reason it was given, when one
# was); +review_ended+ registers the round's end on +ctx+ and answers the run as given; +finish_check+ answers the stored run;
# +finish_follow_ups+ runs the check registered on a context through +finish_check+ and keeps a registered window close, round
# end and review in the calls as +:close_review+, +:review_end+ and +:review_round+.
class RecordingEvaluation
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param runs [Hash{String=>Hash}] the stored runs by id
  # @param check [Hash, nil] what +evaluate+ registers on its context
  # @param reason [Hash, nil] the reason +evaluate+ leaves on the run
  # @param review [Hash, nil] the review round +evaluate+ registers on its context
  def initialize(runs, check: nil, reason: nil, review: nil)
    @runs = runs
    @check = check
    @review = review
    @reason = reason
    @calls = []
  end

  def evaluate(run, ctx:, turn_started: nil, background: [])
    run = Workspace::WorkflowRun.from_h(run)
    @calls << [:evaluate, run.current]
    ctx.check(@check) if @check
    ctx.review(@review) if @review
    @reason ? Workspace::WorkflowRun.from_h(run.thawed.merge("reason" => @reason)) : run
  end

  # Marks the last attempt `guard_accepted`, then answers as +evaluate+ does.
  def evaluate_accepted(run, ctx:)
    hash = Workspace::WorkflowRun.from_h(run).thawed
    @calls << [:evaluate_accepted, hash["current"]]
    hash["steps"][hash["current"]]["attempts"].last["guard_accepted"] = hash.dig("reason", "details", "guard")
    ctx.check(@check) if @check
    ctx.review(@review) if @review
    Workspace::WorkflowRun.from_h(hash.merge("reason" => @reason))
  end

  def review_ended(run, ctx:)
    run = Workspace::WorkflowRun.from_h(run)
    @calls << [:review_ended, run.current]
    ctx.review_end({"step" => run.current})
    run
  end

  def finish_check(run_id, check)
    @calls << [:finish_check, run_id, check]
    Workspace::WorkflowRun.from_h(@runs.fetch(run_id))
  end

  def finish_follow_ups(run_id, ctx, run)
    return run unless ctx
    @calls << [:close_review, run_id, ctx.close_review] if ctx.close_review
    run = finish_check(run_id, ctx.check) if ctx.check
    @calls << [:review_end, run_id, ctx.review_end] if ctx.review_end
    @calls << [:review_round, run_id, ctx.review] if ctx.review
    run
  end
end

# Fake of Workspace::WorkflowGateNote#find and #missing: the note it was given, and the error the real one builds
# for a gate that names none.
class RecordingGateNote
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param found [Hash, nil] what +find+ answers ("name", "path", "sha256")
  def initialize(found: nil)
    @found = found
    @calls = []
  end

  def find(run, step_id = nil)
    @calls << [:find, Workspace::WorkflowRun.from_h(run).id]
    @found
  end

  def missing(run, step_id = nil)
    Workspace::Error.new("The gate names no note.", code: "gate_note_unreadable", details: {"run_id" => Workspace::WorkflowRun.from_h(run).id})
  end
end
