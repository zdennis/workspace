require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowRunStore do
  around do |example|
    Dir.mktmpdir("wf-runs") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:runs_dir) { File.join(@dir, ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, ".workflows", "archive") }
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
  let(:ids) { %w[wr_1 wr_2 wr_3] }
  subject(:store) { described_class.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }

  # The least a run file holds to be read as a run: a current step among its steps and in its definition.
  let(:whole) do
    {"current" => "plan", "steps" => {"plan" => {"state" => "running", "attempts" => []}}, "definition" => {"steps" => [{"id" => "plan"}]}}
  end

  def create(fields = {})
    store.create({"workflow" => "rpiv", "workspace" => "app", "state" => "running", "created_at" => now.first.utc.iso8601}.merge(whole).merge(fields))
  end

  it "writes a new run under an id, where RunLiveness finds it alive" do
    run = create

    expect(run["id"]).to eq("wr_1")
    expect(JSON.parse(File.read(File.join(runs_dir, "wr_1.json")))).to eq(run)
    expect(File.stat(File.join(runs_dir, "wr_1.json")).mode & 0o777).to eq(0o600)
    expect(Workspace::RunLiveness.new(dir: runs_dir).alive?("wr_1")).to be true
    expect(store.find("wr_1")).to eq(run)
  end

  it "never gives a new run the id of a run going or finished" do
    create
    store.update("wr_1") { |run| run["state"] = "completed" }
    ids.unshift("wr_1")

    expect(create["id"]).to eq("wr_2")
  end

  it "makes ids from the time by default, as names RunLiveness accepts" do
    id = described_class.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }).create("state" => "running")["id"]

    expect(id).to match(/\Awr_261004120000[a-z0-9]{4}\z/)
    expect(id).to match(Workspace::RunLiveness::ID_PATTERN)
  end

  it "stores what an update's block left in the run, and returns the block's value" do
    create

    result = store.update("wr_1") do |run|
      run["note"] = "kept"
      :done
    end

    expect(result).to eq(:done)
    expect(store.find("wr_1")["note"]).to eq("kept")
  end

  it "stores nothing when the block raises" do
    create

    expect { store.update("wr_1") { |run| run["note"] = "kept?" and raise Workspace::Error, "no" } }.to raise_error(Workspace::Error, "no")
    expect(store.find("wr_1")).not_to have_key("note")
  end

  it "moves a run that finished to the archive with its history, so it is no longer alive and still found" do
    create
    store.record_event("wr_1", "run_started", "workflow" => "rpiv")

    store.update("wr_1") { |run| run.merge!("state" => "cancelled", "ended_at" => "2026-10-04T12:05:00Z") }

    expect(Dir.children(runs_dir)).to eq([])
    expect(Dir.children(archive_dir).sort).to eq(%w[wr_1.events.jsonl wr_1.json])
    expect(Workspace::RunLiveness.new(dir: runs_dir).alive?("wr_1")).to be false
    expect(store.find("wr_1")["state"]).to eq("cancelled")
    expect(store.events_path("wr_1")).to eq(File.join(archive_dir, "wr_1.events.jsonl"))
    expect(store.active).to eq([])
    expect(store.archived.map { |run| run["id"] }).to eq(["wr_1"])
  end

  it "refuses to update a finished run, with its state" do
    create
    store.update("wr_1") { |run| run["state"] = "completed" }

    expect { store.update("wr_1") { |run| run["state"] = "running" } }
      .to raise_error(Workspace::Error, "Workflow run wr_1 is completed; nothing more can happen to it.") { |error|
        expect(error.code).to eq("run_not_active")
        expect(error.details).to eq("run_id" => "wr_1", "state" => "completed")
      }
    expect(Dir.children(runs_dir)).to eq([])
  end

  it "lets the caller fill in what depends on the id before the run's file is written" do
    run = store.create(whole.merge("state" => "waiting")) { |created| created["artifacts_dir"] = "/src/app/.workflow/#{created["id"]}" }

    expect(run["artifacts_dir"]).to eq("/src/app/.workflow/wr_1")
    expect(JSON.parse(File.read(File.join(runs_dir, "wr_1.json")))).to eq(run)
  end

  it "does not hand out a finished run that is still among the runs going: it archives it and refuses" do
    create
    path = File.join(runs_dir, "wr_1.json")
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("state" => "cancelled")))
    yielded = false

    expect { store.update("wr_1") { yielded = true } }.to raise_error(Workspace::Error) { |error|
      expect(error.code).to eq("run_not_active")
      expect(error.details).to eq("run_id" => "wr_1", "state" => "cancelled")
    }
    expect(yielded).to be false
    expect(Dir.children(runs_dir)).to eq([])
    expect(Dir.children(archive_dir)).to eq(["wr_1.json"])
  end

  describe "a run file that can't be read as a run" do
    before do
      create
      create
      File.write(File.join(runs_dir, "wr_1.json"), "{not json")
      # The file's name is the id: a file naming another run is not that run, nor this one.
      File.write(File.join(runs_dir, "wr_2.json"), JSON.generate({"id" => "wr_3", "state" => "waiting", "workspace" => "app"}.merge(whole)))
    end

    it "is listed by path, and is not among the runs" do
      expect(store.unreadable).to eq([File.join(runs_dir, "wr_1.json"), File.join(runs_dir, "wr_2.json")])
      expect(store.active).to eq([])
    end

    it "includes a run without the steps every verb goes by, however it lacks them" do
      path = File.join(runs_dir, "wr_1.json")
      base = {"id" => "wr_1", "state" => "running"}.merge(whole)
      broken = [
        base.except("steps"), base.except("current"), base.except("definition"), base.merge("current" => "verify"),
        base.merge("steps" => {"plan" => {"state" => "running"}}), base.merge("steps" => {"plan" => {"attempts" => [1]}}),
        base.merge("steps" => []), base.merge("definition" => {"steps" => [{"id" => "other"}]}), base.merge("definition" => {"steps" => {}}),
        base.merge("definition" => "x"), base.merge("definition" => ["x"]), base.merge("definition" => {"steps" => ["plan"]}),
        base.merge("steps" => {"plan" => "x"}),
        # Every step of the definition needs its state, not only the current one.
        base.merge("definition" => {"steps" => [{"id" => "plan"}, {"id" => "verify"}]}),
        base.merge("definition" => {"steps" => [{"id" => "plan"}, {"id" => "verify"}]},
          "steps" => {"plan" => {"state" => "running", "attempts" => []}, "verify" => {"state" => "pending"}}),
        [base]
      ]

      broken.each do |content|
        File.write(path, JSON.generate(content))
        expect(store.unreadable).to include(path), "expected #{content.inspect[0, 80]} to be unreadable"
        expect { store.update("wr_1") { |run| run } }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_run") }
      end
      File.write(path, JSON.generate(base))
      expect(store.find("wr_1")).to eq(base)
    end

    it "does not count a run that finished between the listing and the read" do
      gone = File.join(runs_dir, "wr_9.json")
      allow(Dir).to receive(:glob).and_call_original
      allow(Dir).to receive(:glob).with(File.join(runs_dir, "*.json")).and_return([gone, File.join(runs_dir, "wr_1.json")])

      expect(store.unreadable).to eq([File.join(runs_dir, "wr_1.json")])
    end

    it "includes a file that may not be read, and one whose name is not a run id" do
      skip "root reads any file" if Process.uid.zero?
      create
      path = File.join(runs_dir, "wr_3.json")
      odd = File.join(runs_dir, "not an id.json")
      File.write(odd, JSON.generate({"id" => "not an id", "state" => "running"}.merge(whole)))
      File.chmod(0o000, path)

      expect(store.unreadable).to include(path, odd)
      expect(store.active).to eq([])
      expect { store.find("wr_3") }.to raise_error(Workspace::Error) { |error| expect(error.details).to eq("run_id" => "wr_3", "path" => path) }
    ensure
      File.chmod(0o600, path) if path && File.exist?(path)
    end

    it "is not found or changed under its id, and the error names the file and the way out" do
      %w[wr_1 wr_2].each do |id|
        path = File.join(runs_dir, "#{id}.json")
        before = File.read(path)
        [-> { store.find(id) }, -> { store.update(id) { |run| run["state"] = "cancelled" } }].each do |call|
          expect(&call).to raise_error(Workspace::Error, /The file of workflow run #{id} can't be read as a run \(#{Regexp.escape(path)}\).*workspace lock clear NAME.*delete the file/) { |error|
            expect(error.code).to eq("unknown_run")
            expect(error.details).to eq("run_id" => id, "path" => path)
          }
        end
        expect(File.read(path)).to eq(before)
      end
      expect(Dir.exist?(archive_dir)).to be false
    end
  end

  describe "read by a process with no UTF-8 locale" do
    it "reads back the non-ASCII text a run holds, as UTF-8, through every way a run is read" do
      create("inputs" => {"task" => "café"})
      store.update("wr_1") { |run| run["note"] = "naïve" }

      without_utf8_locale do
        expect(File.read(File.join(runs_dir, "wr_1.json")).encoding).to eq(Encoding::US_ASCII)
        run = store.find("wr_1")
        expect(run).to include("inputs" => {"task" => "café"}, "note" => "naïve")
        expect(run["note"].encoding).to eq(Encoding::UTF_8)
        expect(store.active.map { |each| each["id"] }).to eq(["wr_1"])
        expect(store.unreadable).to eq([])
        expect(store.update("wr_1") { |each| each["note"] = "déjà vu" }).to eq("déjà vu")
        expect(store.create(whole.merge("title" => "Über"))["id"]).to eq("wr_2")
      end
      expect(JSON.parse(File.read(File.join(runs_dir, "wr_1.json"), encoding: "UTF-8"))["note"]).to eq("déjà vu")
      expect(store.find("wr_2")["title"]).to eq("Über")
    end

    it "calls a run file whose bytes are not UTF-8 unreadable, in any locale" do
      create
      path = File.join(runs_dir, "wr_1.json")
      File.binwrite(path, File.binread(path).sub("rpiv", "rp\xFFiv".b))

      [-> { without_utf8_locale { store.unreadable } }, -> { store.unreadable }].each { |call| expect(call.call).to eq([path]) }
      without_utf8_locale do
        expect { store.find("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.details).to eq("run_id" => "wr_1", "path" => path) }
      end
    end
  end

  it "refuses, as a workspace error, to store text that is not valid UTF-8, and leaves the run as it was" do
    create
    bad = (+"caf\xC3").force_encoding("UTF-8")

    expect { store.update("wr_1") { |run| run["note"] = bad } }
      .to raise_error(Workspace::Error, /Could not write the workflow run: it holds text that is not valid UTF-8/)
    expect { store.create(whole.merge("note" => bad)) }.to raise_error(Workspace::Error, /not valid UTF-8/)
    expect(store.find("wr_1")).not_to have_key("note")
    expect(Dir.children(runs_dir).grep(/tmp/)).to eq([])
  end

  it "raises unknown_run for an id no run has, or one that is not an id, and leaves no lock file" do
    expect { store.find("wr_9") }.to raise_error(Workspace::Error) { |error| expect(error.details).to eq("run_id" => "wr_9") }
    ["wr_9", "../wr_1", "", nil].each do |id|
      expect { store.find(id) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_run") }
      expect { store.update(id) { |run| run } }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_run") }
    end
    expect(Dir.exist?(runs_dir) ? Dir.children(runs_dir) : []).to eq([])
  end

  it "lists the runs still going, oldest first, and finished runs newest first" do
    create("created_at" => "2026-10-04T12:00:02Z")
    create("created_at" => "2026-10-04T12:00:01Z")
    create("created_at" => "2026-10-04T12:00:03Z")
    store.update("wr_1") { |run| run.merge!("state" => "completed", "ended_at" => "2026-10-04T13:00:00Z") }
    store.update("wr_3") { |run| run.merge!("state" => "cancelled", "ended_at" => "2026-10-04T14:00:00Z") }

    expect(store.active.map { |run| run["id"] }).to eq(["wr_2"])
    expect(store.archived.map { |run| run["id"] }).to eq(%w[wr_3 wr_1])
  end

  it "skips a file that is not a run when listing" do
    create
    File.write(File.join(runs_dir, "junk.json"), "{not json")
    File.write(File.join(runs_dir, "list.json"), "[]")

    expect(store.active.map { |run| run["id"] }).to eq(["wr_1"])
  end

  it "returns nil from a nonblocking update while another process changes the run" do
    create
    reader, writer = IO.pipe
    release_reader, release_writer = IO.pipe
    pid = fork do
      described_class.new(dir: runs_dir, archive_dir: archive_dir).update("wr_1") do |run|
        writer.puts "held"
        release_reader.gets
        run["note"] = "held"
      end
      exit!(0)
    end
    reader.gets

    expect(store.update("wr_1", nonblocking: true) { |run| run["note"] = "skipped" }).to be_nil

    release_writer.puts "go"
    Process.wait(pid)
    expect(store.find("wr_1")["note"]).to eq("held")
  end

  it "appends one line per event to the run's history" do
    create
    store.record_event("wr_1", "run_started", "workflow" => "rpiv")
    now[0] += 5
    store.record_event("wr_1", "step_dispatched", "step" => "research", "attempt" => 1)

    lines = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }
    expect(lines).to eq([
      {"ts" => "2026-10-04T12:00:00Z", "type" => "run_started", "workflow" => "rpiv"},
      {"ts" => "2026-10-04T12:00:05Z", "type" => "step_dispatched", "step" => "research", "attempt" => 1}
    ])
  end

  it "does not raise when the history can't be written" do
    expect(store.record_event("wr_1", "run_started")).to be_nil
  end

  it "keeps the newest finished runs and removes the rest" do
    stub_const("#{described_class}::ARCHIVE_LIMIT", 2)
    3.times do |n|
      create
      store.record_event("wr_#{n + 1}", "run_started")
      store.update("wr_#{n + 1}") { |run| run.merge!("state" => "completed", "ended_at" => "2026-10-04T13:00:0#{n}Z") }
    end

    expect(Dir.children(archive_dir).sort).to eq(%w[wr_2.events.jsonl wr_2.json wr_3.events.jsonl wr_3.json])
  end

  it "reports a store it can't write as an error" do
    FileUtils.mkdir_p(File.dirname(runs_dir))
    File.write(runs_dir, "a file where the directory should be")

    expect { create }.to raise_error(Workspace::Error, /Could not access the workflow run store at #{Regexp.escape(runs_dir)}/)
  end
end
