require "spec_helper"
require "json"

RSpec.describe Workspace::TicketSource do
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:resolver) { Workspace::StartRef.new(git: git, lineage: Workspace::WorkspaceLineage.new) }
  let(:calls) { [] }
  let(:reply) { ["{}", "", true] }
  let(:runner) do
    lambda do |argv, chdir:, timeout:|
      calls << {argv: argv, chdir: chdir, timeout: timeout}
      reply.respond_to?(:call) ? reply.call : reply
    end
  end
  let(:present) { ->(_exe) { true } }
  subject(:source) { described_class.new(runner: runner, which: present, timeout: 3) }

  def fetch(input) = source.fetch(resolver.call(input), chdir: "/repo")

  def failure_of(input)
    fetch(input)
    nil
  rescue Workspace::Error => e
    e
  end

  describe "a pull request" do
    let(:reply) { [JSON.generate("title" => "Add x", "body" => "Because.", "url" => "https://github.com/o/r/pull/41"), "", true] }

    it "reads the title, body and URL with gh, in the checkout and within the time limit" do
      expect(fetch("https://github.com/o/r/pull/41")).to eq("title" => "Add x", "body" => "Because.", "url" => "https://github.com/o/r/pull/41")

      expect(calls).to eq([{argv: %w[gh pr view 41 --repo o/r --json title,body,url], chdir: "/repo", timeout: 3}])
    end

    it "leaves --repo out for a bare #n, so gh uses the repository it runs in" do
      fetch("#41")

      expect(calls.first[:argv]).to eq(%w[gh pr view 41 --json title,body,url])
    end
  end

  describe "an issue" do
    let(:reply) { [JSON.generate("title" => "Bug", "body" => nil, "url" => "https://github.com/o/r/issues/42"), "", true] }

    it "reads it with gh issue view and keeps a missing body as nil" do
      expect(fetch("https://github.com/o/r/issues/42")).to include("title" => "Bug", "body" => nil)

      expect(calls.first[:argv]).to eq(%w[gh issue view 42 --repo o/r --json title,body,url])
    end

    it "reads an issue whose repository was not parsed from the repository gh runs in" do
      allow(git).to receive(:parse_start_input).and_return({type: :issue_url, value: "issue-42"})

      fetch("whatever")

      expect(calls.first[:argv]).to eq(%w[gh issue view 42 --json title,body,url])
    end
  end

  describe "the body limit" do
    it "cuts the body to 64 KB without splitting a character" do
      body = "é" * 40_000
      allow(runner).to receive(:call).and_return([JSON.generate("title" => "t", "body" => body, "url" => "u"), "", true])

      result = fetch("#41")

      expect(result["body"].bytesize).to be <= 65_536
      expect(result["body"]).to be_valid_encoding
      expect(result["body"].bytesize).to be > 65_000
    end

    it "keeps a short body whole" do
      allow(runner).to receive(:call).and_return([JSON.generate("title" => "t", "body" => "ok", "url" => "u"), "", true])

      expect(fetch("#41")["body"]).to eq("ok")
    end
  end

  describe "a branch" do
    it "has nothing to look up, so nothing runs" do
      expect(fetch("feature/x")).to eq("title" => nil, "body" => nil, "url" => nil)
      expect(calls).to be_empty
    end
  end

  describe "a JIRA key" do
    let(:issue) { {"key" => "PROJ-123", "self" => "https://acme.atlassian.net/rest/api/2/issue/10001", "fields" => {"summary" => "Fix it", "description" => "Details"}} }
    let(:reply) { [JSON.generate(issue), "", true] }

    it "reads it with the jira command" do
      expect(fetch("PROJ-123")).to eq("title" => "Fix it", "body" => "Details", "url" => "https://acme.atlassian.net/browse/PROJ-123")

      expect(calls.first[:argv]).to eq(%w[jira issue view PROJ-123 --raw])
    end

    it "turns a rich-text description into plain text" do
      issue["fields"]["description"] = {"type" => "doc", "content" => [
        {"type" => "paragraph", "content" => [{"type" => "text", "text" => "First"}, {"type" => "hardBreak"}, {"type" => "text", "text" => "line"}]},
        {"type" => "paragraph", "content" => [{"type" => "text", "text" => "Second"}]}
      ]}

      expect(fetch("PROJ-123")["body"]).to eq("First\nline\nSecond")
    end

    it "ignores rich-text content that is not a node" do
      issue["fields"]["description"] = {"type" => "doc", "content" => ["stray", {"type" => "paragraph", "content" => [{"type" => "text", "text" => "Only"}]}]}

      expect(fetch("PROJ-123")["body"]).to eq("Only")
    end

    it "has no title when the reply carries no fields" do
      issue.delete("fields")

      expect(fetch("PROJ-123")).to include("title" => nil, "body" => nil)
    end

    it "has no URL or body when the reply gives neither" do
      issue.delete("self")
      issue["fields"].delete("description")

      expect(fetch("PROJ-123")).to eq("title" => "Fix it", "body" => nil, "url" => nil)
    end

    it "has no URL when self is not a URL" do
      issue["self"] = "not a url"

      expect(fetch("PROJ-123")["url"]).to be_nil
    end

    it "has no URL when self has no host" do
      issue["self"] = "/rest/api/2/issue/1"

      expect(fetch("PROJ-123")["url"]).to be_nil
    end

    it "calls a reply that is not an issue unreadable" do
      allow(runner).to receive(:call).and_return(["[]", "", true])

      expect(failure_of("PROJ-123")).to have_attributes(code: "ticket_source_unavailable", details: {"source" => "jira", "reason" => "error", "detail" => "unreadable reply from jira"})
    end
  end

  describe "when the tool cannot answer" do
    it "says the tool is missing when it is not on the PATH, and runs nothing" do
      absent = described_class.new(runner: runner, which: ->(_exe) { false })

      error = begin
        absent.fetch(resolver.call("#41"), chdir: "/repo")
      rescue Workspace::Error => e
        e
      end

      expect(error).to have_attributes(code: "ticket_source_unavailable", details: {"source" => "gh", "reason" => "missing"})
      expect(calls).to be_empty
    end

    it "says the tool is missing when starting it fails with ENOENT" do
      allow(runner).to receive(:call).and_raise(Errno::ENOENT)

      expect(failure_of("PROJ-123")).to have_attributes(code: "ticket_source_unavailable", details: {"source" => "jira", "reason" => "missing"})
    end

    it "reports a timeout" do
      allow(runner).to receive(:call).and_raise(Timeout::Error)

      expect(failure_of("#41")).to have_attributes(code: "ticket_source_unavailable", details: {"source" => "gh", "reason" => "timeout"})
    end

    it "reports the first line of what the tool said when it failed" do
      allow(runner).to receive(:call).and_return(["", "To get started with GitHub CLI, run: gh auth login\nmore", false])

      error = failure_of("#41")

      expect(error.code).to eq("ticket_source_unavailable")
      expect(error.details).to eq("source" => "gh", "reason" => "error", "detail" => "To get started with GitHub CLI, run: gh auth login")
    end

    it "reports a reply that is not JSON" do
      allow(runner).to receive(:call).and_return(["oops", "", true])

      expect(failure_of("#41").details).to include("reason" => "error", "detail" => "unreadable reply from gh")
    end

    it "reports a reply that is not an object" do
      allow(runner).to receive(:call).and_return(["[1]", "", true])

      expect(failure_of("#41").details).to include("detail" => "unreadable reply from gh")
    end
  end

  describe "when the ticket does not exist" do
    [
      ["gh", "#41", "GraphQL: Could not resolve to a PullRequest with the number of 41. (repository.pullRequest)"],
      ["gh", "#41", "HTTP 404: Not Found (https://api.github.com/repos/o/r/pulls/41)"],
      ["jira", "PROJ-123", "Error: Issue does not exist or you do not have permission to see it."]
    ].each do |tool, input, text|
      it "is ticket_not_found for #{tool}: #{text[0, 30]}" do
        allow(runner).to receive(:call).and_return(["", text, false])

        expect(failure_of(input)).to have_attributes(code: "ticket_not_found", details: {"source" => tool, "ref" => input})
      end
    end
  end

  describe "when the network fails" do
    it "is unavailable, not a missing ticket, even when the text says could not resolve or not found" do
      ["Post \"https://api.github.com/graphql\": dial tcp: lookup api.github.com: Could not resolve host", "jira: command not found"].each do |text|
        allow(runner).to receive(:call).and_return(["", text, false])

        expect(failure_of("#41")).to have_attributes(code: "ticket_source_unavailable"), text
      end
    end
  end

  describe "#list" do
    let(:gh_issues) { [{"number" => 7, "title" => "Crash\non start\e[1m", "url" => "https://github.com/o/r/issues/7", "state" => "OPEN", "updatedAt" => "2026-10-16T09:00:00Z"}] }
    let(:gh_prs) { [{"number" => 9, "title" => "Add x", "url" => "https://github.com/o/r/pull/9", "state" => "OPEN", "updatedAt" => "2026-10-17T13:00:00Z"}] }
    let(:jira_issues) do
      [{"key" => "PROJ-1", "self" => "https://acme.atlassian.net/rest/api/2/issue/10001",
        "fields" => {"summary" => "Fix login", "status" => {"name" => "In Progress"}, "updated" => "2026-10-17T14:30:00.000+0200"}}]
    end
    let(:replies) { {"issue" => JSON.generate(gh_issues), "pr" => JSON.generate(gh_prs), "jira" => JSON.generate(jira_issues)} }
    let(:runner) do
      lambda do |argv, chdir:, timeout:|
        calls << {argv: argv, chdir: chdir, timeout: timeout}
        reply = replies.fetch((argv[0] == "jira") ? "jira" : argv[1])
        reply.is_a?(Proc) ? reply.call : [reply, "", true]
      end
    end

    def list(**options) = source.list(filter: "assigned", limit: 20, chdir: "/repo", **options)

    it "reads gh issues, gh pull requests and jira in the checkout, within the time limit, with the assigned filter" do
      list

      expect(calls.map { |c| c[:argv] }).to contain_exactly(
        %w[gh issue list --state open --limit 20 --json number,title,url,state,updatedAt --assignee @me],
        %w[gh pr list --state open --limit 20 --json number,title,url,state,updatedAt --assignee @me],
        ["jira", "issue", "list", "-q", "assignee = currentUser() AND resolution = Unresolved", "--order-by", "updated", "--raw", "--paginate", "0:20"]
      )
      expect(calls.map { |c| [c[:chdir], c[:timeout]] }.uniq).to eq([["/repo", 3]])
    end

    it "asks for recently changed tickets for the recent filter" do
      source.list(filter: "recent", limit: 5, chdir: "/repo")

      argvs = calls.map { |c| c[:argv] }
      expect(argvs).to include(%w[gh issue list --state open --limit 5 --json number,title,url,state,updatedAt --search sort:updated-desc])
      expect(argvs.find { |a| a[0] == "jira" }).to include("updated >= -14d", "0:5")
    end

    it "returns rows from every source, newest first, as one line of plain text each" do
      rows = list["rows"]

      expect(rows.map { |r| r["ref"] }).to eq(["https://github.com/o/r/pull/9", "PROJ-1", "https://github.com/o/r/issues/7"])
      expect(rows[1]).to eq("ref" => "PROJ-1", "kind" => "jira", "source" => "jira", "title" => "Fix login",
        "url" => "https://acme.atlassian.net/browse/PROJ-1", "state" => "In Progress", "updated_at" => "2026-10-17T14:30:00.000+0200")
      expect(rows[2]).to include("kind" => "github_issue", "source" => "gh", "state" => "open", "title" => "Crash on start [1m")
    end

    it "cuts the merged rows to the limit" do
      expect(source.list(filter: "assigned", limit: 2, chdir: "/repo")["rows"].size).to eq(2)
    end

    it "asks only the sources named" do
      list(sources: ["jira"])

      expect(calls.map { |c| c[:argv][0] }).to eq(["jira"])
    end

    it "reads a jira reply that wraps the issues in an object" do
      replies["jira"] = JSON.generate("issues" => jira_issues)

      expect(list(sources: ["jira"])["rows"].map { |r| r["ref"] }).to eq(["PROJ-1"])
    end

    it "leaves out a row with no URL or key" do
      replies["issue"] = JSON.generate([{"number" => 1, "title" => "x"}])
      replies["jira"] = JSON.generate([{"fields" => {}}])

      expect(list["rows"].map { |r| r["ref"] }).to eq(["https://github.com/o/r/pull/9"])
    end

    it "makes a missing tool one warning and keeps the other rows" do
      source = described_class.new(runner: runner, which: ->(exe) { exe != "gh" }, timeout: 3)

      result = source.list(filter: "assigned", limit: 20, chdir: "/repo")

      expect(result["rows"].map { |r| r["source"] }).to eq(["jira"])
      expect(result["warnings"]).to eq([{"source" => "gh", "code" => "ticket_source_unavailable", "reason" => "missing", "message" => "`gh` is not installed."}])
    end

    it "makes a timeout, a failure and an unreadable reply warnings, never a raise" do
      replies["issue"] = -> { raise Timeout::Error }
      replies["pr"] = -> { ["", "gh: To get started with GitHub CLI, please run: gh auth login\nmore", false] }
      replies["jira"] = "not json"

      result = list

      expect(result["rows"]).to eq([])
      expect(result["warnings"]).to contain_exactly(
        include("source" => "gh", "reason" => "timeout", "message" => "`gh` did not answer in time."),
        include("source" => "gh", "reason" => "error", "detail" => "gh: To get started with GitHub CLI, please run: gh auth login"),
        include("source" => "jira", "reason" => "error", "detail" => "unreadable reply from jira")
      )
    end

    it "says a missing gh once, though it is asked twice" do
      source = described_class.new(runner: runner, which: ->(exe) { exe != "gh" }, timeout: 3)

      expect(source.list(filter: "assigned", limit: 20, chdir: "/repo", sources: ["gh"])["warnings"].size).to eq(1)
    end

    it "treats a jira reply that is a bare string or null as an unreadable reply" do
      ['"x"', "null", "3"].each do |reply|
        replies["jira"] = reply

        expect(list(sources: ["jira"])).to include("rows" => [], "warnings" => [include("source" => "jira", "reason" => "error")]), reply
      end
    end

    it "treats a reply that is not a list as an unreadable reply" do
      replies["issue"] = JSON.generate("oops" => 1)

      expect(list(sources: ["gh"])["warnings"]).to include(include("reason" => "error", "detail" => "unreadable reply from gh"))
    end
  end

  describe ".run" do
    it "returns what the command printed and whether it succeeded" do
      expect(described_class.run(["sh", "-c", "echo out; echo err >&2"], chdir: Dir.pwd, timeout: 5)).to eq(["out\n", "err\n", true])
    end

    it "reports a failing command" do
      expect(described_class.run(["sh", "-c", "exit 3"], chdir: Dir.pwd, timeout: 5).last).to be(false)
    end

    it "stops a command that runs past the limit" do
      expect { described_class.run(["sh", "-c", "sleep 5"], chdir: Dir.pwd, timeout: 0.2) }.to raise_error(Timeout::Error)
    end

    it "raises ENOENT for a command that does not exist" do
      expect { described_class.run(["workspace-no-such-tool"], chdir: Dir.pwd, timeout: 1) }.to raise_error(Errno::ENOENT)
    end
  end
end
