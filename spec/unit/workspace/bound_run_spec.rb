require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::BoundRun do
  let(:tmpdir) { Dir.mktmpdir("ws-bound-run") }
  let(:bindings) { Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json"), error_output: StringIO.new) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:env) { {"TMUX_PANE" => "%4"} }

  subject(:bound_run) { described_class.new(pane_bindings: bindings, tmux: tmux, env: env) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(tmux).to receive(:session_name_for_pane).with("%4").and_return("app")
    allow(tmux).to receive(:pane_slot).with("%4").and_return("app:0.1")
  end

  def bind(pane, fields = {})
    bindings.bind(pane, {"kind" => "run", "id" => "wr_1", "session" => "app", "pane_slot" => "app:0.1"}.merge(fields))
  end

  it "names the run the calling pane is bound to" do
    bind("%4")

    expect(bound_run.run_id).to eq("wr_1")
  end

  it "is nil for a pane with no binding" do
    bind("%5")

    expect(bound_run.run_id).to be_nil
  end

  it "is nil for a pane bound to a review or a play" do
    bind("%4", "kind" => "review")

    expect(bound_run.run_id).to be_nil
  end

  it "is nil for a pane bound to a reflection" do
    bind("%4", "kind" => "reflection")

    expect(bound_run.run_id).to be_nil
  end

  it "is nil outside tmux, without asking tmux" do
    bind("%4")

    expect(described_class.new(pane_bindings: bindings, tmux: tmux, env: {}).run_id).to be_nil
    expect(described_class.new(pane_bindings: bindings, tmux: tmux, env: {"TMUX_PANE" => ""}).run_id).to be_nil
    expect(tmux).not_to have_received(:session_name_for_pane)
  end

  it "is nil for a binding made for another tmux session" do
    bind("%4", "session" => "other")

    expect(bound_run.run_id).to be_nil
  end

  it "is nil for a binding made for another pane slot, as after a tmux restart reuses the pane id" do
    bind("%4", "pane_slot" => "app:0.2")

    expect(bound_run.run_id).to be_nil
  end

  it "is nil for a binding parked under its slot, which is not a pane id" do
    File.write(File.join(tmpdir, "bindings.json"),
      JSON.generate("slot:app:0.1" => {"kind" => "run", "id" => "wr_1", "session" => "app", "pane_slot" => "app:0.1"}))

    expect(bound_run.run_id).to be_nil
  end

  it "is nil when tmux can't be asked" do
    bind("%4")
    allow(tmux).to receive(:session_name_for_pane).and_raise(Errno::ENOENT, "tmux")

    expect(bound_run.run_id).to be_nil
  end

  it "is nil for a pane tmux no longer knows" do
    bind("%4")
    allow(tmux).to receive(:session_name_for_pane).with("%4").and_return(nil)
    allow(tmux).to receive(:pane_slot).with("%4").and_return(nil)

    expect(bound_run.run_id).to be_nil
  end

  describe "a review pane" do
    before { bind("%4", "role" => "reviewer", "round" => 1, "pane_slot" => "app:3.0") }

    it "is the run's for the deny tripwire, whatever the window index now is" do
      expect(bound_run.run_id).to eq("wr_1")
    end

    it "is nil once tmux restarted and a new server reused the pane id" do
      bind("%4", "role" => "reviewer", "round" => 1, "pane_slot" => "app:3.0", "server_pid" => "4242")
      allow(tmux).to receive(:server_pid_for_pane).with("%4").and_return("9999")
      expect(bound_run.run_id).to be_nil

      allow(tmux).to receive(:server_pid_for_pane).with("%4").and_return("4242")
      expect(bound_run.run_id).to eq("wr_1")
    end

    it "is not the author's run, for dev up, lock acquire and promote" do
      expect(bound_run.author_run_id).to be_nil
    end
  end

  it "names the author's run through author_run_id, and nothing for an unbound pane" do
    bind("%4")

    expect(bound_run.author_run_id).to eq("wr_1")
    expect(described_class.new(pane_bindings: bindings, tmux: tmux, env: {}).author_run_id).to be_nil
  end
end
