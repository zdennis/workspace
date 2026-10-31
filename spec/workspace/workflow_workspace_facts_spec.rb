require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowWorkspaceFacts do
  let(:state_root) { Dir.mktmpdir }
  let(:sessions) { {} }
  let(:configs) { {} }
  let(:answers) { {} }

  let(:liveness) do
    sessions_ref = sessions
    calls = (@liveness_calls = [])
    Class.new do
      define_method(:call) do |names|
        calls << names
        names.to_h { |n| [n, sessions_ref.fetch(n, false)] }
      end
    end.new
  end

  let(:project_config) do
    configs_ref = configs
    Class.new do
      define_method(:exists?) { |name| configs_ref.fetch(name, false) }
    end.new
  end

  let(:config) do
    root = state_root
    Class.new do
      define_method(:pipeline_state_dir) { |name| File.join(root, name) }
    end.new
  end

  let(:fetched) { [] }
  let(:agents) do
    answers_ref = answers
    log = fetched
    Class.new do
      define_method(:facts) do |name, timeout:|
        log << [name, timeout]
        value = answers_ref.fetch(name, {"available" => false, "reason" => "no_daemon"})
        raise value if value.is_a?(Exception)
        value
      end
    end.new
  end

  let(:timeout) { 1.0 }
  subject(:facts) do
    described_class.new(liveness: liveness, project_config: project_config, config: config, agents: agents, timeout: timeout)
  end

  after { FileUtils.rm_rf(state_root) }

  def panes(*pairs)
    {"available" => true, "panes" => pairs.map { |kind, state| {"kind" => kind, "state" => state} }}
  end

  describe "status" do
    it "is live when the session exists" do
      sessions["a"] = true
      expect(facts.call(["a"])["a"]).to include("status" => "live", "tmux_session" => true)
    end

    it "is live when the session is unknown and a daemon answers" do
      sessions["a"] = nil
      answers["a"] = panes(["claude", "idle"])
      expect(facts.call(["a"])["a"]["status"]).to eq("live")
    end

    it "is unknown when the session is unknown and no daemon answers" do
      sessions["a"] = nil
      expect(facts.call(["a"])["a"]["status"]).to eq("unknown")
    end

    it "is stopped when the session is gone but the config exists" do
      configs["a"] = true
      expect(facts.call(["a"])["a"]).to include("status" => "stopped", "config" => true)
    end

    it "is gone when the session and config are both missing" do
      expect(facts.call(["a"])["a"]).to include("status" => "gone", "config" => false)
    end

    it "reports whether the state directory exists" do
      Dir.mkdir(File.join(state_root, "a"))
      result = facts.call(%w[a b])
      expect(result["a"]["state_dir"]).to be(true)
      expect(result["b"]["state_dir"]).to be(false)
    end
  end

  describe "agent" do
    before { sessions["a"] = true }

    it "is working when one of several agent panes works, whatever the others are doing" do
      answers["a"] = panes(["claude", "idle"], ["claude", "working"], ["claude", "waiting"])
      expect(facts.call(["a"])["a"]["agent"]).to eq("working")
    end

    it "is waiting when none works and one waits" do
      answers["a"] = panes(["claude", "idle"], ["claude", "waiting"])
      expect(facts.call(["a"])["a"]["agent"]).to eq("waiting")
    end

    it "is idle when the panes are idle or done" do
      answers["a"] = panes(["claude", "idle"], ["claude", "done"])
      expect(facts.call(["a"])["a"]["agent"]).to eq("idle")
    end

    it "does not count a shell pane that is working" do
      answers["a"] = panes(["shell", "working"], ["claude", "idle"])
      expect(facts.call(["a"])["a"]["agent"]).to eq("idle")
    end

    it "is nil when only shell panes are left" do
      answers["a"] = panes(["shell", "working"])
      expect(facts.call(["a"])["a"]["agent"]).to be_nil
    end

    it "is nil when the daemon does not answer" do
      expect(facts.call(["a"])["a"]["agent"]).to be_nil
    end

    it "is nil for a workspace that is not live" do
      sessions["a"] = false
      expect(facts.call(["a"])["a"]["agent"]).to be_nil
    end
  end

  describe "daemon reads" do
    it "asks no daemon when the session is false" do
      sessions["a"] = false
      facts.call(["a"])
      expect(fetched).to be_empty
    end

    it "asks the daemon when the session is nil, with the timeout" do
      sessions["a"] = nil
      facts.call(["a"])
      expect(fetched).to eq([["a", 1.0]])
    end

    it "returns within the shared deadline when a daemon hangs" do
      slow = Class.new do
        def facts(_name, timeout:)
          sleep 5
        end
      end.new
      sessions["a"] = true
      subject = described_class.new(liveness: liveness, project_config: project_config, config: config, agents: slow, timeout: 0.1)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = subject.call(["a"])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
      expect(result["a"]).to include("status" => "live", "agent" => nil)
    end

    it "reads a thread that raises as no answer" do
      sessions["a"] = nil
      answers["a"] = RuntimeError.new("boom")
      expect(facts.call(["a"])["a"]["status"]).to eq("unknown")
    end

    it "reads a NoMethodError from one workspace's daemon read as no answer, so one failed read does not fail the whole table" do
      sessions["a"] = nil
      sessions["b"] = true
      answers["a"] = NoMethodError.new("boom")
      answers["b"] = panes(["claude", "idle"])
      result = facts.call(["a", "b"])
      expect(result["a"]).to include("status" => "unknown", "agent" => nil)
      expect(result["b"]).to include("status" => "live", "agent" => "idle")
    end
  end

  describe "names" do
    it "deduplicates names" do
      sessions["a"] = true
      result = facts.call(%w[a a])
      expect(result.keys).to eq(["a"])
      expect(@liveness_calls).to eq([["a"]])
      expect(fetched.size).to eq(1)
    end

    it "gives nil facts and unknown status to nil, empty and NUL names without reaching Liveness" do
      sessions["a"] = true
      result = facts.call([nil, "", "x\0y", "a"])
      expect(@liveness_calls).to eq([["a"]])
      [nil, "", "x\0y"].each do |bad|
        expect(result[bad]).to eq("status" => "unknown", "agent" => nil, "config" => nil, "tmux_session" => nil, "state_dir" => nil)
      end
      expect(result["a"]["status"]).to eq("live")
    end
  end

  describe "when Liveness raises" do
    [Errno::EACCES, ArgumentError].each do |error|
      it "reads every session as nil after #{error}" do
        allow(liveness).to receive(:call).and_raise(error)
        answers["a"] = panes(["claude", "idle"])
        result = facts.call(["a"])
        expect(result["a"]).to include("tmux_session" => nil, "status" => "live")
        expect(fetched).to eq([["a", 1.0]])
      end
    end
  end
end
