require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AskStore do
  let(:tmpdir) { Dir.mktmpdir("ws-ask-store") }
  let(:path) { File.join(tmpdir, "asks.json") }
  let(:error_output) { StringIO.new }
  subject(:store) { described_class.new(path: path, error_output: error_output) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  describe "#add" do
    it "records an open question with the default taken" do
      record = store.add(question: "pg or sqlite?", default: "sqlite", context: "lib/x.rb:1", pane: "%1", worktree: "/app")

      expect(record).to include(
        "question" => "pg or sqlite?", "default" => "sqlite", "context" => "lib/x.rb:1",
        "pane" => "%1", "worktree" => "/app", "status" => "open", "answer" => nil
      )
      expect(record["id"]).to be_a(String)
      expect(record["asked_at"]).to be_a(String)
    end

    it "persists across instances" do
      store.add(question: "q1", default: "d1")

      expect(described_class.new(path: path).list.size).to eq(1)
    end

    it "assigns each question a distinct id" do
      first = store.add(question: "q1", default: "d1")
      second = store.add(question: "q2", default: "d2")

      expect(first["id"]).not_to eq(second["id"])
    end

    it "draws a new id when the first one is already taken" do
      allow(SecureRandom).to receive(:hex).with(3).and_return("aaaaaa", "aaaaaa", "bbbbbb")

      store.add(question: "q1", default: "d1")

      expect(store.add(question: "q2", default: "d2")["id"]).to eq("bbbbbb")
    end

    it "refuses to record over a file that isn't valid JSON, leaving it unchanged" do
      File.write(path, '[{"id": ')

      expect { store.add(question: "q", default: "d") }
        .to raise_error(Workspace::Error, /#{Regexp.escape(path)}.*not valid JSON.*nothing was recorded and the file was left unchanged/)
      expect(File.read(path)).to eq('[{"id": ')
    end

    it "refuses to record over a file that holds something other than a list" do
      File.write(path, '{"id": "abc123"}')

      expect { store.add(question: "q", default: "d") }.to raise_error(Workspace::Error, /not a JSON list/)
      expect(File.read(path)).to eq('{"id": "abc123"}')
    end

    it "keeps entries that aren't objects when it rewrites the file" do
      File.write(path, JSON.generate([nil, {"id" => "abc123", "status" => "open"}]))

      store.add(question: "q", default: "d")

      expect(JSON.parse(File.read(path)).first).to be_nil
    end
  end

  describe "#list" do
    it "returns records oldest first" do
      store.add(question: "q1", default: "d1")
      store.add(question: "q2", default: "d2")

      expect(store.list.map { |r| r["question"] }).to eq(["q1", "q2"])
    end

    it "filters to open questions when open_only is true" do
      answered = store.add(question: "q1", default: "d1")
      store.add(question: "q2", default: "d2")
      store.answer(answered["id"], "a1")

      expect(store.list(open_only: true).map { |r| r["question"] }).to eq(["q2"])
    end

    it "returns an empty array when nothing has been recorded" do
      expect(store.list).to eq([])
    end

    it "does not create the store directory or lockfile" do
      described_class.new(path: File.join(tmpdir, "ws", "asks.json")).list

      expect(Dir.exist?(File.join(tmpdir, "ws"))).to be(false)
    end

    it "reads an unparseable file as empty, with a warning" do
      File.write(path, "not json")

      expect(store.list).to eq([])
      expect(error_output.string).to include("ignoring question store #{path}", "not valid JSON")
      expect(File.read(path)).to eq("not json")
    end

    it "skips entries that aren't objects" do
      File.write(path, JSON.generate([nil, 3, {"id" => "abc123", "status" => "open"}]))

      expect(store.list(open_only: true).map { |r| r["id"] }).to eq(["abc123"])
    end
  end

  describe "#answer" do
    it "marks a question answered and records the answer" do
      record = store.add(question: "q1", default: "d1")

      answered = store.answer(record["id"], "use postgres")

      expect(answered).to include("status" => "answered", "answer" => "use postgres")
      expect(answered["answered_at"]).to be_a(String)
    end

    it "refuses to answer against an unparseable file, leaving it unchanged" do
      File.write(path, "not json")

      expect { store.answer("abc123", "a") }.to raise_error(Workspace::Error, /left unchanged/)
      expect(File.read(path)).to eq("not json")
    end

    it "returns nil for an unknown id" do
      expect(store.answer("nope", "answer")).to be_nil
    end

    it "returns nil for a question that is already answered" do
      record = store.add(question: "q1", default: "d1")
      store.answer(record["id"], "first answer")

      expect(store.answer(record["id"], "second answer")).to be_nil
    end
  end
end
