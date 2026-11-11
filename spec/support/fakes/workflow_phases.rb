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
  def initialize(runs)
    @runs = runs
    @calls = []
    @events = []
    @deliveries = []
  end

  def call(run_id, nonblocking: false)
    @calls << [:call, run_id, {nonblocking: nonblocking}]
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

# Fake of the Workspace::WorkflowRunStore calls a starter makes: +create+ runs the check, gives the next id and
# keeps the run in +runs+; +on_checkout+ answers the run Hash scripted for the path, as a WorkflowRun.
class RecordingRunStore
  CONTROL_METHODS = %i[calls runs].freeze

  attr_reader :calls, :runs

  # @param on_checkout [Hash{String=>Hash}] the run going on each checkout path
  # @param ids [Array<String>] the ids +create+ hands out, in order
  def initialize(on_checkout: {}, ids: %w[wr_1 wr_2])
    @on_checkout = on_checkout
    @ids = ids.dup
    @runs = {}
    @calls = []
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
