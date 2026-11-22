require "spec_helper"
require "json"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

RSpec.describe DemoCalculator2::EventWaiter do
  let(:lanes) { %w[lane-a lane-b] }

  def line(type, workspace = nil)
    JSON.generate({"type" => type, "workspace" => workspace}.compact)
  end

  describe ".wake?" do
    %w[work_queue_item_started work_queue_item_finished].each do |type|
      %w[lane-a lane-b].each do |workspace|
        it "is true for #{type} in #{workspace}" do
          expect(described_class.wake?(line(type, workspace), lanes)).to be(true)
        end
      end
    end

    it "is false for stream lines, other workspaces, other types and junk" do
      expect(described_class.wake?(line("follow_started"), lanes)).to be(false)
      expect(described_class.wake?(line("gap"), lanes)).to be(false)
      expect(described_class.wake?(line("work_queue_item_started", "other"), lanes)).to be(false)
      expect(described_class.wake?(line("tool_finished", "lane-a"), lanes)).to be(false)
      expect(described_class.wake?(line("work_queue_item_started"), lanes)).to be(false)
      expect(described_class.wake?("not json", lanes)).to be(false)
      expect(described_class.wake?("[1]", lanes)).to be(false)
    end
  end

  describe "#call" do
    let(:argvs) { [] }
    let(:slept) { [] }
    let(:pipe) { IO.pipe }
    let(:thread) { double("thread", pid: 999_999, join: nil) }
    before { allow(Process).to receive(:kill) }
    let(:spawn) {
      ->(argv) {
        argvs << argv
        [pipe[0], thread]
      }
    }
    let(:waiter) { described_class.new(workspaces: lanes, spawn: spawn, sleeper: ->(seconds) { slept << seconds }) }

    after { pipe.each { |io| io.close unless io.closed? } }

    it "starts the follower lazily with exactly the documented argv" do
      expect(argvs).to be_empty
      waiter.call(0.05)
      expect(argvs).to eq([%w[workspace events --follow --json --types work_queue_item_started,work_queue_item_finished]])
      waiter.call(0.05)
      expect(argvs.size).to eq(1)
    end

    it "returns on a matching line and keeps one that arrived between waits" do
      pipe[1].puts line("work_queue_item_finished", "lane-b")
      pipe[1].puts line("work_queue_item_started", "lane-a")
      waiter.call(5)
      waiter.call(5)
      expect(slept).to be_empty
    end

    it "uses the workspaces given to a call in place of the constructor's" do
      pipe[1].puts line("work_queue_item_started", "late-lane")
      waiter.call(0.2)
      expect(slept).to be_empty
      pipe[1].puts line("work_queue_item_started", "late-lane")
      started = Time.now
      waiter.call(5, workspaces: %w[late-lane])
      expect(Time.now - started).to be < 2
    end

    it "falls back to a 3s sleep when the spawn fails" do
      failing = described_class.new(workspaces: lanes, spawn: ->(_) { raise Errno::ENOENT }, sleeper: ->(seconds) { slept << seconds })
      failing.call(5)
      failing.call(5)
      expect(slept).to eq([3, 3])
    end

    it "falls back to a 3s sleep when the follower's output ends" do
      pipe[1].close
      waiter.call(5)
      waiter.call(5)
      expect(slept).to eq([3, 3])
      expect(argvs.size).to eq(1)
    end
  end
end
