require "spec_helper"
require "tmpdir"

RSpec.describe "workspace workflow sweep --install through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-sweep-install") do |dir|
      saved = ENV.to_h
      begin
        ENV.replace("HOME" => File.realpath(dir), "PATH" => File.dirname(RbConfig.ruby))
        example.run
      ensure
        ENV.replace(saved)
      end
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:calls) { [] }
  let(:plist) { File.join(ENV.fetch("HOME"), "Library", "LaunchAgents", "com.workspace.workflow-sweep.plist") }
  # Every launchctl call lands here; a real one cannot be reached from these specs.
  let(:launchctl) do
    lambda do |args|
      calls << args
      (args.first == "print") ? ["Could not find service", 1] : ["", 0]
    end
  end
  let(:cli) do
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}, launchctl: launchctl, exit_handler: FakeExitHandler)
  end

  before do
    # The specs may run from a linked worktree, which the real source refuses.
    allow_any_instance_of(Workspace::SkillSource).to receive(:executable).and_return(File.join(ENV.fetch("HOME"), "bin", "workspace")) # standard:disable RSpec/AnyInstance
  end

  def document
    JSON.parse(out.string)
  end

  it "reports status under a temp HOME" do
    cli.run(["workflow", "sweep", "--installed", "--json"])
    expect(document).to include("action" => "workflow sweep --installed", "status" => "ok")
    expect(document["results"].first).to include("installed" => false)
    expect(calls.map(&:first)).to eq(["print"])
  end

  it "installs and uninstalls through the injected launchctl, text and --json" do
    cli.run(["workflow", "sweep", "--install", "--json"])
    expect(document).to include("action" => "workflow sweep --install")
    expect(document["results"].first).to include("outcome" => "installed")
    expect(File.exist?(plist)).to be(true)
    expect(calls.map(&:first)).to include("bootstrap")
    out.truncate(0)
    out.rewind
    cli.run(["workflow", "sweep", "--uninstall"])
    expect(out.string).to include("removed")
    expect(File.exist?(plist)).to be(false)
  end

  it "maps --dry-run to status dry_run and changes nothing" do
    cli.run(["workflow", "sweep", "--install", "--dry-run", "--json"])
    expect(document).to include("status" => "dry_run")
    expect(File.exist?(plist)).to be(false)
    expect(calls.map(&:first)).to eq(["print"])
  end

  it "refuses a RUN, --name, two flags and --dry-run with --installed" do
    [%w[RUN --install], %w[--name app --install], %w[--install --uninstall], %w[--installed --dry-run]].each do |args|
      expect { cli.run(["workflow", "sweep", *args]) }.to raise_error(FakeSystemExit)
    end
    expect(calls).to be_empty
  end

  it "refuses the flags on another verb" do
    expect { cli.run(["workflow", "status", "--install"]) }.to raise_error(FakeSystemExit)
    expect(calls).to be_empty
  end
end
