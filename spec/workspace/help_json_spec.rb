require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::HelpJson do
  describe ".strip" do
    it "removes --json when a help word and --json are both given, in either order" do
      expect(described_class.strip(["plan", "show", "--help", "--json"])).to eq(["plan", "show", "--help"])
      expect(described_class.strip(["--json", "plan", "-h"])).to eq(["plan", "-h"])
    end

    it "treats `help` as the first word like --help" do
      expect(described_class.strip(["help", "--json"])).to eq(["help"])
    end

    it "is nil with only one of the two" do
      expect(described_class.strip(["plan", "--help"])).to be_nil
      expect(described_class.strip(["plan", "show", "--json"])).to be_nil
    end

    it "leaves a line alone when any word before the help word starts with a dash" do
      expect(described_class.strip(["plan", "show", "--name", "--help", "--json"])).to be_nil
      expect(described_class.strip(["plan", "show", "--name", "-h", "--json"])).to be_nil
      expect(described_class.strip(["inbox", "add", "T", "--global", "--body", "--help", "--json"])).to be_nil
      expect(described_class.strip(["plan", "pause", "--interrupt", "--help", "--json"])).to be_nil
      expect(described_class.strip(["plan", "show", "--name", "ws", "--help", "--json"])).to be_nil
    end

    it "does not see words inside one argument" do
      expect(described_class.strip(["ask", "what does --help --json do", "--default", "x"])).to be_nil
    end

    it "does not take `ask`, whose words are free text" do
      expect(described_class.strip(%w[ask what is --help --json])).to be_nil
      expect(described_class.strip(%w[ask list --help --json])).to eq(%w[ask list --help])
      expect(described_class.strip(%w[ask --help --json])).to eq(%w[ask --help])
    end

    it "stops at --" do
      expect(described_class.strip(["lock", "--json", "--", "--help"])).to be_nil
      expect(described_class.strip(["plan", "--help", "--json", "--", "--json"])).to eq(["plan", "--help", "--", "--json"])
    end

    it "takes a help word after the verb's words and --json before it" do
      expect(described_class.strip(%w[--json plan show --help])).to eq(%w[plan show --help])
      expect(described_class.strip(%w[run %1 ls --help --json])).to eq(%w[run %1 ls --help])
    end
  end

  describe ".document" do
    it "splits usage, description, options and examples" do
      text = <<~PAGE
        Usage: workspace x one [--all]
               workspace x two

        Does a thing.

        Options:
            --name WS                    The workspace
                                         (continued)
            -h, --help                   Show this help

        Examples:
          workspace x one    # first
          workspace x two
      PAGE

      expect(described_class.document(text)).to eq(
        "usage" => ["workspace x one [--all]", "workspace x two"],
        "description" => "Does a thing.",
        "options" => [
          {"flags" => "--name WS", "description" => "The workspace (continued)"},
          {"flags" => "-h, --help", "description" => "Show this help"}
        ],
        "examples" => [{"command" => "workspace x one", "scenario" => "first"}, {"command" => "workspace x two", "scenario" => ""}]
      )
    end

    it "reads odd option lines: a bare flag, placeholders, a first line that is not a flag, a blank before a continuation" do
      text = "Usage: workspace z\n\nOptions:\n    some preamble line\n    --discard-unsaved\n    --pane [ARG] Take it\n    --to <dir> Where\n\n        goes on\n    --no-agents show only: skip\n"

      expect(described_class.document(text)["options"]).to eq([
        {"flags" => "some preamble line", "description" => ""},
        {"flags" => "--discard-unsaved", "description" => ""},
        {"flags" => "--pane [ARG]", "description" => "Take it"},
        {"flags" => "--to <dir>", "description" => "Where goes on"},
        {"flags" => "--no-agents", "description" => "show only: skip"}
      ])
    end

    it "gives a Usage-only page empty text parts" do
      expect(described_class.document("Usage: workspace q\n")).to eq("usage" => ["workspace q"], "description" => "", "options" => [], "examples" => [])
    end

    it "keeps a first line that is not Usage in the description" do
      doc = described_class.document("Hello there\n\nExamples:\n  workspace q   # one\n  workspace q2 # two\n")

      expect(doc["usage"]).to eq([])
      expect(doc["description"]).to eq("Hello there")
      expect(doc["examples"]).to eq([{"command" => "workspace q", "scenario" => "one"}, {"command" => "workspace q2", "scenario" => "two"}])
    end

    it "keeps other headed parts and splits a long flag column on one space" do
      doc = described_class.document("Usage: workspace y\n\nText.\n\nOptions:\n    --a-very-long-flag-name VALUE Explains it\n\nExit codes:\n  0  ok\n")

      expect(doc["options"]).to eq([{"flags" => "--a-very-long-flag-name VALUE", "description" => "Explains it"}])
      expect(doc["sections"]).to eq([{"heading" => "Exit codes", "text" => "0  ok"}])
    end

    it "gives valid JSON for text that is not a page" do
      doc = described_class.document("just words\nmore")

      expect(JSON.parse(JSON.generate(doc))).to include("usage" => [], "description" => "just words\nmore", "options" => [], "examples" => [])
      expect(described_class.document("")).to include("usage" => [], "description" => "")
    end
  end
