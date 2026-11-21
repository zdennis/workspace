require_relative "../demo_calculator/config"

module DemoCalculator2
  GOALS = %w[01-add-sub 02-mul-div 03-div-zero 04-precedence 05-mod-pow 06-json 07-repl].freeze
  DEMO_DIR = "demo/calculator2".freeze
  ACCEPTANCE_REF = "refs/demo-calc2/acceptance-base".freeze
  ACCEPTANCE_RUNNER = "script/demo_calculator2/acceptance_runner".freeze
  WORKFLOW_ID = "deliver-goal".freeze

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

  # @return [Array<String>] the argv of `work-queue add` for one goal
  def self.queue_argv(goal, name_args)
    path = "#{DEMO_DIR}/goals/#{goal}.md"
    ["work-queue", "add", "workflow", WORKFLOW_ID, "--prompt", "Deliver the goal in #{path}", "--input", "goal=#{path}",
      "--input", "acceptance=#{ACCEPTANCE_RUNNER}", "--dedupe-key", "calculator2-demo:#{goal}", "--json", *name_args]
  end

  # @param stub_ref [String] the git ref that holds the stub `reset` and `run` restore
  # @param goals [Array<String>] the goals to queue, each one of GOALS, in order
  # @return [DemoCalculator::Config] the calculator2 demo: one `deliver-goal` item per goal
  def self.config(stub_ref: "main", goals: GOALS)
    DemoCalculator::Config.new(demo_dir: DEMO_DIR, workflows_dir: "#{DEMO_DIR}/workflows", definition_ids: [WORKFLOW_ID],
      queue_items: ->(name_args) { goals.map { |goal| [WORKFLOW_ID, queue_argv(goal, name_args)] } },
      restored: %w[bin lib test], template_dir: nil, stub_ref: stub_ref,
      acceptance_dir: "#{DEMO_DIR}/acceptance", readme_path: "#{DEMO_DIR}/README.md", runs_dir: "tmp/demo-calculator2/runs",
      test_command: "ruby #{DEMO_DIR}/test/calc_test.rb", lint_command: "bundle exec standardrb #{DEMO_DIR}",
      acceptance_ref: ACCEPTANCE_REF, program: "demo-calculator2", record_extras: {"stub_ref" => stub_ref, "goals" => goals})
  end
end
