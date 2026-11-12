require "spec_helper"

# Each shared fake is held to the real class it stands for (the accepts-every-call rule in
# spec/support/fake_contract.rb). A section that adds a shared fake adds one describe block here.
RSpec.describe "fake contracts" do
  describe FakeContract do
    let(:real) do
      Class.new do
        def two(a, b, lines: 1, all: false) = nil

        def with_optional(a, b = nil) = nil

        def open(a, **opts) = nil
      end
    end

    def problems_for(&body)
      fake = Class.new(&body)
      described_class.problems(fake, real)
    end

    it "accepts a fake that takes the same positionals and every keyword by name or by **" do
      expect(problems_for { def two(_a, _b, **) = nil }).to be_empty
      expect(problems_for { def two(_a, _b, lines: 1, all: false) = nil }).to be_empty
    end

    it "fails when a keyword the real method takes is dropped" do
      expect(problems_for { def two(_a, _b, lines: 1) = nil }).to eq(["two: the fake does not accept all:"])
    end

    it "fails when the fake requires an argument the real method does not" do
      expect(problems_for { def two(_a, _b, _c) = nil }.first).to include("requires 3 positionals")
      expect(problems_for { def two(_a, _b, lines:, all: false) = nil }).to eq(["two: the fake requires lines:, the real method does not"])
    end

    it "fails when the fake has no room for an optional positional or a free keyword" do
      expect(problems_for { def with_optional(_a) = nil }.first).to include("at most")
      expect(problems_for { def open(_a) = nil }).to eq(["open: the real method takes any keyword, the fake does not"])
    end

    it "fails on a method the real class lacks, unless it is a control method" do
      fake = Class.new { def invented = nil }
      expect(described_class.problems(fake, real).first).to include("is not a method of")
      expect(described_class.problems(fake, real, control: [:invented])).to be_empty
    end
  end

  describe FakeTmux do
    it "accepts every call Workspace::Tmux accepts" do
      expect(FakeContract.problems(described_class, Workspace::Tmux, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe FakePane do
    it "accepts every call Workspace::Pane accepts" do
      expect(FakeContract.problems(described_class, Workspace::Pane, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe FakePaneFactory do
    it "accepts every call Workspace::PaneFactory accepts" do
      expect(FakeContract.problems(described_class, Workspace::PaneFactory, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe FakeGit do
    it "accepts every call Workspace::Git accepts" do
      expect(FakeContract.problems(described_class, Workspace::Git, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingComposer do
    it "accepts every call Workspace::InstructionComposer accepts" do
      expect(FakeContract.problems(described_class, Workspace::InstructionComposer, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingGitExclude do
    it "accepts every call Workspace::GitExclude accepts" do
      expect(FakeContract.problems(described_class, Workspace::GitExclude, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingRunChange do
    it "accepts every call Workspace::WorkflowRunChange accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowRunChange, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingRunStore do
    it "accepts every call Workspace::WorkflowRunStore accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowRunStore, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingWorkflowPrompt do
    it "accepts every call Workspace::WorkflowPrompt accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowPrompt, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingDispatch do
    it "accepts every call Workspace::WorkflowDispatch accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowDispatch, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingRunResources do
    it "accepts every call Workspace::RunResources accepts" do
      expect(FakeContract.problems(described_class, Workspace::RunResources, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingWorkflowPanes do
    it "accepts every call Workspace::WorkflowPanes accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowPanes, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingAttemptRecord do
    it "accepts every call Workspace::WorkflowAttemptRecord accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowAttemptRecord, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingLogTail do
    it "accepts every call Workspace::WorkflowLogTail accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowLogTail, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingProgress do
    it "accepts every call Workspace::WorkflowProgress accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowProgress, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingChecker do
    it "accepts every call Workspace::WorkflowCheck accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowCheck, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingRequire do
    it "accepts every call Workspace::WorkflowRequire accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowRequire, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingGuard do
    it "accepts every call Workspace::WorkflowGuard accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowGuard, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingCommandsConfig do
    it "accepts every call Workspace::CommandsConfig accepts" do
      expect(FakeContract.problems(described_class, Workspace::CommandsConfig, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingInbox do
    it "accepts every call Workspace::InboxStore accepts" do
      expect(FakeContract.problems(described_class, Workspace::InboxStore, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingEvaluation do
    it "accepts every call Workspace::WorkflowEvaluation accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowEvaluation, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingGateNote do
    it "accepts every call Workspace::WorkflowGateNote accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkflowGateNote, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe FakeSentinelPoller do
    it "accepts every call Workspace::SentinelPoller accepts" do
      expect(FakeContract.problems(described_class, Workspace::SentinelPoller, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingRestartMonitor do
    it "accepts every call Workspace::SessionMonitor accepts" do
      expect(FakeContract.problems(described_class, Workspace::SessionMonitor, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingContextReader do
    it "accepts every call Workspace::ContextReader accepts" do
      expect(FakeContract.problems(described_class, Workspace::ContextReader, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingRestartRegistry do
    it "accepts every call Workspace::RestartRegistry accepts" do
      expect(FakeContract.problems(described_class, Workspace::RestartRegistry, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingRestartRunner do
    it "accepts every call Workspace::RestartRunner accepts" do
      expect(FakeContract.problems(described_class, Workspace::RestartRunner, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingPipelineConfig do
    it "accepts every call Workspace::PipelineConfig accepts" do
      expect(FakeContract.problems(described_class, Workspace::PipelineConfig, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingPipelineState do
    it "accepts every call Workspace::PipelineState accepts" do
      expect(FakeContract.problems(described_class, Workspace::PipelineState, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingCoordinatorClient do
    it "accepts every call Workspace::WorkCoordinatorClient accepts" do
      expect(FakeContract.problems(described_class, Workspace::WorkCoordinatorClient, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end

  describe RecordingSentinelPoller do
    it "accepts every call Workspace::SentinelPoller accepts" do
      expect(FakeContract.problems(described_class, Workspace::SentinelPoller, control: described_class::CONTROL_METHODS)).to be_empty
    end
  end
end
