require "spec_helper"
require "tmpdir"
require "socket"

RSpec.describe Workspace::SessionWorkspace do
  let(:tmpdir) { Dir.mktmpdir }
  let(:tmux) { instance_double(Workspace::Tmux, session_option: nil) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: []) }
  let(:config) { instance_double(Workspace::Config) }
  let(:ambiguous) { [] }

  subject(:resolver) do
    described_class.new(tmux: tmux, project_config: project_config, config: config,
      on_ambiguous: ->(session, names) { ambiguous << [session, names] })
  end

  before { allow(config).to receive(:agent_socket_path) { |name| File.join(tmpdir, "#{name}.sock") } }

  after { FileUtils.remove_entry(tmpdir) }

  it "reads the workspace recorded on the session, without looking at the configs" do
    allow(tmux).to receive(:session_option).with("lab-wc-wt-lab-1", "@workspace").and_return("Lab-WC.worktree-lab-1")
    expect(project_config).not_to receive(:available_projects)

    workspace = resolver.call("lab-wc-wt-lab-1")

    expect(workspace).to eq("lab-wc.worktree-lab-1")
    expect(config.agent_socket_path(workspace)).not_to eq(config.agent_socket_path("lab-wc-wt-lab-1"))
  end

  context "with no option recorded (a session started before it)" do
    before do
      allow(project_config).to receive(:available_projects).and_return(%w[lab-wc lab-wc.worktree-lab-1])
      allow(tmux).to receive(:session_name_for) { |name| {"lab-wc" => "lab-wc", "lab-wc.worktree-lab-1" => "\"Lab-WC-wt-lab-1\""}.fetch(name) }
    end

    it "finds the config naming the session, unquoted and ignoring case" do
      expect(resolver.call("lab-wc-wt-lab-1")).to eq("lab-wc.worktree-lab-1")
    end

    it "keeps a plain workspace\x27s name" do
      expect(resolver.call("lab-wc")).to eq("lab-wc")
    end

    it "is nil for a session no config names" do
      expect(resolver.call("stray")).to be_nil
    end

    it "uses the first of several configs naming the session and says so" do
      allow(project_config).to receive(:available_projects).and_return(%w[a b])
      allow(tmux).to receive(:session_name_for).and_return("shared")

      expect(resolver.call("shared")).to eq("a")
      expect(ambiguous).to eq([["shared", %w[a b]]])
    end

    it "falls back to the session\x27s own name only when a daemon listens under it" do
      server = UNIXServer.new(config.agent_socket_path("stray"))

      expect(resolver.call("stray")).to eq("stray")
    ensure
      server&.close
    end
  end
end
