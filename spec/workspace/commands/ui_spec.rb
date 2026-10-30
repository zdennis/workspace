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
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  subject(:command) { described_class.new(opener: opener, output: output, notes: notes) }

  describe "#url_for" do
    it "builds a task, review and inbox link" do
      expect(command.url_for(view: "task", workspace: "my-app")).to eq("workspace-ui://task/my-app")
      expect(command.url_for(view: "review", workspace: "my-app.worktree-fix")).to eq("workspace-ui://review/my-app.worktree-fix")
      expect(command.url_for(view: "inbox")).to eq("workspace-ui://inbox")
    end

    it "builds a notes link that names the workspace, percent-encoded like task" do
      expect(command.url_for(view: "notes", workspace: "my-app.worktree-fix")).to eq("workspace-ui://notes/my-app.worktree-fix")
      expect(command.url_for(view: "notes", workspace: "a b/c")).to eq("workspace-ui://notes/a%20b%2Fc")
    end

    it "builds a plan link like notes and refuses a pane" do
      expect(command.url_for(view: "plan", workspace: "my-app.worktree-fix")).to eq("workspace-ui://plan/my-app.worktree-fix")
      expect { command.url_for(view: "plan") }.to raise_error(Workspace::UsageError, /plan needs a workspace/)
      expect { command.url_for(view: "plan", workspace: "x", pane: "%1") }.to raise_error(Workspace::UsageError, /plan takes no pane/)
      expect { command.url_for(view: "inbox", pane: "%1") }.to raise_error(Workspace::UsageError, /inbox takes no pane/)
    end

    it "builds a pane link with the workspace and the pane id percent-encoded" do
      expect(command.url_for(view: "pane", workspace: "my-app", pane: "%19")).to eq("workspace-ui://pane/my-app/%2519")
      expect(command.url_for(view: "pane", workspace: "a b", pane: "%0")).to eq("workspace-ui://pane/a%20b/%250")
    end

    it "requires a tmux pane id for pane" do
      expect { command.url_for(view: "pane", workspace: "x") }.to raise_error(Workspace::UsageError, /pane needs a pane id/)
      ["19", "%", "%a", "%1/2", "%19 ", "%1\n2", "0.1", "%1234567890"].each do |bad|
        expect { command.url_for(view: "pane", workspace: "x", pane: bad) }.to raise_error(Workspace::UsageError, /not a tmux pane id/), bad.inspect
      end
    end

    it "treats a blank pane as missing and prints a pane link under print_only" do
      expect { command.url_for(view: "pane", workspace: "x", pane: "  ") }.to raise_error(Workspace::UsageError, /pane needs a pane id/)
      result = command.open(view: "pane", workspace: "x", pane: "%3", print_only: true)
      expect(result).to have_attributes(outcome: "printed", url: "workspace-ui://pane/x/%253")
      expect(opener.calls).to eq([])
    end

    it "opens a pane link through open" do
      command.open(view: "pane", workspace: "x", pane: "%3")
      expect(opener.calls).to eq([["open", "workspace-ui://pane/x/%253"]])
    end

    it "requires a workspace for notes" do
      expect { command.url_for(view: "notes") }.to raise_error(Workspace::UsageError, /notes needs a workspace/)
    end

    it "percent-encodes everything but unreserved characters" do
      expect(command.url_for(view: "task", workspace: "a b/c?d#e%f")).to eq("workspace-ui://task/a%20b%2Fc%3Fd%23e%25f")
    end

    it "rejects an unknown view, naming the valid ones" do
      expect { command.url_for(view: "settings", workspace: "x") }
        .to raise_error(Workspace::UsageError, /Unknown view 'settings'.*task, review, notes, plan, pane, inbox.*workspace ui --help/)
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

  describe "notes --path" do
    let(:dir) { Dir.mktmpdir }
    before do
      allow(notes).to receive(:info).with(name: "app").and_return({"dir" => dir})
      FileUtils.mkdir_p(File.join(dir, "research"))
      File.write(File.join(dir, "research", "findings.md"), "x")
      File.write(File.join(dir, "a.md"), "x")
    end

    after { FileUtils.remove_entry(dir) }

    it "builds a notes link that ends in the checked path" do
      expect(command.url_for(view: "notes", workspace: "app", path: "research/findings.md")).to eq("workspace-ui://notes/app/research/findings.md")
    end

    it "prints the link and opens nothing under print_only" do
      result = command.open(view: "notes", workspace: "app", path: "a.md", print_only: true)
      expect(result).to have_attributes(outcome: "printed", url: "workspace-ui://notes/app/a.md")
      expect(output.string).to eq("workspace-ui://notes/app/a.md\n")
      expect(opener.calls).to eq([])
    end

    it "refuses a missing file with invalid_note_path and its details" do
      expect { command.url_for(view: "notes", workspace: "app", path: "nope.md") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("invalid_note_path")
        expect(e.details).to eq("workspace" => "app", "path" => "nope.md", "reason" => "no such file in the notes directory")
      }
    end

    it "refuses a badly shaped path and a symlink" do
      File.symlink(File.join(dir, "a.md"), File.join(dir, "link.md"))
      ["../a.md", "/a.md", "a.txt", "link.md", "my note.md"].each do |bad|
        expect { command.url_for(view: "notes", workspace: "app", path: bad) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_note_path") }, bad
      end
    end

    it "refuses --path on every other view" do
      %w[task review plan].each do |view|
        expect { command.url_for(view: view, workspace: "app", path: "a.md") }.to raise_error(Workspace::UsageError, /takes no --path/)
      end
      expect { command.url_for(view: "inbox", path: "a.md") }.to raise_error(Workspace::UsageError, /inbox takes no --path/)
      expect { command.url_for(view: "pane", workspace: "app", pane: "%1", path: "a.md") }.to raise_error(Workspace::UsageError, /takes no --path/)
    end

    it "cuts details.path to 200 characters for a long bad path" do
      expect { command.url_for(view: "notes", workspace: "app", path: "#{"a" * 300}.md") }.to raise_error(Workspace::Error) { |e|
        expect(e.details["path"].length).to eq(200)
      }
    end

    it "is wired with the notes command by build_cli" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {})
      ui = cli.instance_variable_get(:@ui_command)
      expect(ui.instance_variable_get(:@notes)).to be_a(Workspace::Commands::Notes)
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
      result = described_class.new(opener: failing, output: output, notes: notes).open(view: "inbox")

      expect(result).to have_attributes(outcome: "failed", reason: "open_failed")
      expect(result.message).to include("-10814").and include("workspace-ui://inbox").and include("UI app installed").and include("--print")
      expect(result).not_to be_ok
      expect(output.string).to eq("")
    end

    it "reports a missing `open` executable as a failed row" do
      result = described_class.new(opener: UiFakeOpener.new(missing: true), output: output, notes: notes).open(view: "inbox")

      expect(result).to have_attributes(outcome: "failed", reason: "open_unavailable")
      expect(result.message).to include("open")
    end
  end
end
