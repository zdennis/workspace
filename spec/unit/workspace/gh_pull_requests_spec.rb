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

  let(:remotes) { {} }
  let(:git) do
    remotes_by_path = remotes
    Class.new { define_method(:remote_url) { |path| remotes_by_path[path] } }.new
  end

  subject(:pull_requests) { described_class.new(git: git, runner: runner) }

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
      remotes["/wt"] = "git@github.com:o/r.git"
      answers[%w[gh pr]] = [pr_json, "", result_class.new(true)]

      expect(pull_requests.status_for("feat", "/wt")).to eq(number: 7, url: "https://github.com/o/r/pull/7", state: "MERGED")
      expect(calls).to eq([%w[gh pr view feat --repo o/r --json number,url,state]])
      expect(calls.last).to eq(%w[gh pr view feat --repo o/r --json number,url,state])
    end

    it "reads an https remote without a .git suffix" do
      remotes["/wt"] = "https://github.com/o/r"
      answers[%w[gh pr]] = [pr_json, "", result_class.new(true)]
      expect(pull_requests.status_for("feat", "/wt")).to include(number: 7, state: "MERGED")
      expect(calls.last).to include("o/r")
    end

    it "is nil when the origin cannot be read" do
      expect(pull_requests.status_for("feat", "/wt")).to be_nil
    end

    it "is nil for a remote that is not GitHub" do
      remotes["/wt"] = "git@example.com:o/r.git"
      expect(pull_requests.status_for("feat", "/wt")).to be_nil
    end

    it "is nil when gh fails" do
      remotes["/wt"] = "git@github.com:o/r.git"
      answers[%w[gh pr]] = ["", "no pull requests found", result_class.new(false)]
      expect(pull_requests.status_for("feat", "/wt")).to be_nil
    end

    it "is nil when gh prints something that is not JSON" do
      remotes["/wt"] = "git@github.com:o/r.git"
      answers[%w[gh pr]] = ["nope", "", result_class.new(true)]
      expect(pull_requests.status_for("feat", "/wt")).to be_nil
    end
  end
end
