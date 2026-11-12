require "spec_helper"
require "tmpdir"

RSpec.describe RunFileReads do
  fixture_paths = Dir[File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_runs", "*.json")].sort

  def build_store(root)
    Workspace::WorkflowRunStore.new(dir: File.join(root, "runs"), archive_dir: File.join(root, "archive"))
  end

  def place(root, text, id: nil)
    hash = JSON.parse(text)
    hash["id"] = id if id
    dir = Workspace::WorkflowRunStore::TERMINAL_STATES.include?(hash["state"]) ? "archive" : "runs"
    FileUtils.mkdir_p(File.join(root, dir))
    path = File.join(root, dir, "#{hash["id"]}.json")
    File.write(path, id ? JSON.pretty_generate(hash) : text)
    path
  end

  let(:root) { Dir.mktmpdir }

  after { FileUtils.remove_entry(root) }

  it "has fixtures to prove against" do
    expect(fixture_paths).not_to be_empty
  end

  fixture_paths.each do |path|
    describe File.basename(path) do
      let(:text) { File.read(path) }
      let(:id) { JSON.parse(text)["id"] }
      let(:store) { build_store(root) }

      before { place(root, text) }

      it "stored_run equals the run file and #run, mutable and independent" do
        run = stored_run(store, id)
        expect(run).to eq(JSON.parse(text))
        expect(run).to eq(store.run(id).to_h)
        expect(run).not_to be_frozen
        run["state"] = "changed"
        expect(stored_run(store, id)).to eq(JSON.parse(text))
      end

      it "stored_run refuses an unknown id as #run does" do
        expect { stored_run(store, "wr_nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_run") }
        expect { store.run("wr_nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_run") }
      end

      it "going_runs equals #going and finished_runs equals #finished" do
        expect(going_runs(store)).to eq(store.going.map(&:to_h))
        expect(finished_runs(store)).to eq(store.finished.map(&:to_h))
      end

      it "edit_run leaves the bytes #change does, and answers the block's value" do
        other = File.join(root, "other")
        other_store = build_store(other)
        place(other, text)
        block = lambda do |hash|
          hash["marker"] = {"nested" => [1, 2]}
          hash["state"]
        end
        if Workspace::WorkflowRunStore::TERMINAL_STATES.include?(JSON.parse(text)["state"])
          expect { edit_run(store, id, &block) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_not_active") }
          expect { other_store.change(id) { |run| run } }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_not_active") }
        else
          expect(edit_run(store, id, &block)).to eq(JSON.parse(text)["state"])
          other_store.change(id) do |run|
            hash = Workspace::WorkflowRun.deep_thaw(run.to_h)
            block.call(hash)
            Workspace::WorkflowRun.from_h(hash)
          end
          expect(File.binread(File.join(root, "runs", "#{id}.json"))).to eq(File.binread(File.join(other, "runs", "#{id}.json")))
        end
      end
    end
  end

  it "lists many runs in the order #going and #finished do" do
    store = build_store(root)
    fixture_paths.each_with_index do |path, i|
      hash = JSON.parse(File.read(path))
      hash["created_at"] = "2026-01-01T00:00:%02dZ" % (i * 3 % 60)
      hash["ended_at"] = "2026-01-01T00:01:%02dZ" % (i * 7 % 60) if hash["ended_at"]
      place(root, JSON.generate(hash), id: "wr_#{File.basename(path, ".json")}")
    end
    expect(going_runs(store)).to eq(store.going.map(&:to_h))
    expect(finished_runs(store)).to eq(store.finished.map(&:to_h))
    expect(going_runs(store)).not_to be_empty
    expect(finished_runs(store)).not_to be_empty
  end

  it "edit_run returns nil for a busy run when nonblocking, as #change does" do
    store = build_store(root)
    place(root, File.read(fixture_paths.find { |p| JSON.parse(File.read(p))["state"] == "running" }))
    Workspace::FileLock.new(File.join(root, "runs", "wr_simulated.lock")).hold do
      expect(edit_run(store, "wr_simulated", nonblocking: true) { 1 }).to be_nil
      expect(store.change("wr_simulated", nonblocking: true) { nil }).to be_nil
    end
  end
end
