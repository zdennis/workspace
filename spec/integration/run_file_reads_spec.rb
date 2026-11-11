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

      it "stored_run equals find, mutable and independent" do
        run = stored_run(store, id)
        expect(run).to eq(store.find(id))
        expect(run).not_to be_frozen
        run["state"] = "changed"
        expect(stored_run(store, id)).to eq(store.find(id))
      end

      it "stored_run refuses an unknown id as find does" do
        expect { stored_run(store, "wr_nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_run") }
        expect { store.find("wr_nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_run") }
      end

      it "going_runs equals active and finished_runs equals archived" do
        expect(going_runs(store)).to eq(store.active)
        expect(finished_runs(store)).to eq(store.archived)
      end

      it "edit_run leaves the bytes and answer update does" do
        other = File.join(root, "other")
        other_store = build_store(other)
        place(other, text)
        block = lambda do |hash|
          hash["marker"] = {"nested" => [1, 2]}
          hash["state"]
        end
        if Workspace::WorkflowRunStore::TERMINAL_STATES.include?(JSON.parse(text)["state"])
          expect { edit_run(store, id, &block) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_not_active") }
          expect { other_store.update(id, &block) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_not_active") }
        else
          expect(edit_run(store, id, &block)).to eq(other_store.update(id, &block))
          expect(File.binread(File.join(root, "runs", "#{id}.json"))).to eq(File.binread(File.join(other, "runs", "#{id}.json")))
        end
      end
    end
  end

  it "lists many runs in the order the Hash methods do" do
    store = build_store(root)
    fixture_paths.each_with_index do |path, i|
      hash = JSON.parse(File.read(path))
      hash["created_at"] = "2026-01-01T00:00:%02dZ" % (i * 3 % 60)
      hash["ended_at"] = "2026-01-01T00:01:%02dZ" % (i * 7 % 60) if hash["ended_at"]
      place(root, JSON.generate(hash), id: "wr_#{File.basename(path, ".json")}")
    end
    expect(going_runs(store)).to eq(store.active)
    expect(finished_runs(store)).to eq(store.archived)
    expect(going_runs(store)).not_to be_empty
    expect(finished_runs(store)).not_to be_empty
  end

  it "edit_run returns nil for a busy run when nonblocking, as update does" do
    store = build_store(root)
    place(root, File.read(fixture_paths.find { |p| JSON.parse(File.read(p))["state"] == "running" }))
    Workspace::FileLock.new(File.join(root, "runs", "wr_simulated.lock")).hold do
      expect(edit_run(store, "wr_simulated", nonblocking: true) { 1 }).to be_nil
      expect(store.update("wr_simulated", nonblocking: true) { 1 }).to be_nil
    end
  end
end
