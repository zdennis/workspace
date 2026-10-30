require "spec_helper"
require "json"

RSpec.describe Workspace::Commands::PrFeedback do
  let(:output) { StringIO.new }
  let(:checkout) { instance_double(Workspace::WorkspaceCheckout) }
  let(:target) { {"workspace" => "api.worktree-x", "path" => "/tmp/wt", "branch" => "feature/x"} }
  let(:feedback) { instance_double(Workspace::PullRequestFeedback) }
  subject(:command) { described_class.new(feedback: feedback, checkout: checkout, output: output) }

  def comment(body: "Rename this.", author: "rev", trusted: true, hidden_html: false)
    {"id" => 1, "author" => author, "author_kind" => "user", "author_association" => "MEMBER", "trusted" => trusted,
     "body" => body, "hidden_html" => hidden_html, "created_at" => "2026-10-29T10:00:00Z", "url" => nil}
  end

  def thread(resolved: false, outdated: false, line: 12, comments: [comment])
    {"id" => "PRRT_1", "path" => "lib/a.rb", "line" => line, "original_line" => line, "side" => "RIGHT", "resolved" => resolved,
     "outdated" => outdated, "url" => nil, "comments" => comments, "comments_truncated" => false}
  end

  let(:threads) { [thread] }
  let(:reviews) { [] }
  let(:comments) { [] }
  let(:failed) { [] }
  let(:read) do
    {"pull_request" => {"number" => 41, "url" => "https://github.com/o/r/pull/41", "title" => "Add x", "state" => "OPEN", "draft" => false,
                        "cross_repository" => false, "head_ref" => "feature/x", "head_sha" => "abc", "base_ref" => "main",
                        "review_decision" => nil, "author" => "me", "author_kind" => "user"},
     "threads" => threads, "reviews" => reviews, "comments" => comments, "checks" => {"failed" => failed},
     "totals" => {"threads" => 9, "reviews" => 4, "comments" => 5, "checks" => 2},
     "truncated" => {"threads" => true, "reviews" => false, "comments" => false, "checks" => false}}
  end

  before do
    allow(checkout).to receive(:resolve).and_return(target)
    allow(feedback).to receive(:call).and_return(read)
  end

  def document
    @document ||= begin
      command.call(json: true, working_dir: "/tmp/wt")
      JSON.parse(output.string)
    end
  end

  it "resolves the checkout and reads the feedback for its branch" do
    command.call(name: "api", json: true, working_dir: "/w")

    expect(checkout).to have_received(:resolve).with("api", working_dir: "/w")
    expect(feedback).to have_received(:call).with("/tmp/wt", branch: "feature/x")
  end

  it "builds the document, mapping totals to counts" do
    expect(document).to include("schema_version" => 1, "ok" => true, "workspace" => "api.worktree-x", "branch" => "feature/x",
      "truncated" => {"threads" => true, "reviews" => false, "comments" => false, "checks" => false})
    expect(document["pull_request"]).not_to have_key("author_kind")
    expect(document["counts"]).to eq("threads" => 9, "unresolved" => 1, "resolved" => 0, "outdated" => 0, "reviews" => 0,
      "comments" => 0, "failing_checks" => 0)
    expect(document["threads"].first["comments"].first).to include("body" => "Rename this.", "body_truncated" => false)
  end

  context "with resolved and fully minimized threads" do
    let(:threads) { [thread, thread(resolved: true, outdated: true), thread(comments: [])] }

    it "leaves resolved threads and empty ones out, but counts the resolved ones" do
      expect(document["threads"].size).to eq(1)
      expect(document["counts"]).to include("unresolved" => 2, "resolved" => 1, "outdated" => 1)
    end

    it "keeps resolved threads with --all" do
      command.call(all: true, json: true, working_dir: "/w")

      expect(JSON.parse(output.string)["threads"].size).to eq(2)
    end
  end

  context "with a long body" do
    let(:comments) { [comment(body: "a" * 4_001), comment(body: "b" * 4_000)] }

    it "cuts at 4,000 characters and says so" do
      expect(document["comments"].map { |c| [c["body"].length, c["body_truncated"]] }).to eq([[4_000, true], [4_000, false]])
      expect(document["counts"]["comments"]).to eq(2)
    end
  end

  context "with failing checks and a review" do
    let(:failed) { [{"name" => "rspec", "url" => nil, "run_id" => 9}] }
    let(:reviews) { [comment.merge("state" => "CHANGES_REQUESTED", "submitted_at" => "x")] }

    it "reports them in the counts" do
      expect(document["checks"]).to eq("failed" => failed)
      expect(document["counts"]).to include("reviews" => 1, "failing_checks" => 1)
    end
  end

  describe "text output" do
    let(:failed) { [{"name" => "rspec", "url" => nil, "run_id" => 9}] }
    let(:threads) do
      [thread(comments: [comment(body: "first\nsecond", trusted: false, hidden_html: true)]), thread(line: nil)]
    end

    it "prints the summary, a line per thread and one per failing check" do
      command.call(working_dir: "/w")

      expect(output.string.lines.map(&:chomp)).to eq([
        "PR #41 Add x: 2 unresolved threads (0 outdated), 0 reviews with comments, 0 comments, 1 failing checks",
        "  lib/a.rb:12  rev: first [untrusted] [hidden html]",
        "  lib/a.rb  rev: Rename this.",
        "  failing check: rspec"
      ])
    end

    context "with hostile text" do
      let(:threads) { [thread(comments: [comment(body: "\e[2Jx‮y​z\u0085⁧", author: "a\rb")])] }
      let(:read_title) { "T\e]0;x\a" }

      it "escapes control, bidi and zero-width characters" do
        read["pull_request"]["title"] = read_title
        command.call(working_dir: "/w")

        expect(output.string).to include("\\e[2Jx\\u202Ey\\u200Bz\\u0085\\u2067", "a\\rb", "T\\e]0;x\\u0007")
        expect(output.string).not_to match(/[\e‮​\u0085\r\a]/)
      end
    end
  end

  context "with hostile names and ghost authors" do
    let(:failed) { [{"name" => "ci\e[31m‮", "url" => nil, "run_id" => 1}] }
    let(:threads) { [thread(comments: [comment(author: nil, body: "\e[2Jraw")]).merge("path" => "a​\e.rb")] }

    it "escapes the check name and path, and prints a ghost author as unknown" do
      command.call(working_dir: "/w")

      expect(output.string).to include("failing check: ci\\e[31m\\u202E", "a\\u200B\\e.rb:12  unknown: \\e[2Jraw")
      expect(output.string).not_to match(/[\e‮​]/)
    end

    it "leaves bodies raw under --json" do
      expect(document["threads"].first["comments"].first["body"]).to eq("\e[2Jraw")
      expect(document["threads"].first["comments"].first["author"]).to be_nil
    end
  end

  context "with a thread of several comments" do
    let(:threads) { [thread(comments: [comment, comment(trusted: false), comment(hidden_html: true)])] }

    it "tags the line when any comment is untrusted or hidden" do
      command.call(working_dir: "/w")

      expect(output.string).to include("Rename this. [untrusted] [hidden html]")
    end
  end

  context "with long thread and review bodies" do
    let(:threads) { [thread(comments: [comment(body: "t" * 4_001)])] }
    let(:reviews) { [comment(body: "r" * 4_001).merge("state" => "COMMENTED", "submitted_at" => "x")] }

    it "cuts each at 4,000 characters" do
      expect(document["threads"].first["comments"].first).to include("body_truncated" => true)
      expect(document["threads"].first["comments"].first["body"].length).to eq(4_000)
      expect(document["reviews"].first).to include("body_truncated" => true)
      expect(document["reviews"].first["body"].length).to eq(4_000)
    end
  end

  it "lets the reader's errors through" do
    allow(feedback).to receive(:call).and_raise(Workspace::Error.new("none", code: "no_pull_request"))

    expect { command.call(json: true, working_dir: "/w") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_pull_request") }
    expect(output.string).to eq("")
  end
end
