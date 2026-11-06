RSpec.describe Workspace::GhPullRequests do
  let(:result_class) do
    Struct.new(:ok) do
      def success? = ok
    end
  end

  let(:calls) { [] }
  let(:answers) { {} }
  let(:runner) do
    ->(*argv) do
      calls << argv
      answers.fetch(argv.first(2)) { ["", "", result_class.new(false)] }
    end
  end

  subject(:pull_requests) { described_class.new(runner: runner) }

  describe "#usable?" do
    it "is true when gh auth status succeeds" do
      answers[%w[gh auth]] = ["", "", result_class.new(true)]
      expect(pull_requests.usable?).to be true
      expect(calls).to eq([%w[gh auth status]])
    end

    it "is false when it fails" do
      expect(pull_requests.usable?).to be false
    end
  end

  describe "#status_for" do
    let(:pr_json) { '{"number":7,"url":"https://github.com/o/r/pull/7","state":"MERGED"}' }

    it "reads the pull request of the branch from the origin repository" do
      answers[%w[git -C]] = ["git@github.com:o/r.git\n", "", result_class.new(true)]
      answers[%w[gh pr]] = [pr_json, "", result_class.new(true)]

      expect(pull_requests.status_for("feat", "/wt")).to eq(number: 7, url: "https://github.com/o/r/pull/7", state: "MERGED")
      expect(calls.last).to eq(%w[gh pr view feat --repo o/r --json number,url,state])
    end

    it "reads an https remote without a .git suffix" do
      answers[%w[git -C]] = ["https://github.com/o/r\n", "", result_class.new(true)]
      answers[%w[gh pr]] = [pr_json, "", result_class.new(true)]
      expect(pull_requests.status_for("feat", "/wt")).to include(number: 7, state: "MERGED")
      expect(calls.last).to include("o/r")
    end

    it "is nil when the origin cannot be read" do
      expect(pull_requests.status_for("feat", "/wt")).to be_nil
    end

    it "is nil for a remote that is not GitHub" do
      answers[%w[git -C]] = ["git@example.com:o/r.git\n", "", result_class.new(true)]
      expect(pull_requests.status_for("feat", "/wt")).to be_nil
    end

    it "is nil when gh fails" do
      answers[%w[git -C]] = ["git@github.com:o/r.git\n", "", result_class.new(true)]
      answers[%w[gh pr]] = ["", "no pull requests found", result_class.new(false)]
      expect(pull_requests.status_for("feat", "/wt")).to be_nil
    end

    it "is nil when gh prints something that is not JSON" do
      answers[%w[git -C]] = ["git@github.com:o/r.git\n", "", result_class.new(true)]
      answers[%w[gh pr]] = ["nope", "", result_class.new(true)]
      expect(pull_requests.status_for("feat", "/wt")).to be_nil
    end
  end
end
