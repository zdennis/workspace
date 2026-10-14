require "spec_helper"
require "tmpdir"

# A status write races an agent that is editing the same plan.
RSpec.describe Workspace::PlanFile do
  around do |example|
    Dir.mktmpdir("plan-race") do |dir|
      @path = File.join(File.realpath(dir), "IMPLEMENTATION_PLAN.md")
      File.write(@path, "---\nstatus: active\n---\n## Tasks\n- [~] T1 One\n- [ ] T2 Two\n")
      example.run
    end
  end

  # Runs +edit+ each time the writer saves its temp file, which is after it read the plan and before it renames.
  def edit_while_writing(&edit)
    allow(File).to receive(:binwrite).and_wrap_original do |original, file, *rest|
      edit.call if file.end_with?(".tmp")
      original.call(file, *rest)
    end
  end

  it "makes its change again on what the agent saved, and keeps the agent's edit" do
    edits = 0
    edit_while_writing do
      edits += 1
      File.write(@path, File.read(@path).sub("- [~] T1 One", "- [x] T1 One")) if edits == 1
    end

    expect(described_class.set_status(@path, "paused")).to be true

    plan = described_class.read(@path)
    expect(plan.status).to eq("paused")
    expect(plan.tasks.map(&:state)).to eq(%w[done todo])
    expect(Dir.children(File.dirname(@path))).to eq(["IMPLEMENTATION_PLAN.md"])
  end

  it "gives up with plan_write_conflict when the agent saves during the second try as well, and changes nothing of its own" do
    edits = 0
    edit_while_writing do
      edits += 1
      File.write(@path, File.read(@path) + "- [ ] T#{edits + 2} Added #{edits}\n")
    end

    expect { described_class.set_status(@path, "paused") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("plan_write_conflict")
      expect(e.details).to eq("path" => @path)
    }

    plan = described_class.read(@path)
    expect(plan.status).to eq("active")
    expect(plan.tasks.map(&:id)).to eq(%w[T1 T2 T3 T4])
    expect(Dir.children(File.dirname(@path))).to eq(["IMPLEMENTATION_PLAN.md"])
  end

  it "does not write at all when the agent already made the change" do
    edit_while_writing { File.write(@path, File.read(@path).sub("status: active", "status: paused")) }

    expect(described_class.set_status(@path, "paused")).to be false

    expect(described_class.read(@path).status).to eq("paused")
  end

  it "stops with ENOENT when the agent deletes the plan during the write" do
    edit_while_writing { File.delete(@path) }

    expect { described_class.set_status(@path, "paused") }.to raise_error(Errno::ENOENT)

    expect(Dir.children(File.dirname(@path))).to eq([])
  end
end
