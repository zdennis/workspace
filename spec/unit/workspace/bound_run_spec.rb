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
end
