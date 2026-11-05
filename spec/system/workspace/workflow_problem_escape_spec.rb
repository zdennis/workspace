require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "invalid_workflow problem lines through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-escape") do |dir|
      saved = ENV.to_h
      @home = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@home, ".config", "workspace", "workflows"))
      @bad = File.join(@home, "bad.yml")
      File.write(@bad, "title: x\nsteps:\n  \"a\\e[31m\":\n    \"bogus\\e[1m\": 1\n    prompt: hi\ninputs:\n  \"n\\e[2m\": {}\n")
      FileUtils.cp(@bad, File.join(@home, ".config", "workspace", "workflows", "bad.yml"))
      begin
        ENV.replace("HOME" => @home, "PATH" => ENV["PATH"])
        ENV.delete("TMUX")
        ENV.delete("TMUX_PANE")
        Dir.chdir(@home) { example.run }
      ensure
        ENV.replace(saved)
      end
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def run_cli(*args)
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", *args])
  rescue SystemExit
    nil
  end

  def commands
    [["validate", @bad], ["show", "bad"], ["show", "bad", "--source"], ["render", "bad", "a"], ["add", "bad2", @bad], ["update", "bad", @bad], ["start", "bad", "x"], ["show"]]
  end

  it "prints no raw control character in text mode on any path" do
    commands.each do |args|
      out.truncate(0)
      err.truncate(0)
      run_cli(*args)
      expect(out.string + err.string).not_to match(/\e/), "raw ESC from #{args.join(" ")}"
    end
  end

  it "shows the escaped step, key and input name in the problem lines" do
    run_cli("validate", @bad)
    expect(err.string).to include("step a\\e[31m has unknown key bogus\\e[1m", "n\\e[2m")
  end

  it "escapes the problem on a list row" do
    key_only = File.join(@home, ".config", "workspace", "workflows", "keyonly.yml")
    File.write(key_only, "title: x\nsteps:\n  a:\n    \"bogus\\e[1m\": 1\n    prompt: hi\n")
    run_cli("show")
    row = out.string.lines.grep(/keyonly/).first
    expect(row).to include("INVALID: step a has unknown key bogus\\e[1m")
    expect(out.string).not_to match(/\e/)
  end

  it "keeps trailing blank lines of an error message" do
    cli = Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {})
    allow_any_instance_of(Workspace::CLI).to receive(:cmd_workflow).and_raise(Workspace::Error.new("boom\n\n\n"))
    begin
      cli.run(["workflow", "show"])
    rescue SystemExit
      nil
    end
    expect(err.string).to eq("Error: boom\n\n\n")
  end

  it "leaves the --json problems unchanged (control characters as JSON escapes)" do
    run_cli("validate", @bad, "--json")
    doc = JSON.parse(out.string)
    expect(doc["code"]).to eq("invalid_workflow")
    expect(doc["details"]["problems"].join).to include("a\e[31m")
    expect(out.string).not_to match(/\e/)
  end
end
