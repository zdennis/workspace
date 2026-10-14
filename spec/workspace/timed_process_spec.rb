require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::TimedProcess do
  it "returns stdout, stderr and success" do
    expect(described_class.run(["sh", "-c", "echo out; echo err >&2"], chdir: Dir.pwd, timeout: 5)).to eq(["out\n", "err\n", true])
  end

  it "reports a failing command as not successful" do
    expect(described_class.run(["sh", "-c", "exit 3"], chdir: Dir.pwd, timeout: 5).last).to be(false)
  end

  it "runs in the given directory" do
    Dir.mktmpdir do |dir|
      out, = described_class.run(["pwd"], chdir: dir, timeout: 5)

      expect(File.realpath(out.strip)).to eq(File.realpath(dir))
    end
  end

  it "tells gh and git not to ask questions" do
    out, = described_class.run(["sh", "-c", "echo $GH_PROMPT_DISABLED $GIT_TERMINAL_PROMPT"], chdir: Dir.pwd, timeout: 5)

    expect(out).to eq("1 0\n")
  end

  it "closes stdin so a command that reads it does not wait" do
    expect(described_class.run(["cat"], chdir: Dir.pwd, timeout: 5)).to eq(["", "", true])
  end

  it "stops the whole process group and raises when time runs out" do
    expect { described_class.run(["sh", "-c", "sleep 5 & sleep 5"], chdir: Dir.pwd, timeout: 0.2) }.to raise_error(Timeout::Error)
  end

  it "raises Errno::ENOENT for a command that is not installed" do
    expect { described_class.run(["workspace-no-such-tool"], chdir: Dir.pwd, timeout: 1) }.to raise_error(Errno::ENOENT)
  end
end
