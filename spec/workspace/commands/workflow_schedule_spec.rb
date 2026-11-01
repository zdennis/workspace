require "spec_helper"

RSpec.describe Workspace::Commands::Workflow, "#schedule" do
  let(:output) { StringIO.new }
  let(:schedule) { instance_double(Workspace::SweepSchedule) }

  def build(schedule)
    described_class.new(catalog: nil, engine: nil, status: nil, store: nil, panes: nil, files: nil, run_files: nil, tmux: nil,
      process_tree: nil, lock_holder: nil, schedule: schedule, output: output)
  end

  it "refuses when no schedule was wired" do
    expect { build(nil).schedule(:install) }.to raise_error(Workspace::Error, /no schedule was wired/)
  end

  it "dispatches each action and maps dry_run to the status" do
    allow(schedule).to receive_messages(install: {"outcome" => "dry_run", "message" => "Would load."}, uninstall: {"outcome" => "removed", "message" => "gone"}, status: {"outcome" => "installed", "message" => "ok"})
    command = build(schedule)
    expect(command.schedule(:install, dry_run: true)).to include(exit_code: 0, status: "dry_run")
    expect(schedule).to have_received(:install).with(dry_run: true)
    expect(command.schedule(:uninstall)).to include(status: nil)
    expect(command.schedule(:status)[:results]).to eq([{"outcome" => "installed", "message" => "ok"}])
    expect(output.string).to include("Would load.", "gone")
  end
end
