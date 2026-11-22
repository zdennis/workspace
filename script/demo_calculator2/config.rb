require_relative "../demo_calculator/config"
require_relative "dag"

module DemoCalculator2
  GOALS = %w[01-add-sub 02-mul-div 03-div-zero 04-precedence 05-mod-pow 06-json 07-repl].freeze
  DEMO_DIR = "demo/calculator2".freeze
  ACCEPTANCE_REF = "refs/demo-calc2/acceptance-base".freeze
  ACCEPTANCE_RUNNER = "script/demo_calculator2/acceptance_runner".freeze
  LANES_ACCEPTANCE_RUNNER = "script/demo_calculator2/acceptance_runner_lanes".freeze
  WORKFLOW_ID = "deliver-goal".freeze
  INTEGRATE_WORKFLOW_ID = "integrate-branch".freeze
  DEFINITION_IDS = [WORKFLOW_ID, "deliver-goal-fast", INTEGRATE_WORKFLOW_ID].freeze
  # The workflows a goal's item may run as; integrate-branch is the lanes' merge repair, never a goal's.
  GOAL_WORKFLOW_IDS = DEFINITION_IDS - [INTEGRATE_WORKFLOW_ID]
  # Lane A runs 01-05 and lane B 06 and 07, forked from lane A's head after goal 03 (`fork_after`).
  LANES = {a: %w[01-add-sub 02-mul-div 03-div-zero 04-precedence 05-mod-pow].freeze, b: %w[06-json 07-repl].freeze, fork_after: "03-div-zero"}.freeze
  # Lane B's prompt names the goals "earlier" means, since its branch holds only 01-03. The goal documents are unchanged.
  LANE_B_PROMPT = "Earlier goals here means 01, 02 and 03. This branch holds only their work; do not read or build goals 04 or 05.".freeze

  # @param spec [String] comma-separated goal numbers or names, such as `01,03`
  # @return [Array<String>] those goals in GOALS order
  # @raise [DemoCalculator::Refused] when one matches no goal
  def self.pick_goals(spec)
    picked = spec.split(",").map(&:strip).reject(&:empty?).map do |token|
      GOALS.find { |goal| goal == token || goal.start_with?("#{token}-") } || raise(DemoCalculator::Refused, "no goal #{token}: use #{GOALS.join(", ")}")
    end
    raise DemoCalculator::Refused, "--goals names no goal" if picked.empty?
    repeated = picked.tally.select { |_, count| count > 1 }.keys
    raise DemoCalculator::Refused, "--goals names #{repeated.join(", ")} more than once" unless repeated.empty?
    GOALS & picked
  end

  # @return [Array<Array<String>>] the argv of `work-queue add` for one goal
  def self.queue_argv(goal, name_args, workflow_id: WORKFLOW_ID, acceptance: ACCEPTANCE_RUNNER, prompt: nil)
    path = "#{DEMO_DIR}/goals/#{goal}.md"
    text = ["Deliver the goal in #{path}", prompt].compact.join(". ")
    ["work-queue", "add", "workflow", workflow_id, "--prompt", text, "--input", "goal=#{path}",
      "--input", "acceptance=#{acceptance}", "--dedupe-key", "calculator2-demo:#{goal}", "--json", *name_args]
  end

  # @param branch [String] the branch to merge, lane B's
  # @return [Array<String>] the argv of `work-queue add` for the integrate-branch run in lane A: the plain acceptance
  #   runner on 07-repl, so groups 1..7 run
  def self.integrate_argv(branch, name_args)
    ["work-queue", "add", "workflow", INTEGRATE_WORKFLOW_ID, "--prompt", "Merge #{branch} into this branch and make the tests, lint and acceptance pass.",
      "--input", "branch=#{branch}", "--input", "goal=#{DEMO_DIR}/goals/07-repl.md", "--input", "acceptance=#{ACCEPTANCE_RUNNER}",
      "--dedupe-key", "calculator2-demo:integrate", "--json", *name_args]
  end

  # @param goals [Array<String>] the goals queued as per-item runs under the lanes' runner
  # @return [Hash{String => Array<Integer>}] goal => the groups its own acceptance check runs (see DAG)
  def self.group_coverage(goals)
    goals.to_h { |goal| [goal, DAG.fetch(goal[/\A0(\d)/, 1].to_i)] }
  end

  # The dry-run check on group coverage: which groups no per-item check runs, so only the plain 07 run after the merge covers them.
  #
  # @param goals [Array<String>]
  # @return [Hash] `covered` (groups some item runs) and `integration_only` (the rest of 1..7)
  def self.coverage_check(goals)
    covered = group_coverage(goals).values.flatten.uniq.sort
    {covered: covered, integration_only: (1..7).to_a - covered}
  end

  # @param stub_ref [String] the git ref that holds the stub `reset` and `run` restore
  # @param goals [Array<String>] the goals to queue, each one of GOALS, in order
  # @param workflow_id [String] the workflow each item runs
  # @param acceptance [String] the acceptance program each item's `acceptance` input names
  # @param prompt [String, nil] a sentence added to each item's prompt
  # @param extras [Hash] more keys for run.json
  # @return [DemoCalculator::Config] the calculator2 demo: one item per goal
  def self.config(stub_ref: "main", goals: GOALS, workflow_id: WORKFLOW_ID, acceptance: ACCEPTANCE_RUNNER, prompt: nil, extras: {})
    DemoCalculator::Config.new(demo_dir: DEMO_DIR, workflows_dir: "#{DEMO_DIR}/workflows", definition_ids: DEFINITION_IDS,
      queue_items: ->(name_args) { goals.map { |goal| [workflow_id, queue_argv(goal, name_args, workflow_id: workflow_id, acceptance: acceptance, prompt: prompt)] } },
      restored: %w[bin lib test], template_dir: nil, stub_ref: stub_ref,
      acceptance_dir: "#{DEMO_DIR}/acceptance", readme_path: "#{DEMO_DIR}/README.md", runs_dir: "tmp/demo-calculator2/runs",
      test_command: "ruby #{DEMO_DIR}/test/calc_test.rb", lint_command: "bundle exec standardrb #{DEMO_DIR}",
      acceptance_ref: ACCEPTANCE_REF, program: "demo-calculator2", record_extras: {"stub_ref" => stub_ref, "goals" => goals}.merge(extras))
  end

  # @param lane [Symbol] :a or :b
  # @param goals [Array<String>] the goals of the run (GOALS order); the lane takes its own
  # @return [Array<String>] the lane's goals within them
  def self.lane_goals(lane, goals = GOALS)
    LANES.fetch(lane) & goals
  end

  # @return [DemoCalculator::Config] one lane's config: its goals under the lanes' acceptance runner, and lane B's prompt
  def self.lane_config(lane, workflow_id:, stub_ref: "main", goals: GOALS, extras: {})
    config(stub_ref: stub_ref, goals: lane_goals(lane, goals), workflow_id: workflow_id, acceptance: LANES_ACCEPTANCE_RUNNER,
      prompt: (lane == :b) ? LANE_B_PROMPT : nil, extras: extras)
  end

  # The goal lane A finishes before lane B forks: the last of lane A's goals in the run that does not come after the fork point.
  #
  # @param goals [Array<String>] the goals of the run
  # @return [String, nil] nil when lane A has none before the fork
  def self.fork_goal(goals = GOALS)
    index = GOALS.index(LANES.fetch(:fork_after))
    lane_goals(:a, goals).reverse.find { |goal| GOALS.index(goal) <= index }
  end
end
