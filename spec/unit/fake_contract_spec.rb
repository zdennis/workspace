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
end
