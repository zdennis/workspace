require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AskStore do
  let(:tmpdir) { Dir.mktmpdir("ws-ask-store") }
  let(:path) { File.join(tmpdir, "asks.json") }
  subject(:store) { described_class.new(path: path) }

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
  end

  describe "#answer" do
    it "marks a question answered and records the answer" do
      record = store.add(question: "q1", default: "d1")

      answered = store.answer(record["id"], "use postgres")

      expect(answered).to include("status" => "answered", "answer" => "use postgres")
      expect(answered["answered_at"]).to be_a(String)
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
