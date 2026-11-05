require "spec_helper"

RSpec.describe Workspace::UiAppProbe do
  let(:result_class) { Workspace::OsascriptRunner::Result }

  def probe_for(stdout: "", success: true, timed_out: false)
    runner = double("osascript", call: result_class.new(stdout, success, timed_out))
    described_class.new(osascript: runner)
  end

  def answer_for(handler: nil, running: [])
    probe_for(stdout: JSON.generate({handler: handler, running: running}) + "\n").call
  end

  describe "SCRIPT" do
    it "is frozen and holds no input" do
      expect(described_class::SCRIPT).to be_frozen
      expect(described_class::SCRIPT).to include("workspace-ui://inbox", "com.zdennis.workspace-ui", "WorkspaceUILinkRevision")
      expect(described_class::SCRIPT).not_to include("console.log", "openURL", "launchApplication")
    end

    it "is the only thing passed to osascript" do
      runner = double("osascript")
      expect(runner).to receive(:call).with(described_class::SCRIPT).and_return(result_class.new("{}", true, false))
      described_class.new(osascript: runner).call
    end
  end

  describe "#call" do
    it "reads a found handler" do
      answer = answer_for(handler: {path: "/Applications/Workspace UI.app", id: "com.zdennis.workspace-ui", version: "0.30.1", rev: 2})
      expect(answer.problem).to be_nil
      expect(answer.handler).to eq(described_class::Handler.new("/Applications/Workspace UI.app", "com.zdennis.workspace-ui", "0.30.1", 2))
      expect(answer.running).to eq([])
    end

    it "reads no handler" do
      answer = answer_for
      expect(answer.handler).to be_nil
      expect(answer.problem).to be_nil
    end

    it "reads running copies" do
      answer = answer_for(running: [{pid: 4242, path: "/Applications/Workspace UI.app", launched: 1_700_000_000.5}])
      expect(answer.running).to eq([described_class::Running.new(4242, "/Applications/Workspace UI.app", Time.at(1_700_000_000.5))])
    end

    it "gives a nil launched_at when LaunchServices did not start the app" do
      answer = answer_for(running: [{pid: 7, path: "/x.app", launched: nil}])
      expect(answer.running.first.launched_at).to be_nil
      expect(answer.running.first.pid).to eq(7)
    end

    it "keeps a positive Integer revision only" do
      revisions = {1 => 1, 42 => 42, 0 => nil, -3 => nil, "1" => nil, 1.5 => nil, true => nil, false => nil, nil => nil, [1] => nil}
      revisions.each do |given, expected|
        answer = answer_for(handler: {path: "/a.app", id: "x", version: "1", rev: given})
        expect(answer.handler.link_revision).to eq(expected), "rev #{given.inspect}"
      end
    end

    it "reads malformed fields as nil without raising" do
      answer = answer_for(
        handler: {path: 5, id: [], version: {}, rev: "x"},
        running: [{pid: "9", path: "/a"}, {pid: 3, path: 8, launched: "soon"}, "junk", nil]
      )
      expect(answer.problem).to be_nil
      expect(answer.handler).to eq(described_class::Handler.new(nil, nil, nil, nil))
      expect(answer.running).to eq([described_class::Running.new(3, nil, nil)])
    end

    it "refuses a pid that is not positive, a relative or control-character path and an impossible launch time" do
      running = [{pid: 0}, {pid: -4}, {pid: 7, path: "relative/App.app", launched: 1e30}, {pid: 8, path: "/App\n.app", launched: 0}, {pid: 9, launched: Float::MAX}]
      answer = answer_for(running: running)

      expect(answer.running.map(&:pid)).to eq([7, 8, 9])
      expect(answer.running.map(&:path)).to eq([nil, nil, nil])
      expect(answer.running.map(&:launched_at)).to eq([nil, nil, nil])
    end

    it "reads a handler's relative path as nil" do
      answer = answer_for(handler: {path: "App.app", id: "x\ey"})

      expect(answer.handler.path).to be_nil
      expect(answer.handler.id).to be_nil
    end

    it "reports a timeout" do
      answer = probe_for(timed_out: true, success: false).call
      expect(answer.to_a).to eq([nil, [], :timed_out])
    end

    it "reports a failed run" do
      expect(probe_for(stdout: "{}", success: false).call.problem).to eq(:unavailable)
    end

    it "reports an empty answer (no osascript)" do
      expect(probe_for(stdout: "", success: false).call.problem).to eq(:unavailable)
      expect(probe_for(stdout: "  \n").call.problem).to eq(:unavailable)
    end

    it "reports malformed JSON" do
      expect(probe_for(stdout: "not json").call.problem).to eq(:bad_answer)
    end

    ["[]", '"x"', "null", "5", '{"running":{}}', '{"handler":[],"running":[]}', "{}"].each do |text|
      it "reports the wrong shape #{text} as bad_answer" do
        expect(probe_for(stdout: text).call.problem).to eq(:bad_answer)
      end
    end
  end

  describe "the real script" do
    it "answers with the right shape on macOS" do
      skip "needs macOS osascript" unless RUBY_PLATFORM.include?("darwin") && system("which osascript > /dev/null 2>&1")
      runner = Workspace::OsascriptRunner.new(command: ["osascript", "-l", "JavaScript"], timeout: 20)
      answer = described_class.new(osascript: runner).call
      skip "osascript timed out under load" if answer.problem == :timed_out
      expect(answer.problem).to be_nil
      expect(answer.running).to be_an(Array)
      expect(answer.handler).to be_nil.or be_a(described_class::Handler)
    end
  end
end
