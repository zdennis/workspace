require "spec_helper"
require "stringio"

# Behaves like `open URL`: [stdout, stderr, status], raising Errno::ENOENT when `open` is missing.
class UiFakeOpener
  attr_reader :calls

  def initialize(status: 0, stderr: "", missing: false)
    @calls = []
    @status = status
    @stderr = stderr
    @missing = missing
  end

  def call(argv)
    @calls << argv
    raise Errno::ENOENT, argv.first if @missing
    ["", @stderr, Struct.new(:exitstatus) { def success? = exitstatus.zero? }.new(@status)]
  end
end

RSpec.describe Workspace::Commands::Ui do
  let(:opener) { UiFakeOpener.new }
  let(:output) { StringIO.new }
  subject(:command) { described_class.new(opener: opener, output: output) }

  describe "#url_for" do
    it "builds a task, review and inbox link" do
      expect(command.url_for(view: "task", workspace: "my-app")).to eq("workspace-ui://task/my-app")
      expect(command.url_for(view: "review", workspace: "my-app.worktree-fix")).to eq("workspace-ui://review/my-app.worktree-fix")
      expect(command.url_for(view: "inbox")).to eq("workspace-ui://inbox")
    end

    it "percent-encodes everything but unreserved characters" do
      expect(command.url_for(view: "task", workspace: "a b/c?d#e%f")).to eq("workspace-ui://task/a%20b%2Fc%3Fd%23e%25f")
    end

    it "rejects an unknown view, naming the valid ones" do
      expect { command.url_for(view: "settings", workspace: "x") }
        .to raise_error(Workspace::UsageError, /Unknown view 'settings'.*task, review, inbox.*workspace ui --help/)
    end

    it "requires a workspace for task and review" do
      expect { command.url_for(view: "task") }.to raise_error(Workspace::UsageError, /task needs a workspace/)
      expect { command.url_for(view: "review", workspace: "  ") }.to raise_error(Workspace::UsageError, /review needs a workspace/)
    end

    it "refuses a workspace for inbox" do
      expect { command.url_for(view: "inbox", workspace: "x") }.to raise_error(Workspace::UsageError, /inbox takes no workspace/)
    end

    it "rejects control characters and over-long names" do
      expect { command.url_for(view: "task", workspace: "a\nb") }.to raise_error(Workspace::UsageError, /not a valid workspace name/)
      expect { command.url_for(view: "task", workspace: "a" * 256) }.to raise_error(Workspace::UsageError, /not a valid workspace name/)
    end
  end

  describe "#open" do
    it "hands the URL to `open` as one argv element" do
      result = command.open(view: "task", workspace: "my-app")

      expect(opener.calls).to eq([["open", "workspace-ui://task/my-app"]])
      expect(result).to have_attributes(outcome: "opened", url: "workspace-ui://task/my-app", view: "task")
      expect(result).to be_ok
      expect(output.string).to eq("Opened workspace-ui://task/my-app\n")
    end

    it "prints the URL and opens nothing with print_only" do
      result = command.open(view: "inbox", print_only: true)

      expect(opener.calls).to eq([])
      expect(result.outcome).to eq("printed")
      expect(output.string).to eq("workspace-ui://inbox\n")
    end

    it "never lets a workspace name become an option or a second argument" do
      command.open(view: "task", workspace: "--help; rm -rf /")

      expect(opener.calls.size).to eq(1)
      expect(opener.calls.first.size).to eq(2)
      expect(opener.calls.first.last).to start_with("workspace-ui://task/")
    end

    it "reports no registered handler as a failed row with open's own message" do
      failing = UiFakeOpener.new(status: 1, stderr: "LSOpenURLsWithRole() failed with error -10814 for the URL workspace-ui://inbox.\n")
      result = described_class.new(opener: failing, output: output).open(view: "inbox")

      expect(result).to have_attributes(outcome: "failed", reason: "open_failed")
      expect(result.message).to include("-10814").and include("workspace-ui://inbox").and include("UI app installed").and include("--print")
      expect(result).not_to be_ok
      expect(output.string).to eq("")
    end

    it "reports a missing `open` executable as a failed row" do
      result = described_class.new(opener: UiFakeOpener.new(missing: true), output: output).open(view: "inbox")

      expect(result).to have_attributes(outcome: "failed", reason: "open_unavailable")
      expect(result.message).to include("open")
    end
  end
end
