require_relative "../demo_calculator/config"

module DemoCalculator2
  GOALS = %w[01-add-sub 02-mul-div 03-div-zero 04-precedence 05-mod-pow 06-json 07-repl].freeze
  DEMO_DIR = "demo/calculator2".freeze
  ACCEPTANCE_REF = "refs/demo-calc2/acceptance-base".freeze
  ACCEPTANCE_RUNNER = "script/demo_calculator2/acceptance_runner".freeze
  WORKFLOW_ID = "deliver-goal".freeze

  # @return [Array<String>] the argv of `work-queue add` for one goal
  def self.queue_argv(goal, name_args)
    path = "#{DEMO_DIR}/goals/#{goal}.md"
    ["work-queue", "add", "workflow", WORKFLOW_ID, "--prompt", "Deliver the goal in #{path}", "--input", "goal=#{path}",
      "--input", "acceptance=#{ACCEPTANCE_RUNNER}", "--dedupe-key", "calculator2-demo:#{goal}", "--json", *name_args]
  end

  # @return [DemoCalculator::Config] the calculator2 demo: one `deliver-goal` item per goal
  def self.config
    DemoCalculator::Config.new(demo_dir: DEMO_DIR, workflows_dir: "#{DEMO_DIR}/workflows", definition_ids: [WORKFLOW_ID],
      queue_items: ->(name_args) { GOALS.map { |goal| [WORKFLOW_ID, queue_argv(goal, name_args)] } },
      restored: %w[bin lib test], template_dir: nil, stub_ref: "main",
      acceptance_dir: "#{DEMO_DIR}/acceptance", readme_path: "#{DEMO_DIR}/README.md", runs_dir: "tmp/demo-calculator2/runs",
      test_command: "ruby #{DEMO_DIR}/test/calc_test.rb", lint_command: "bundle exec standardrb #{DEMO_DIR}",
      acceptance_ref: ACCEPTANCE_REF, program: "demo-calculator2")
  end
end
