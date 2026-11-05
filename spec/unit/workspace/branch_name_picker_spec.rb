require "spec_helper"

RSpec.describe Workspace::BranchNamePicker do
  let(:commands) { instance_double(Workspace::AgentCommands, kind: "claude", executable_for: "/opt/claude") }
  let(:calls) { [] }
  let(:output) { "fix-login-redirect\n" }
  let(:runner) do
    lambda do |argv, **opts|
      calls << [argv, opts]
      [output, "", true]
    end
  end
  let(:enabled) { true }
  let(:override) { nil }
  let(:picker) do
    described_class.new(commands: commands, enabled: ->(_) { enabled }, timeout: ->(_) { 20 },
      command: ->(_) { override }, runner: runner)
  end

  def pick(text = "fix the login redirect") = picker.call(text: text, project: "proj", root: "/r")

  it "picks a sanitized name" do
    result = pick

    expect(result.name).to eq("fix-login-redirect")
    expect(result.reason).to be_nil
  end

  it "runs claude headless with no setting sources, the timeout and a size cap" do
    pick

    argv, opts = calls.first
    expect(argv.first(4)).to eq(["/opt/claude", "-p", "--setting-sources", ""])
    expect(opts).to include(timeout: 20, max_bytes: 64 * 1024)
  end

  it "puts the description in the last argv element, capped at 4,000 characters" do
    pick("needle " + "z" * 5000)

    prompt = calls.first.first.last
    expect(prompt).to include("needle")
    expect(prompt).to include("48 characters")
    expect(prompt.scan("z").size).to eq(4000 - "needle ".size)
  end

  context "with a command override" do
    let(:override) { "my-namer --fast 'a b'" }

    it "splits it into argv and appends the description as one element" do
      pick

      argv = calls.first.first
      expect(argv.first(3)).to eq(["my-namer", "--fast", "a b"])
      expect(argv.size).to eq(4)
      expect(argv.last).to include("fix the login redirect")
    end
  end

  it "is disabled without running anything" do
    result = described_class.new(commands: commands, enabled: ->(_) { false }, timeout: ->(_) { 20 },
      command: ->(_) {}, runner: runner).call(text: "x", project: "p", root: "/r")

    expect(result.reason).to eq(:disabled)
    expect(calls).to be_empty
  end

  it "reports no_agent for another agent kind without an override" do
    allow(commands).to receive(:kind).and_return("codex")

    expect(pick.reason).to eq(:no_agent)
    expect(calls).to be_empty
  end

  it "reports no_agent when the binary is missing" do
    picker = described_class.new(commands: commands, enabled: ->(_) { true }, timeout: ->(_) { 20 },
      command: ->(_) {}, runner: ->(*, **) { raise Errno::ENOENT })

    expect(picker.call(text: "x", project: "p", root: "/r").reason).to eq(:no_agent)
  end

  {Timeout::Error => :timeout, Workspace::TimedProcess::OutputTooLarge => :output_too_large,
   RuntimeError => :failed}.each do |error, reason|
    it "answers #{reason} when the runner raises #{error}" do
      picker = described_class.new(commands: commands, enabled: ->(_) { true }, timeout: ->(_) { 20 },
        command: ->(_) {}, runner: ->(*, **) { raise error })

      expect(picker.call(text: "x", project: "p", root: "/r").reason).to eq(reason)
    end
  end

  it "answers failed when the command exits non-zero" do
    picker = described_class.new(commands: commands, enabled: ->(_) { true }, timeout: ->(_) { 20 },
      command: ->(_) {}, runner: ->(*, **) { ["name", "", false] })

    expect(picker.call(text: "x", project: "p", root: "/r").reason).to eq(:failed)
  end

  context "with garbage output" do
    let(:output) { "́\n" }

    it "answers empty" do
      expect(pick.reason).to eq(:empty)
    end
  end

  context "with a long answer" do
    let(:output) { "Add-Retry-Backoff-To-The-Webhook-Delivery-Worker-Please\n" }

    it "cuts to 48 characters at a word boundary" do
      name = pick.name

      expect(name).to eq("add-retry-backoff-to-the-webhook-delivery-worker")
      expect(name.length).to be <= 48
    end
  end

  context "with an answer of exactly 48 characters" do
    let(:output) { "a" * 48 + "\n" }

    it "keeps it whole" do
      expect(pick.name).to eq("a" * 48)
    end
  end

  context "with a 49th character that is a dash" do
    let(:output) { "a" * 48 + "-" + "b" * 10 + "\n" }

    it "cuts before the dash" do
      expect(pick.name).to eq("a" * 48)
    end
  end

  context "with one long token and no dash" do
    let(:output) { "a" * 60 + "\n" }

    it "hard-cuts at 48" do
      expect(pick.name).to eq("a" * 48)
    end
  end

  it "normalizes accents, case and punctuation like StartRef.slug" do
    runner_out = "  Fix: Café_Ünïcode!! \n"
    picker = described_class.new(commands: commands, enabled: ->(_) { true }, timeout: ->(_) { 20 },
      command: ->(_) {}, runner: ->(*, **) { [runner_out, "", true] })

    expect(picker.call(text: "x", project: "p", root: "/r").name).to eq("fix-cafe-unicode")
  end

  it "runs in a fresh temp directory and unsets the pane and Claude environment" do
    parent_env = {"PATH" => "/bin", "CLAUDE_CODE_SESSION" => "s", "CLAUDE_FOO" => "1"}
    tmp = Class.new do
      attr_reader :dir

      def mktmpdir(*)
        @dir = "/fake/tmp"
        yield @dir
      end
    end.new
    picker = described_class.new(commands: commands, enabled: ->(_) { true }, timeout: ->(_) { 20 },
      command: ->(_) {}, runner: runner, tmpdir: tmp, env: parent_env)

    picker.call(text: "x", project: "p", root: "/r")

    _, opts = calls.first
    expect(opts[:chdir]).to eq("/fake/tmp")
    # The nil values unset over the env the child inherits, so this map is the whole contract.
    expect(opts[:env]).to eq("TMUX_PANE" => nil, "TMUX" => nil, "CLAUDECODE" => nil,
      "CLAUDE_CODE_SESSION" => nil, "CLAUDE_FOO" => nil)
  end

  it "hands the project to the config readers" do
    seen = []
    picker = described_class.new(commands: commands, enabled: ->(p) { seen << p },
      timeout: ->(_) { 20 }, command: ->(_) {}, runner: runner)
    picker.call(text: "x", project: "proj", root: "/r")

    expect(seen).to eq(["proj"])
  end

  it "falls back to the injected slugger" do
    picker = described_class.new(commands: commands, enabled: ->(_) { true }, timeout: ->(_) { 20 },
      command: ->(_) {}, runner: runner, slug: ->(_text) { "slugged" })

    expect(picker.fallback("any text")).to eq("slugged")
  end
end
