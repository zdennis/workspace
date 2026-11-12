require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::CLI::Common do
  subject(:common) { described_class.new }

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:invocation) do
    Workspace::CLI::Invocation.new(output: out, error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
  end

  def exit_status
    yield
    nil
  rescue FakeSystemExit => e
    e.status
  end

  describe "#run_action" do
    it "leaves text alone without --json and exits with the block's non-zero code" do
      status = exit_status do
        common.run_action(invocation, "stop", json: false) do
          out.puts("stopped app")
          {exit_code: 2}
        end
      end

      expect(status).to eq(2)
      expect(out.string).to eq("stopped app\n")
    end

    it "does not exit without --json when the block answers 0 or nil" do
      expect(exit_status { common.run_action(invocation, "stop", json: false) { {exit_code: 0} } }).to be_nil
      expect(exit_status { common.run_action(invocation, "stop", json: false) { nil } }).to be_nil
    end

    it "prints one action document with --json and sends the command's text to stderr" do
      gate = Workspace::OutputGate.new(out)
      run = invocation.with(output: gate)
      status = exit_status do
        common.run_action(run, "stop", json: true) do
          gate.puts("stopping app")
          {results: [common.action_row("app", "stopped")], warnings: ["careful"]}
        end
      end

      doc = JSON.parse(out.string)
      expect(status).to be_nil
      expect(doc).to include("ok" => true, "action" => "stop", "status" => "ok", "warnings" => ["careful"])
      expect(doc["results"]).to eq([{"workspace" => "app", "outcome" => "stopped", "reason" => nil, "message" => nil}])
      expect(err.string).to eq("stopping app\n")
    end

    it "exits 3 for a partial result and with the block's code for a failed one" do
      partial = [common.action_row("a", "stopped"), common.action_row("b", "failed")]
      expect(exit_status { common.run_action(invocation, "stop", json: true) { {results: partial} } }).to eq(3)
      expect(exit_status { common.run_action(invocation, "stop", json: true) { {results: [common.action_row("a", "stopped")], exit_code: 4} } }).to eq(4)
    end
  end

  describe "#run_row_action" do
    it "prints the row as the one result and exits 1 when it failed" do
      status = exit_status { common.run_row_action(invocation, "workflow run", json: true) { {"workspace" => "app", "outcome" => "failed"} } }

      expect(status).to eq(1)
      expect(JSON.parse(out.string)).to include("action" => "workflow run", "status" => "failed", "results" => [{"workspace" => "app", "outcome" => "failed"}])
    end

    it "marks a dry_run row and reports a nil row as cancelled" do
      common.run_row_action(invocation, "workflow run", json: true) { {"workspace" => "app", "outcome" => "dry_run"} }
      common.run_row_action(invocation, "workflow remove", json: true) { nil }

      expect(out.string.lines.map { |line| JSON.parse(line)["status"] }).to eq(["dry_run", "cancelled"])
    end
  end

  describe "#refuse_bad_bytes!" do
    it "retags the arguments as UTF-8" do
      args = ["caf\xC3\xA9".b]
      common.refuse_bad_bytes!(args)

      expect(args.first.encoding).to eq(Encoding::UTF_8)
    end

    it "names the flag before an argument that is not valid UTF-8, else says an argument" do
      expect { common.refuse_bad_bytes!(["--note", "\xFF".b]) }.to raise_error(Workspace::UsageError, /\A--note holds bytes that are not valid UTF-8 text/)
      expect { common.refuse_bad_bytes!(["\xFF".b]) }.to raise_error(Workspace::UsageError, /\AAn argument holds bytes/)
    end
  end

  describe "#exit_code_row" do
    it "answers the ok outcome on 0, else a failed row carrying the code" do
      expect(common.exit_code_row("app", "released", 0, lock: "edit"))
        .to eq({"workspace" => "app", "outcome" => "released", "reason" => nil, "message" => nil, "lock" => "edit"})
      expect(common.exit_code_row("app", "released", 2))
        .to eq({"workspace" => "app", "outcome" => "failed", "reason" => "exit_code", "message" => "Exited 2; the details are on stderr.", "exit_code" => 2})
    end
  end

  describe "#emit_json_error and #emit_json_usage_error" do
    it "print the error document to the invocation's output and exit 1" do
      error = Workspace::Error.new("no such run", code: "unknown_run")
      expect(exit_status { common.emit_json_error(invocation, 1, error) }).to eq(1)
      expect(JSON.parse(out.string)).to include("ok" => false, "error" => "no such run", "code" => "unknown_run")

      out.truncate(0)
      out.rewind
      expect(exit_status { common.emit_json_usage_error(invocation, 1, "bad option") }).to eq(1)
      expect(JSON.parse(out.string)).to include("ok" => false, "error" => "bad option", "code" => "usage")
    end
  end

  describe "#help_requested?" do
    it "counts --help and -h only before a bare --" do
      expect(common.help_requested?(["status", "--help"])).to be(true)
      expect(common.help_requested?(["status", "-h"])).to be(true)
      expect(common.help_requested?(["status", "--", "--help"])).to be(false)
    end

    it "reads the word after a flag that takes a value as that value" do
      page = Workspace::HelpPages::WORKFLOW.fetch("approve")
      expect(common.help_requested?(["approve", "--note", "--help"], page)).to be(false)
    end
  end

  describe "#verb_help_shown?" do
    it "prints the verb's page to the invocation's output when help is asked for" do
      expect(common.verb_help_shown?(invocation, Workspace::HelpPages::LOCK, ["acquire", "--help"])).to be(true)
      expect(out.string).to include("Usage: workspace lock acquire")
    end

    it "is false and prints nothing without a request" do
      expect(common.verb_help_shown?(invocation, Workspace::HelpPages::LOCK, ["acquire"])).to be(false)
      expect(out.string).to eq("")
    end
  end

  describe "#json_requested?" do
    it "is true for the flag already parsed or --json still among the arguments" do
      expect(common.json_requested?(true, [])).to be(true)
      expect(common.json_requested?(false, ["--bogus", "--json"])).to be(true)
      expect(common.json_requested?(false, ["--bogus"])).to be(false)
    end
  end

  describe "#parse_duration_option" do
    it "answers seconds and turns a bad value into a usage error naming the flag" do
      expect(common.parse_duration_option("--poll", "5m")).to eq(300)
      expect { common.parse_duration_option("--poll", "soon") }.to raise_error(Workspace::UsageError, /\A--poll: /)
      expect { common.parse_duration_option("--poll", "0", positive: true) }.to raise_error(Workspace::UsageError, /\A--poll: /)
    end
  end
  describe "#open_in_editor" do
    def build(env: {"EDITOR" => "vi"}, input: StringIO.new, interactive: -> { true }, launcher: ->(argv) { (@launched ||= []) << argv })
      @launched = []
      [described_class.new(input: input, editor_launcher: launcher, interactive: interactive),
        Workspace::CLI::Invocation.new(output: out, error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: env)]
    end

    it "runs $VISUAL ahead of $EDITOR as an argv array with every path, so no shell sees them" do
      editor, run = build(env: {"VISUAL" => "code --wait", "EDITOR" => "vi"})

      result = editor.open_in_editor(run, "/a b; rm -rf $HOME/project.yml", "/a b; rm -rf $HOME/worktree.yml")

      expect(@launched).to eq([["code", "--wait", "/a b; rm -rf $HOME/project.yml", "/a b; rm -rf $HOME/worktree.yml"]])
      expect(result).to be(true)
    end

    it "falls back to $EDITOR when $VISUAL is blank" do
      editor, run = build(env: {"VISUAL" => " ", "EDITOR" => "nano"})

      editor.open_in_editor(run, "/f.yml")

      expect(@launched).to eq([["nano", "/f.yml"]])
    end

    it "prints each path and opens nothing with no editor, off a terminal, or under --no-input" do
      no_editor, run = build(env: {})
      no_terminal, run_two = build(interactive: -> { false })
      no_input, run_three = build(input: Workspace::PromptInput.new(StringIO.new, no_input: true))

      results = [no_editor.open_in_editor(run, "/a.yml", "/b.yml"), no_terminal.open_in_editor(run_two, "/c.yml"), no_input.open_in_editor(run_three, "/d.yml")]

      expect(results).to eq([false, false, false])

      expect(out.string).to eq("/a.yml\n/b.yml\n/c.yml\n/d.yml\n")
      expect(@launched).to eq([])
    end

    it "raises editor_failed for an unbalanced quote and for an editor that fails" do
      editor, run = build(env: {"EDITOR" => 'vim "x'})
      expect { editor.open_in_editor(run, "/f.yml") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("editor_failed") }

      failing, run_two = build(launcher: ->(_argv) { false })
      expect { failing.open_in_editor(run_two, "/f.yml") }.to raise_error(Workspace::Error, /Could not run the editor 'vi'.*\/f.yml/) { |e| expect(e.details).to eq(path: "/f.yml", editor: "vi") }
    end
  end
end
