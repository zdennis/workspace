require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::CLI::Pipeline do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-pipeline-family") }
  let(:running) { false }
  let(:config) do
    instance_double(Workspace::Config, agent_running?: running).tap do |c|
      allow(c).to receive(:pipeline_state_path) { |name| File.join(tmpdir, "#{name}-pipeline.json") }
    end
  end
  let(:agent_client) { double("agent client", call: {"ok" => true}) }
  let(:now) { Time.utc(2026, 9, 27, 12, 0, 0) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def family
    names = Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: RecordingProjectDetector.new,
      lineage: CLITestHelpers::FakeLineage.new, working_dir: "/src/app")
    described_class.new(config: config, agent_client: agent_client, common: Workspace::CLI::Common.new, names: names, clock: -> { now })
  end

  def invocation
    @invocation ||= Workspace::CLI::Invocation.new(output: Workspace::OutputGate.new(out), error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
  end

  def run(*args)
    family.call("pipeline", args, invocation)
    nil
  rescue FakeSystemExit => e
    e.status
  end

  def write_state(entries)
    File.write(config.pipeline_state_path("app"), JSON.generate(entries))
  end

  describe "#call" do
    it "prints the state's entries through the invocation, with the deprecation warning on its error output" do
      write_state("WC-1" => {"work_item_ref" => "WC-1", "pane_index" => 1, "phase" => "implementer", "deadline_at" => (now + 600).iso8601(3)})

      run("status", "app")

      expect(out.string).to include("WORK ITEM  PANE  STAGE  DEADLINE\n", "WC-1  pane 1  implementer  ", "(in 10m)")
      expect(err.string).to eq("Warning: #{described_class::DEPRECATION}\n")
    end

    it "sends start's command message through the agent client" do
      run("start", "app", "--work-item", "WC-1", "--body", "go")

      expect(agent_client).to have_received(:call).with("app", hash_including("type" => "command", "workspace" => "app",
        "work_item_ref" => "WC-1", "body" => "go"))
      expect(out.string).to eq("Sent WC-1 into app's pipeline\n")
    end

    it "sends advance's inject message with the token from the state file" do
      write_state("WC-1" => {"work_item_ref" => "WC-1", "sentinel_token" => "a1b2c3d4"})

      run("advance", "app", "--work-item", "WC-1")

      expect(agent_client).to have_received(:call).with("app", hash_including("type" => "inject", "expected_token" => "a1b2c3d4",
        "interrupt" => true))
    end

    it "clears the state file with reset, and puts the deprecation in the --json document's warnings" do
      write_state("WC-1" => {"work_item_ref" => "WC-1"})

      run("reset", "app", "--json")

      expect(File.exist?(config.pipeline_state_path("app"))).to be false
      expect(JSON.parse(out.string)).to include("action" => "pipeline reset", "warnings" => [described_class::DEPRECATION])
      expect(err.string).to eq("Cleared pipeline state for app\n")
    end

    context "while the agent runs" do
      let(:running) { true }

      it "refuses reset and keeps the state file" do
        write_state("WC-1" => {"work_item_ref" => "WC-1"})

        expect { run("reset", "app") }.to raise_error(Workspace::Error, /before resetting its pipeline state/)
        expect(File.exist?(config.pipeline_state_path("app"))).to be true
      end
    end

    it "prints its help with no subcommand and raises a usage error for the CLI's rescue funnel to report" do
      expect(run).to be_nil
      expect(out.string).to start_with("Usage: workspace pipeline start PROJECT")
      expect { run("nonsense") }.to raise_error(Workspace::UsageError, /Usage: workspace pipeline start PROJECT/)
      expect { run("status") }.to raise_error(Workspace::UsageError, /Usage: workspace pipeline status/)
      expect(agent_client).not_to have_received(:call)
    end
  end
end
