require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowExecProgram do
  around do |example|
    Dir.mktmpdir("exec-program") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def program(*parts, mode: 0o755)
    path = File.join(@dir, *parts)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n")
    File.chmod(mode, path)
    path
  end

  def problem(argv0, checkout: nil, path: File.join(@dir, "bin"), home: @dir)
    described_class.problem(argv0, checkout: checkout, path: path, home: home)
  end

  it "accepts a bare name found on PATH" do
    program("bin", "check")
    expect(problem("check")).to be_nil
  end

  it "refuses a bare name that is not on PATH, or is there without the executable bit" do
    program("bin", "plain", mode: 0o644)
    expect(problem("nothing")).to eq("is not on PATH")
    expect(problem("plain")).to eq("is not on PATH")
  end

  it "ignores empty PATH entries and a nil PATH" do
    expect(problem("check", path: "")).to eq("is not on PATH")
    expect(problem("check", path: nil)).to eq("is not on PATH")
  end

  it "accepts an absolute executable file and refuses a missing, plain or directory path" do
    expect(problem(program("tools", "run"))).to be_nil
    expect(problem(File.join(@dir, "gone"))).to match(/does not exist/)
    expect(problem(program("tools", "plain", mode: 0o644))).to match(/is not executable/)
    expect(problem(File.join(@dir, "tools"))).to match(/is not a file/)
  end

  it "reads ~/ against HOME, and calls it missing with no HOME" do
    program("tools", "run")
    expect(problem("~/tools/run")).to be_nil
    expect(problem("~/tools/none")).to match(/does not exist/)
    expect(problem("~/tools/run", home: nil)).to eq("starts with ~/ and HOME is not set")
  end

  it "resolves a relative path with a slash against the checkout" do
    program("co", "script", "check")
    expect(problem("script/check", checkout: File.join(@dir, "co"))).to be_nil
    expect(problem("script/other", checkout: File.join(@dir, "co"))).to match(/does not exist/)
  end

  it "does not judge a relative path when there is no checkout yet" do
    expect(problem("script/check", checkout: nil)).to be_nil
    expect(problem("script/check", checkout: File.join(@dir, "absent"))).to be_nil
  end

  it "refuses an empty program" do
    expect(problem("")).to eq("is empty")
  end
end
