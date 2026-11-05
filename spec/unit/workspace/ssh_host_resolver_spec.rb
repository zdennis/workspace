require "spec_helper"

RSpec.describe Workspace::SshHostResolver do
  let(:calls) { [] }
  let(:answer) { ["user gh\nhostname GitHub.com\nport 22\n", "", true] }
  let(:runner) do
    lambda do |argv, **options|
      calls << [argv, options]
      answer.is_a?(Exception) ? raise(answer) : answer
    end
  end
  let(:resolver) { described_class.new(runner: runner) }

  it "returns the hostname ssh reports, lowercased" do
    expect(resolver.hostname("gh")).to eq("github.com")
  end

  it "passes -- before the name and runs from a fixed directory with a time limit" do
    resolver.hostname("gh")

    expect(calls.first).to eq([["ssh", "-G", "--", "gh"], {chdir: "/", timeout: 5}])
  end

  it "is nil when the output has no hostname line" do
    resolver = described_class.new(runner: ->(*, **) { ["port 22\n", "", true] })

    expect(resolver.hostname("gh")).to be_nil
  end

  it "is nil when the answer is not a plain hostname" do
    resolver = described_class.new(runner: ->(*, **) { ["hostname -oProxyCommand=x\n", "", true] })

    expect(resolver.hostname("gh")).to be_nil
  end

  it "refuses a name that is not a plain hostname without running ssh" do
    ["-oProxyCommand=x", "a b", "a;b", "", nil, "-G"].each { |name| expect(resolver.hostname(name)).to be_nil }

    expect(calls).to be_empty
  end

  it "is nil when ssh fails" do
    resolver = described_class.new(runner: ->(*, **) { ["hostname github.com\n", "", false] })

    expect(resolver.hostname("gh")).to be_nil
  end

  it "is nil when ssh times out or cannot be run" do
    [Timeout::Error.new("slow"), Errno::ENOENT.new("ssh")].each do |error|
      resolver = described_class.new(runner: ->(*, **) { raise error })

      expect(resolver.hostname("gh")).to be_nil
    end
  end

  it "asks ssh once per name, failures included" do
    2.times { resolver.hostname("gh") }
    resolver.hostname("other")

    expect(calls.map { |argv, _| argv.last }).to eq(%w[gh other])

    failing = described_class.new(runner: ->(*args, **) { calls.push(args) && ["", "", false] })
    2.times { failing.hostname("x") }
    expect(calls.size).to eq(3)
  end
end
