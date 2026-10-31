require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::PlanPaused do
  let(:dir) { Dir.mktmpdir }
  let(:resolver) { ->(_workspace) { dir } }

  after { FileUtils.remove_entry(dir) }

  def check(resolver = self.resolver) = described_class.new(workspace: "myapp", dir_resolver: resolver).call

  def write_plan(status)
    File.write(File.join(dir, "IMPLEMENTATION_PLAN.md"), "---\nplan: 1\nstatus: #{status}\n---\n\n## Tasks\n\n- [ ] T1 One\n")
  end

  it "is true for a paused plan" do
    write_plan("paused")
    expect(check).to be(true)
  end

  it "is false for an active plan" do
    write_plan("active")
    expect(check).to be(false)
  end

  it "is false with no plan file" do
    expect(check).to be(false)
  end

  it "is false when the notes directory can't be resolved" do
    expect(check(->(_workspace) { raise Workspace::Error, "no notes" })).to be(false)
  end

  it "is false when the plan can't be read" do
    expect(check(->(_workspace) { raise Errno::EACCES })).to be(false)
  end

  it "reads the plan again on each call" do
    write_plan("active")
    watcher = described_class.new(workspace: "myapp", dir_resolver: resolver)
    expect { write_plan("paused") }.to change(watcher, :call).from(false).to(true)
  end
end
