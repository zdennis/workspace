require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

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

    it "is wired with the notes command by build_cli, so a note path is checked against the real notes directory" do
      Dir.mktmpdir("workspace-ui-wiring") do |home|
        saved = ENV.to_h
        begin
          ENV.replace("HOME" => home, "PATH" => ENV["PATH"])
          project = File.join(home, "proj")
          FileUtils.mkdir_p(File.join(project, "tmp", "workspace-notes"))
          system("git", "init", "-q", project, out: File::NULL, err: File::NULL)
          File.write(File.join(project, "tmp", "workspace-notes", "a.md"), "hi")
          run = lambda do |*args|
            out = StringIO.new
            begin
              Workspace.build_cli(output: out, error_output: StringIO.new, input: StringIO.new, env: {}).run(args)
            rescue SystemExit
              nil
            end
            out.string
          end
          run.call("init")
          run.call("add", project)

          expect(run.call("ui", "open", "notes", "proj", "--path", "a.md", "--print")).to eq("workspace-ui://notes/proj/a.md\n")
        ensure
          ENV.replace(saved)
        end
      end
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

    describe "#status" do
      require "tmpdir"
      require "fileutils"

      let(:tmp) { Dir.mktmpdir }
      let(:probe) { instance_double(Workspace::UiAppProbe) }
      let(:command) { described_class.new(opener: opener, output: output, notes: notes, app_probe: probe) }
      let(:handler_id) { "com.zdennis.workspace-ui" }

      after { FileUtils.remove_entry(tmp) }

      def bundle(name = "WorkspaceUI.app", mtime: Time.at(1_700_000_000))
        dir = File.join(tmp, name)
        FileUtils.mkdir_p(File.join(dir, "Contents"))
        plist = File.join(dir, "Contents", "Info.plist")
        File.write(plist, "x")
        File.utime(mtime, mtime, plist)
        dir
      end

      def answer(handler: nil, running: [], problem: nil)
        allow(probe).to receive(:call).and_return(Workspace::UiAppProbe::Answer.new(handler, running, problem))
      end

      def handler_at(path, id: handler_id, revision: 2)
        Workspace::UiAppProbe::Handler.new(path, id, "0.30.1", revision)
      end

      def running_at(path, launched_at: Time.at(1_800_000_000), pid: 41)
        Workspace::UiAppProbe::Running.new(pid, path, launched_at)
      end

      it "reports a revision with no reason when the handler is the declaring bundle and nothing runs" do
        answer(handler: handler_at(bundle))

        doc = command.status
        expect(doc).to include("running" => false, "pids" => [], "probe" => nil, "warnings" => [])
        expect(doc["handler"]).to eq("path" => File.join(tmp, "WorkspaceUI.app"), "id" => handler_id, "version" => "0.30.1")
        expect(doc["links"]).to eq("revision" => 2, "reason" => nil)
      end

      it "keeps the revision when the running copy is the handler through a symlink and started after the bundle" do
        real = bundle
        link = File.join(tmp, "Link.app")
        File.symlink(real, link)
        answer(handler: handler_at(link), running: [running_at(real)])

        doc = command.status
        expect(doc).to include("running" => true, "pids" => [41])
        expect(doc["links"]).to eq("revision" => 2, "reason" => nil)
      end

      it "answers probe_failed with null running, pids and handler for each probe problem" do
        %i[timed_out unavailable bad_answer].each do |problem|
          answer(problem: problem)

          expect(command.status).to include("running" => nil, "pids" => nil, "handler" => nil, "probe" => problem.to_s,
            "links" => {"revision" => nil, "reason" => "probe_failed"})
        end
      end

      it "answers no_handler" do
        answer(handler: nil, running: [running_at("/x")])

        expect(command.status).to include("handler" => nil, "running" => true, "links" => {"revision" => nil, "reason" => "no_handler"})
      end

      it "answers foreign_handler for another bundle id, before looking at the files" do
        answer(handler: handler_at("/nonexistent", id: "com.example.other"))

        expect(command.status["links"]["reason"]).to eq("foreign_handler")
      end

      it "answers handler_unreadable for a nil path, a removed bundle and a bundle with no Info.plist" do
        empty = File.join(tmp, "Empty.app")
        FileUtils.mkdir_p(empty)
        [nil, File.join(tmp, "Gone.app"), empty].each do |path|
          answer(handler: handler_at(path))

          expect(command.status["links"]).to eq("revision" => nil, "reason" => "handler_unreadable")
        end
      end

      it "answers handler_unreadable ahead of handler_differs" do
        answer(handler: handler_at(File.join(tmp, "Gone.app")), running: [running_at(bundle)])

        expect(command.status["links"]["reason"]).to eq("handler_unreadable")
      end

      it "answers handler_differs for a running copy elsewhere, with a nil path or gone, even if another copy matches" do
        here = bundle
        other = bundle("Other.app")
        [other, nil, File.join(tmp, "Gone.app")].each do |path|
          answer(handler: handler_at(here), running: [running_at(here), running_at(path, pid: 42)])

          expect(command.status["links"]).to eq("revision" => nil, "reason" => "handler_differs")
        end
      end

      it "answers launch_unknown for a running copy with no launch time, ahead of app_older_than_bundle" do
        here = bundle
        answer(handler: handler_at(here), running: [running_at(here, launched_at: nil), running_at(here, launched_at: Time.at(1), pid: 42)])

        expect(command.status["links"]["reason"]).to eq("launch_unknown")
      end

      it "answers app_older_than_bundle when a running copy started before Info.plist changed" do
        here = bundle(mtime: Time.at(1_800_000_000))
        answer(handler: handler_at(here), running: [running_at(here, launched_at: Time.at(1_700_000_000))])

        expect(command.status["links"]).to eq("revision" => nil, "reason" => "app_older_than_bundle")
      end

      it "answers not_declared when the bundle has no link revision" do
        answer(handler: handler_at(bundle, revision: nil))

        expect(command.status["links"]).to eq("revision" => nil, "reason" => "not_declared")
      end

      it "applies no launch check when nothing runs" do
        answer(handler: handler_at(bundle(mtime: Time.at(4_000_000_000))))

        expect(command.status["links"]["revision"]).to eq(2)
      end

      it "never calls open" do
        answer(handler: handler_at(bundle))
        command.status

        expect(opener.calls).to be_empty
      end

      describe "#status_lines" do
        it "prints three lines for a running handler" do
          here = bundle
          answer(handler: handler_at(here), running: [running_at(here)])

          expect(command.status_lines(command.status)).to eq([
            "running: yes (pid 41)",
            "handler: #{here} (#{handler_id} 0.30.1)",
            "links: revision 2"
          ])
        end

        it "prints the absent handler and the reason" do
          answer(handler: nil)

          expect(command.status_lines(command.status)).to eq([
            "running: no", "handler: none (no app takes workspace-ui:// links)", "links: no revision (no_handler)"
          ])
        end

        it "prints unknown when the probe has no answer" do
          answer(problem: :timed_out)

          expect(command.status_lines(command.status)).to eq([
            "running: unknown (timed_out)", "handler: unknown", "links: no revision (probe_failed)"
          ])
        end

        it "escapes control characters in values read from macOS" do
          doc = {"pids" => [], "probe" => nil, "links" => {"revision" => nil, "reason" => "not_declared"},
                 "handler" => {"path" => "/a\e[2Jb", "id" => handler_id, "version" => "1\n2"}}

          expect(command.status_lines(doc)[1]).to eq("handler: /a\\e[2Jb (#{handler_id} 1\\n2)")
        end
      end
    end
  end
end
