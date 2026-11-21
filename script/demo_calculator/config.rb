module DemoCalculator
  WORKFLOW_IDS = %w[
    calc-01-add-sub calc-02-mul-div calc-03-div-zero calc-04-precedence
    calc-05-mod-pow calc-06-json calc-07-repl
  ].freeze
  # What `workspace config` sets as commands.test: runs the calculator tests.
  TEST_COMMAND = "ruby demo/calculator/test/calc_test.rb"
  # What `reset` puts back: the pristine copies in demo/calculator/template/.
  RESTORED = %w[bin lib test USAGE.md].freeze
  # Held back from a run branch, so the agents cannot read what scores them.
  ACCEPTANCE_DIR = "demo/calculator-acceptance"
  # Also held back: it explains where eval finds the acceptance tests.
  README_PATH = "demo/calculator/README.md"
  RUN_BRANCH_PREFIX = "calc-demo/"

  # Everything that differs between one calculator demo and another: where it lives, what it queues and how
  # its stub is put back. `Config.v1` is the original demo; `script/demo-calculator2` builds its own.
  #
  # @!attribute demo_dir [String] the demo's directory, relative to the checkout root
  # @!attribute workflows_dir [String] where its workflow definitions are, relative to the root
  # @!attribute definition_ids [Array<String>] the definitions whose hashes the run record keeps
  # @!attribute queue_items [#call] `call(name_args)` returns one `[workflow_id, argv]` per item to queue, in order
  # @!attribute restored [Array<String>] entries of demo_dir that `reset` puts back
  # @!attribute template_dir [String, nil] where reset copies them from (relative to demo_dir); nil restores from git at `stub_ref`
  # @!attribute stub_ref [String, nil] the git ref that holds the stub when template_dir is nil
  # @!attribute acceptance_dir [String] removed from the run branch's first commit
  # @!attribute readme_path [String] removed with it
  # @!attribute runs_dir [String] where `run` writes run records, relative to the root
  # @!attribute test_command [String] workspace-scoped commands.test
  # @!attribute lint_command [String, nil] workspace-scoped commands.lint
  # @!attribute acceptance_ref [String, nil] a git ref `run` points at the main branch's sha, or nil
  # @!attribute program [String] the script's name in messages
  # @!attribute record_extras [Hash, nil] extra keys `run` writes into run.json, such as the options the run was given
  Config = Struct.new(:demo_dir, :workflows_dir, :definition_ids, :queue_items, :restored, :template_dir, :stub_ref,
    :acceptance_dir, :readme_path, :runs_dir, :test_command, :lint_command, :acceptance_ref, :program, :record_extras, keyword_init: true) do
    # @return [String] the path suffix that marks a stale `workflows.sources` entry of this demo
    def workflows_suffix = "/#{workflows_dir}"

    # @return [Config] the seven-workflow calculator demo
    def self.v1
      new(demo_dir: "demo/calculator", workflows_dir: "demo/calculator/workflows", definition_ids: WORKFLOW_IDS,
        queue_items: ->(name_args) {
          WORKFLOW_IDS.map { |id| [id, ["work-queue", "add", "workflow", id, "--dedupe-key", "calculator-demo:#{id}", "--json", *name_args]] }
        },
        restored: RESTORED, template_dir: "template", stub_ref: nil, acceptance_dir: ACCEPTANCE_DIR, readme_path: README_PATH,
        runs_dir: "tmp/demo-calculator/runs", test_command: TEST_COMMAND, lint_command: nil, acceptance_ref: nil,
        program: "demo-calculator")
    end
  end
end
