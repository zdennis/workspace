require "spec_helper"
load File.join(PROJECT_ROOT, "script/hook-timeline")

RSpec.describe HookTimeline do
  def builder(**opts)
    HookTimeline::SettingsBuilder.new(ruby: "/usr/bin/ruby", shim: "/t/shim.rb", log: "/t/log", **opts)
  end

  def hook(command, **extra) = {"hooks" => [{"type" => "command", "command" => command}.merge(extra)]}

  let(:user) { {"hooks" => {"PreToolUse" => [hook("/x/cc-status"), hook("rtk hook claude").merge("matcher" => "Bash")]}} }
  let(:project) { {"hooks" => {"PreToolUse" => [hook("workspace session-event")], "PostToolUse" => [hook("workspace session-event")]}} }

  def commands(settings, event) = settings["hooks"][event].flat_map { |g| g["hooks"].map { |h| h["command"] } }

  describe HookTimeline::SettingsBuilder do
    it "merges user and project hooks, keeps matchers and wraps every command in the shim" do
      settings = builder.call([user, project])
      expect(settings["hooks"].keys).to contain_exactly("PreToolUse", "PostToolUse")
      expect(settings["hooks"]["PreToolUse"].map { |g| g["matcher"] }).to eq([nil, "Bash", nil])
      cmds = commands(settings, "PreToolUse")
      expect(cmds).to all(start_with("/usr/bin/ruby --disable-gems /t/shim.rb /t/log PreToolUse"))
      expect(cmds.first.shellsplit).to eq(["/usr/bin/ruby", "--disable-gems", "/t/shim.rb", "/t/log", "PreToolUse", "cc-status", "false", "/x/cc-status"])
    end

    it "passes the original command as one argument, whatever it contains" do
      original = %q(if [ -z "$HOME" ]; then echo 'a b'; fi)
      cmd = commands(builder.call([{"hooks" => {"Stop" => [hook(original)]}}]), "Stop").first
      expect(cmd.shellsplit.last).to eq(original)
    end

    it "marks hooks async by a substring of the command" do
      settings = builder(async: ["cc-status"]).call([user, project])
      flags = settings["hooks"]["PreToolUse"].flat_map { |g| g["hooks"].map { |h| h["async"] } }
      expect(flags).to eq([true, nil, nil])
      expect(commands(settings, "PreToolUse").first.shellsplit[6]).to eq("true")
    end

    it "swaps the workspace of session-event hooks only" do
      settings = builder(session_event: "/main/bin/workspace").call([user, project])
      expect(commands(settings, "PostToolUse").first.shellsplit.last).to eq("/main/bin/workspace session-event")
      expect(commands(settings, "PreToolUse").first.shellsplit.last).to eq("/x/cc-status")
    end

    it "gives a repeated hook a numbered label" do
      cmds = commands(builder.call([{"hooks" => {"Stop" => [hook("/a/cc-status"), hook("/b/cc-status")]}}]), "Stop")
      expect(cmds.map { |c| c.shellsplit[5] }).to eq(%w[cc-status cc-status#2])
    end

    it "yields no hooks for empty or missing settings" do
      expect(builder.call([{}, nil, {"hooks" => nil}])).to eq({"hooks" => {}})
    end

    it "leaves a non-command hook alone" do
      http = {"hooks" => {"Stop" => [{"hooks" => [{"type" => "http", "url" => "http://x"}]}]}}
      expect(builder.call([http])["hooks"]["Stop"]).to eq(http["hooks"]["Stop"])
    end
  end

  describe ".median" do
    it "takes the middle, the mean of the middle two, and nil for nothing" do
      expect(described_class.median([3, 1, 2])).to eq(2)
      expect(described_class.median([1, 2, 3, 10])).to eq(2.5)
      expect(described_class.median([])).to be_nil
    end
  end

  def line(kind, ts, event, label, pid, async = "false", status = "", cmd = label)
    [kind, ts, event, label, pid, async, status, cmd].join("\t")
  end

  # two calls; cc-status holds the PreToolUse barrier for 0.19, session-event takes 0.31
  let(:lines) do
    [0, 2].flat_map do |o|
      [
        line("start", 10.0 + o, "PreToolUse", "cc-status", 1), line("start", 10.0 + o, "PreToolUse", "workspace", 2),
        line("end", 10.19 + o, "PreToolUse", "cc-status", 1, "false", 0), line("end", 10.31 + o, "PreToolUse", "workspace", 2, "false", 0),
        line("start", 10.37 + o, "PostToolUse", "cc-status", 3), line("start", 10.37 + o, "PostToolUse", "workspace", 4),
        line("end", 10.56 + o, "PostToolUse", "cc-status", 3, "false", 0), line("end", 10.68 + o, "PostToolUse", "workspace", 4, "false", 0)
      ]
    end.shuffle(random: Random.new(1)).sort_by { |l| l.split("\t")[1].to_f }
  end

  describe ".parse" do
    it "pairs starts and ends by event, label and pid, and skips junk and unfinished hooks" do
      entries = described_class.parse(lines + ["garbage", line("start", 99, "Stop", "cc-status", 9)])
      expect(entries.size).to eq(8)
      expect(entries.first).to have_attributes(event: "PreToolUse", status: 0)
      expect(entries.first.duration).to be_within(0.001).of(0.19)
    end
  end

  describe ".analyze" do
    let(:report) { described_class.analyze(described_class.parse(lines)) }

    it "reports per-hook medians relative to the first hook of the event" do
      row = report[:hooks].find { |h| h[:event] == "PreToolUse" && h[:label] == "workspace" }
      expect(row).to include(n: 2)
      expect(row[:start]).to be_within(0.001).of(0)
      expect(row[:end]).to be_within(0.001).of(0.31)
      expect(row[:duration]).to be_within(0.001).of(0.31)
    end

    it "measures X from the last PreToolUse end to the PostToolUse start" do
      expect(report[:x]).to be_within(0.001).of(0.06)
      expect(report[:calls]).to eq(2)
    end

    it "predicts today's delta from the model" do
      expect(report[:predicted][:delta]).to be_within(0.001).of(0.37)
    end

    it "projects a fast session-event with cc-status async" do
      projected = described_class.analyze(described_class.parse(lines), async: ["cc-status"], se_time: 0.08)[:projected]
      expect(projected[:slowest_other_pre]).to eq(0.0)
      expect(projected[:delta]).to be_within(0.001).of(0.14)
    end

    it "projects the cc-status-synchronous case" do
      expect(report[:projected][:delta]).to be_within(0.001).of(0.25)
    end

    it "has no X or delta for an empty log" do
      empty = described_class.analyze([])
      expect(empty).to include(hooks: [], x: nil, predicted: nil)
      expect(described_class.render(empty)).to include("X and the delta are unknown")
    end

    it "renders the table" do
      text = described_class.render(report)
      expect(text).to include("PreToolUse", "cc-status", "X (last PreToolUse end")
    end
  end

  describe ".main" do
    it "analyses a saved log with --parse and starts nothing" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "log")
        File.write(path, lines.join("\n"))
        out = StringIO.new
        expect(described_class.main(["--parse", path, "--async", "cc-status"], out: out)).to eq(0)
        expect(out.string).to include("projected with session-event at 0.080s")
      end
    end

    it "stops with a message when no settings hold hooks" do
      Dir.mktmpdir do |dir|
        err = StringIO.new
        code = described_class.main(["--user-settings", File.join(dir, "none.json"), "--project-dir", dir], out: StringIO.new, err: err)
        expect(code).to eq(1)
        expect(err.string).to include("no hooks found")
      end
    end
  end
end