end

RSpec.describe "workspace --help --json" do
  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = 0
    Dir.mktmpdir("workspace-help-json-home") do |home|
      saved = ENV.to_h
      begin
        ENV.replace("HOME" => home, "PATH" => File.dirname(RbConfig.ruby))
        before = Dir.glob("#{home}/**/*", File::FNM_DOTMATCH).sort
        saved_streams = [$stdout, $stderr]
        begin
          $stdout = out
          $stderr = err
          cli = Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {})
          cli.run(argv)
        rescue SystemExit => e
          status = e.status
        ensure
          $stdout, $stderr = saved_streams
        end
        after = Dir.glob("#{home}/**/*", File::FNM_DOTMATCH).sort
        return [out.string, err.string, status, after - before]
      ensure
        ENV.replace(saved)
      end
    end
  end

  it "prints one document for a verb, in either order, and writes nothing" do
    ["--help --json", "--json --help"].each do |flags|
      out, err, status, created = run_cli(["plan", "show", *flags.split])
      doc = JSON.parse(out)

      expect(doc["usage"].first).to start_with("workspace plan show")
      expect(doc["examples"]).not_to be_empty
      expect(doc["examples"].first.keys).to eq(["command", "scenario"])
      expect([err, status, created]).to eq(["", 0, []])
    end
  end

  it "prints one document for OptionParser pages, which write to $stdout" do
    out, _err, status, = run_cli(["start", "--help", "--json"])

    expect(JSON.parse(out)["usage"].first).to include("issue-url")
    expect(status).to eq(0)
  end

  it "keeps the root page's subcommands and environment variables" do
    doc = JSON.parse(run_cli(["--help", "--json"]).first)

    expect(doc["sections"].map { |s| s["heading"] }).to include("Subcommands", "Environment variables")
    expect(doc["sections"].find { |s| s["heading"] == "Subcommands" }["text"]).to include("workflow")
  end

  it "records a question whose text holds --help and --json" do
    out, _err, status, created = run_cli(["ask", "what does --help --json do", "--default", "x", "--json"])

    expect(JSON.parse(out)).to include("ok" => true)
    expect(JSON.parse(out)).not_to include("usage")
    expect(status).to eq(0)
    expect(created).not_to be_empty
  end

  it "prints no help document for --help after --" do
    out, _err, _status, created = run_cli(["ask", "--json", "--default", "x", "--", "--help"])

    expect(JSON.parse(out)).not_to include("usage")
    expect(created).not_to be_empty
  end

  it "does not treat the value of --name as a help request" do
    out, _err, status, created = run_cli(["plan", "path", "--name", "--help", "--json"])

    expect(JSON.parse(out)).not_to include("usage")
    expect(status).not_to eq(0)
    expect(created).to eq([])
  end

  it "leaves `start --name --help --json` to start's own parser: one error document, nothing written" do
    out, _err, status, created = run_cli(%w[start --name --help --json])

    expect(JSON.parse(out)).to include("ok" => false, "code" => "usage")
    expect(status).not_to eq(0)
    expect(created).to eq([])
  end

  it "leaves `inbox add T --global --body --help --json` as it is on main: --help is the body, and no help document is made" do
    out, _err, status, = run_cli(%w[inbox add T --global --body --help --json])
    doc = JSON.parse(out)

    expect(doc).to include("action" => "inbox add")
    expect(doc).not_to include("examples")
    expect(doc.dig("results", 0, "item", "body")).to eq("--help")
    expect(status).to eq(0)
  end

  it "leaves `ask what is --help --json` as it is on main: OptionParser's text page, no question recorded" do
    out, _err, _status, created = run_cli(%w[ask what is --help --json])

    expect(out).to start_with("Usage: workspace ask")
    expect(created).to eq([])
  end

  it "gives an error document and keeps the status for a run that fails" do
    out, err, status, created = run_cli(%w[nosuch --help --json])

    expect(JSON.parse(out)).to include("ok" => false, "code" => "usage", "error" => "Unknown subcommand: nosuch")
    expect([err, status, created]).to eq(["", 1, []])
  end

  it "leaves --json alone as a normal flag" do
    out, _err, = run_cli(["capabilities", "--json"])

    expect(JSON.parse(out)).to include("features")
  end
end
