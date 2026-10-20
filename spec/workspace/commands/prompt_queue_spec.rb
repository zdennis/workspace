require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::PromptQueue do
  let(:state_dir) { Dir.mktmpdir }
  let(:config) do
    instance_double(Workspace::Config, state_dir: state_dir).tap do |c|
      allow(c).to receive(:prompt_queue_path) { |name| File.join(state_dir, name, "prompt-queue.json") }
    end
  end
  let(:now) { [Time.utc(2026, 10, 19, 12, 0, 0)] }
  let(:clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }
  let(:ids) { (1..30).map { |n| format("%016x", n) } }
  let(:id_pool) { ids.dup }
  let(:event_log) { CLITestHelpers::FakeEventLog.new }
  let(:locator) { instance_double(Workspace::PaneLocator) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:columns) { 60 }
  let(:alive) { [4242] }
  let(:identity) { {"server_pid" => "77", "pane_pid" => 100, "agent_pid" => 101, "session_id" => "s1"} }

  subject(:command) do
    described_class.new(config: config, locator: locator, event_log: event_log, clock: clock, columns: -> { columns },
      store_factory: ->(path) { Workspace::PromptQueueStore.new(path: path, clock: clock, id_generator: -> { id_pool.shift }, pid_alive: ->(pid) { alive.include?(pid) }) },
      output: output, error_output: error_output)
  end

  after { FileUtils.remove_entry(state_dir) }

  def store_for(name)
    Workspace::PromptQueueStore.new(path: config.prompt_queue_path(name), clock: clock, id_generator: -> { id_pool.shift }, pid_alive: ->(pid) { alive.include?(pid) })
  end

  def add(name, text, pane_id: "%5", at: nil)
    now[0] = at if at
    store_for(name).add(pane_id: pane_id, text: text, identity: identity).last
  end

  def json
    JSON.parse(output.string)
  end

  describe "#list" do
    it "answers rows grouped by pane, the pane with the oldest entry first, positions from 1" do
      add("api", "later pane", pane_id: "%9", at: Time.utc(2026, 10, 19, 12, 0, 5))
      add("api", "first", at: Time.utc(2026, 10, 19, 12, 0, 1))
      add("api", "second", at: Time.utc(2026, 10, 19, 12, 0, 9))
      add("api", "other", pane_id: "%9", at: Time.utc(2026, 10, 19, 12, 0, 10))
      now[0] = Time.utc(2026, 10, 19, 12, 1, 0)

      command.list(name: "api", json: true)

      expect(json).to include("schema_version" => 1, "ok" => true, "workspace" => "api")
      expect(json["entries"].map { |r| r.values_at("pane_id", "position", "preview") }).to eq(
        [["%5", 1, "first"], ["%5", 2, "second"], ["%9", 1, "later pane"], ["%9", 2, "other"]]
      )
      expect(json["entries"].first).to eq("id" => ids[1], "pane_id" => "%5", "position" => 1, "state" => "queued",
        "queued_at" => "2026-10-19T12:00:01.000Z", "clear_first" => false, "preview" => "first", "length" => 5)
    end

    it "cuts the preview at 200 characters, escapes control characters and reports the full length" do
      add("api", "a\nb\t" + ("x" * 300) + "\e")

      command.list(name: "api", json: true)

      row = json["entries"].first
      expect(row["preview"]).to eq("a\\nb\\t" + ("x" * 196))
      expect(row["preview"].length).to eq(202)
      expect(row["length"]).to eq(305)
    end

    it "counts the 200 characters, not bytes" do
      add("api", "é" * 250)

      command.list(name: "api", json: true)

      expect(json["entries"].first["preview"]).to eq("é" * 200)
    end

    it "shows a delivering entry as delivering" do
      add("api", "one")
      store_for("api").claim("%5", daemon_pid: 4242) { now[0] }

      command.list(name: "api", json: true)

      expect(json["entries"].first["state"]).to eq("delivering")
    end

    it "narrows to a pane id as given, without asking tmux" do
      expect(locator).not_to receive(:locate)
      add("api", "one")
      add("api", "two", pane_id: "%6")

      command.list(name: "api", pane: "%6", json: true)

      expect(json["entries"].map { |r| r["preview"] }).to eq(%w[two])
    end

    it "resolves window.pane through the locator" do
      add("api", "one")
      add("api", "two", pane_id: "%6")
      allow(locator).to receive(:locate).with("api", "0.1").and_return({id: "%6"})

      command.list(name: "api", pane: "0.1", json: true)

      expect(json["entries"].map { |r| r["preview"] }).to eq(%w[two])
    end

    it "passes the locator's pane errors on" do
      allow(locator).to receive(:locate).and_raise(Workspace::Error.new("no", code: "no_such_pane"))

      expect { command.list(name: "api", pane: "9.9") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_such_pane") }
    end

    it "lists nothing for a pane or a workspace with no entries" do
      add("api", "one")

      command.list(name: "api", pane: "%99", json: true)
      expect(json["entries"]).to eq([])

      output.truncate(0)
      output.rewind
      command.list(name: "nothing-here", json: true)
      expect(json["entries"]).to eq([])
    end

    it "prints one line per entry in human mode, the preview cut to the width" do
      add("api", "short", at: Time.utc(2026, 10, 19, 11, 59, 0))
      add("api", "y" * 150)

      now[0] = Time.utc(2026, 10, 19, 12, 0, 0)
      command.list(name: "api")

      lines = output.string.lines.map(&:chomp)
      expect(lines.first).to eq("%5    #1  queued     1m    #{ids[0]} short")
      expect(lines.last.length).to eq(columns)
      expect(lines.last).to end_with("...")
    end

    it "says so in human mode when nothing is queued" do
      now[0] = Time.utc(2026, 10, 19, 12, 0, 0)
      command.list(name: "api")

      expect(output.string).to eq("No prompts queued in 'api'.\n")
    end

    it "raises, rather than hide entries, when the file can't be read" do
      FileUtils.mkdir_p(File.join(state_dir, "api"))
      File.write(config.prompt_queue_path("api"), "not json")

      expect { command.list(name: "api") }.to raise_error(Workspace::Error, /can't be read/)
    end
  end

  describe "#cancel" do
    it "removes a queued entry, answers its full text and records a cancelled dequeue" do
      entry = add("api", "do the thing\nin two lines")

      command.cancel(id: entry["id"], name: "api", json: true)

      expect(json).to include("schema_version" => 1, "ok" => true, "workspace" => "api", "cancelled" => true,
        "id" => entry["id"], "pane_id" => "%5", "text" => "do the thing\nin two lines")
      expect(json).not_to have_key("cancel_requested")
      expect(store_for("api").entries).to eq([])
      expect(event_log.events).to eq([{"type" => "prompt_dequeued", "project" => "api",
                                       "data" => {"id" => entry["id"], "pane_id" => "%5", "outcome" => "cancelled"}}])
    end

    it "marks a claimed entry that is not yet pasting, and answers cancelled" do
      entry = add("api", "one")
      store_for("api").claim("%5", daemon_pid: 4242) { now[0] }

      command.cancel(id: entry["id"], name: "api", json: true)

      expect(json).to include("cancelled" => true, "cancel_requested" => true, "text" => "one")
      expect(store_for("api").entries.first).to include("state" => "delivering", "cancel_requested" => true)
      expect(event_log.events.size).to eq(1)
    end

    it "makes the delivery that finds the flag type nothing" do
      entry = add("api", "one")
      claim = store_for("api").claim("%5", daemon_pid: 4242) { now[0] }.first
      command.cancel(id: entry["id"], name: "api")

      expect(store_for("api").start_paste(claim)).to eq(:cancelled)
      expect(store_for("api").entries).to eq([])
    end

    it "answers a repeated cancel of a stopping delivery the same way, with no second event" do
      entry = add("api", "one")
      store_for("api").claim("%5", daemon_pid: 4242) { now[0] }
      command.cancel(id: entry["id"], name: "api")
      output.truncate(0)
      output.rewind

      command.cancel(id: entry["id"], name: "api", json: true)

      expect(json).to include("cancelled" => true, "cancel_requested" => true)
      expect(event_log.events.size).to eq(1)
    end

    it "names the queues it couldn't read when the id isn't found elsewhere" do
      FileUtils.mkdir_p(File.join(state_dir, "aaa"))
      File.write(config.prompt_queue_path("aaa"), "not json")

      expect { command.cancel(id: "deadbeefdeadbeef") }.to raise_error(Workspace::Error) { |e|
        expect(e.details).to eq("id" => "deadbeefdeadbeef", "unreadable" => ["aaa"])
      }
    end

    it "refuses unknown_id with details.state delivering once the paste started, and changes nothing" do
      entry = add("api", "one")
      claim = store_for("api").claim("%5", daemon_pid: 4242) { now[0] }.first
      store_for("api").start_paste(claim)

      expect { command.cancel(id: entry["id"], name: "api") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_id")
        expect(e.details).to eq("id" => entry["id"], "workspace" => "api", "state" => "delivering")
      }
      expect(store_for("api").entries.first).not_to have_key("cancel_requested")
      expect(event_log.events).to eq([])
    end

    it "refuses unknown_id, with no state, for an id that is gone" do
      expect { command.cancel(id: "deadbeefdeadbeef", name: "api") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_id")
        expect(e.details).to eq("id" => "deadbeefdeadbeef", "workspace" => "api")
      }
      expect(event_log.events).to eq([])
    end

    it "searches every workspace's queue without --name and reports the one it found" do
      add("web", "other workspace")
      entry = add("api", "mine")

      command.cancel(id: entry["id"], json: true)

      expect(json).to include("workspace" => "api", "text" => "mine")
      expect(store_for("web").entries.size).to eq(1)
      expect(event_log.events.first["project"]).to eq("api")
    end

    it "is unknown_id without --name when no queue holds the id" do
      add("api", "one")

      expect { command.cancel(id: "deadbeefdeadbeef") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_id")
        expect(e.details).to eq("id" => "deadbeefdeadbeef")
      }
    end

    it "skips an unreadable queue file when searching, with a warning" do
      FileUtils.mkdir_p(File.join(state_dir, "aaa"))
      File.write(config.prompt_queue_path("aaa"), "not json")
      entry = add("api", "mine")

      command.cancel(id: entry["id"], json: true)

      expect(json["cancelled"]).to eq(true)
      expect(error_output.string).to include("skipping 'aaa'")
    end

    it "prints a sentence in human mode" do
      entry = add("api", "one")

      command.cancel(id: entry["id"], name: "api")

      expect(output.string).to eq("Cancelled #{entry["id"]} for pane %5 of 'api'.\n")
    end
  end
end
