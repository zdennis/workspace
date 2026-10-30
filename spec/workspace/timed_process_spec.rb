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

  it "passes env to the child over the no-prompt variables" do
    out, _, success = described_class.run(["sh", "-c", "echo $LC_ALL $GIT_TERMINAL_PROMPT"], chdir: Dir.pwd, timeout: 5, env: {"LC_ALL" => "C"})

    expect(success).to be true
    expect(out.strip).to eq("C 0")
  end

  describe "encoding" do
    it "returns non-ASCII stdout as UTF-8 without a cap" do
      out, = described_class.run(["printf", "café"], chdir: Dir.pwd, timeout: 5)

      expect(out.encoding).to eq(Encoding.default_external)
      expect(out).to eq("café")
    end

    it "returns non-ASCII stdout as UTF-8 with a cap, even across a chunk boundary" do
      text = "é" * 70_000
      out, = described_class.run(["sh", "-c", "yes é | head -n 70000 | tr -d '\n'"], chdir: Dir.pwd, timeout: 10, max_bytes: 1_000_000)

      expect(out.encoding).to eq(Encoding.default_external)
      expect(out).to eq(text)
    end
  end

  describe "max_bytes" do
    it "stops a real child that writes past the cap and raises OutputTooLarge" do
      started = Time.now

      expect {
        described_class.run(["sh", "-c", "yes x; sleep 5"], chdir: Dir.pwd, timeout: 10, max_bytes: 200_000)
      }.to raise_error(described_class::OutputTooLarge)
      expect(Time.now - started).to be < 4
    end

    it "returns output at or under the cap" do
      out, = described_class.run(["sh", "-c", "printf abcde"], chdir: Dir.pwd, timeout: 5, max_bytes: 5)

      expect(out).to eq("abcde")
    end

    it "reads without a cap by default" do
      out, = described_class.run(["sh", "-c", "head -c 300000 /dev/zero | tr \\0 a"], chdir: Dir.pwd, timeout: 5)

      expect(out.bytesize).to eq(300_000)
    end
  end
end
