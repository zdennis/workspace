require "spec_helper"

RSpec.describe Workspace::PromptTyper do
  let(:empty_prompt) { "────────\n❯ \n" }

  let(:tmux) do
    Class.new do
      attr_accessor :screens, :statuses
      attr_reader :delivered

      def initialize(screen)
        @screens = [screen]
        @statuses = []
        @delivered = []
      end

      def capture_screen(_pane_id) = (@screens.size > 1) ? @screens.shift : @screens.first

      def capture_screen_styled(pane_id) = capture_screen(pane_id)

      def deliver(session, target, text, enter: true)
        @delivered << [session, target, text, enter]
        status = @statuses.shift || (enter ? :submitted : :pasted)
        Workspace::Tmux::Delivery.new(status: status, message: "fake #{status}")
      end
    end.new(empty_prompt)
  end

  let(:facts) { {kind: "claude", state: "idle", open_tools: []} }
  let(:monitor) { double("monitor").tap { |m| allow(m).to receive(:typing_facts) { facts } } }

  subject(:typer) { described_class.new(tmux: tmux, session_monitor: monitor) }

  def type(text = "run the specs", **opts)
    typer.type(session_name: "api", target: "0.1", pane_id: "%5", text: text, **opts)
  end

  it "pastes without Enter, checks the input line holds the text, then presses Enter" do
    tmux.screens = [empty_prompt, "────────\n❯ run the specs\n────────\n"]

    result = type

    expect(result.outcome).to eq(:submitted)
    expect(result.delivery.status).to eq(:submitted)
    expect(result).to be_landed
    expect(tmux.delivered).to eq([["api", "0.1", "run the specs", false], ["api", "0.1", "", true]])
  end

  it "reads one styled capture, so a suggestion reads as an empty input and a draft does not" do
    suggestion = "────────\n\e[39m❯ \e[2msend %45 the reply\e[0m\n"
    tmux.screens = [suggestion]
    expect(typer.check("%5")).to be_nil

    tmux.screens = ["────────\n\e[39m❯ half a thought\n"]
    expect(typer.check("%5")).to include(reason: "input_not_empty")

    tmux.screens = [nil]
    expect(typer.check("%5")).to include(reason: "no_input_prompt")
  end

  it "takes the paste placeholder for a long paste as the text being there" do
    text = "step\n" * 50
    tmux.screens = [empty_prompt, "────────\n❯ [Pasted text #1 +50 lines]\n────────\n"]

    expect(type(text).outcome).to eq(:submitted)
  end

  it "refuses before typing when the pane can't take text" do
    facts[:state] = "waiting"

    result = type

    expect(result.to_h).to include(outcome: :refused, code: "pane_not_ready", reason: "waiting")
    expect(result).not_to be_landed
    expect(tmux.delivered).to be_empty
  end

  describe "before_enter" do
    before { tmux.screens = [empty_prompt, "────────\n❯ run the specs\n────────\n"] }

    it "leaves the text unsubmitted and presses no Enter when it says no" do
      result = type(before_enter: -> { false })

      expect(result.outcome).to eq(:not_submitted)
      expect(result).to be_landed
      expect(tmux.delivered).to eq([["api", "0.1", "run the specs", false]])
    end

    it "presses Enter when it says yes" do
      expect(type(before_enter: -> { true }).outcome).to eq(:submitted)
      expect(tmux.delivered.last).to eq(["api", "0.1", "", true])
    end

    it "is called after the last check and before Enter" do
      order = []
      allow(typer).to receive(:check).and_wrap_original do |original, *args, **opts|
        order << :check
        original.call(*args, **opts)
      end
      allow(tmux).to receive(:deliver).and_wrap_original do |original, *args, **opts|
        order << (opts[:enter] ? :enter : :paste)
        original.call(*args, **opts)
      end
      type(before_enter: -> { (order << :before_enter) && true })

      expect(order).to eq([:check, :paste, :check, :before_enter, :enter])
    end

    it "isn't called when the last check already refused" do
      tmux.screens = [empty_prompt, empty_prompt]
      called = false
      type(before_enter: -> { called = true })

      expect(called).to be(false)
    end
  end

  it "stops before the paste when before_paste says no" do
    result = type(before_paste: -> { false })

    expect(result.outcome).to eq(:aborted)
    expect(tmux.delivered).to be_empty
  end

  it "calls before_paste after the first check and before the paste" do
    order = []
    allow(monitor).to receive(:typing_facts) { order << :check && facts }
    tmux.screens = [empty_prompt, "────────\n❯ run the specs\n────────\n"]

    type(before_paste: -> { (order << :before_paste) && true })

    expect(order.first(2)).to eq([:check, :before_paste])
  end

  it "reports a paste that never reached the pane as safe to type again" do
    tmux.statuses = [:not_landed]

    result = type

    expect(result.outcome).to eq(:not_landed)
    expect(result).not_to be_landed
    expect(tmux.delivered.size).to eq(1)
  end

  it "reports a tmux failure on the paste as safe to type again" do
    tmux.statuses = [:failed]

    result = type

    expect(result.outcome).to eq(:failed)
    expect(result).not_to be_landed
  end

  it "doesn't press Enter when the paste can't be seen" do
    tmux.statuses = [:unverified]

    result = type

    expect(result.outcome).to eq(:not_submitted)
    expect(result).to be_landed
    expect(result.message).to include("Enter was not pressed")
    expect(tmux.delivered.size).to eq(1)
  end

  it "doesn't press Enter when the input line no longer holds the text" do
    tmux.screens = [empty_prompt, "────────\n❯ 1. Yes\n"]

    result = type

    expect(result.to_h).to include(outcome: :not_submitted, reason: "input_changed")
    expect(tmux.delivered.size).to eq(1)
  end

  it "checks for the whole text with exact:, where pasted: takes the same text or one placeholder" do
    text = "An API error stopped your last turn"
    tmux.screens = ["────────\n❯ #{text} and my own words\n────────\n"]
    expect(typer.check("%5", pasted: text)).to include(reason: "input_changed")
    expect(typer.check("%5", exact: text)).to include(reason: "input_changed")

    tmux.screens = ["────────\n❯ [Pasted text #1 +3 lines]\n────────\n"]
    expect(typer.check("%5", pasted: text)).to be_nil
    expect(typer.check("%5", exact: text)).to include(reason: "input_changed")

    tmux.screens = ["────────\n❯ #{text}\n────────\n"]
    expect(typer.check("%5", exact: text)).to be_nil
  end

  it "reports Enter that didn't take" do
    tmux.screens = [empty_prompt, "────────\n❯ run the specs\n────────\n"]
    tmux.statuses = [:pasted, :unsubmitted]

    result = type

    expect(result.outcome).to eq(:not_submitted)
    expect(result.delivery.status).to eq(:unsubmitted)
  end
end
