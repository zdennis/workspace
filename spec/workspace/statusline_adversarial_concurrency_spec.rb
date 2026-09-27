require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe "Statusline adversarial concurrency" do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-statusline-conc")) }
  let(:renderer) do
    Class.new do
      def render(_payload) = "built-in line"
    end.new
  end
  let(:context_store) { Workspace::ContextStore.new(path: File.join(tmpdir, "state", "context.json")) }
  let(:output) { StringIO.new }
  let(:pidfile) { File.join(tmpdir, "grandchild.pid") }

  after do
    kill_grandchild
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  def settings_for(command)
    Struct.new(:command) do
      def load_global = {"statusline" => {"command" => command}}
    end.new(command)
  end

  def statusline(command)
    Workspace::Commands::Statusline.new(
      context_store: context_store,
      renderer: renderer,
      project_settings: settings_for(command),
      env: {"TMUX_PANE" => "%1"},
      input: StringIO.new(JSON.generate("context_window" => {"used_percentage" => 40})),
      output: output,
      delegate_timeout: 1
    )
  end

  def grandchild_pid
    Integer(File.read(pidfile).strip) if File.exist?(pidfile) && !File.read(pidfile).strip.empty?
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def kill_grandchild
    pid = grandchild_pid
    Process.kill(:KILL, pid) if pid
  rescue Errno::ESRCH
    nil
  end

  it "C1: a delegate that exits but leaves a background child holding stdout still returns within the timeout" do
    command = "echo delegated; sleep 30 & echo $! > #{pidfile}"
    runner = Thread.new { statusline(command).call }
    finished = runner.join(4)

    kill_grandchild
    runner.join

    expect(finished).not_to be_nil, "statusline blocked on the delegate's stdout after the delegate exited"
  end

  it "C2: a timed-out delegate's child processes are killed along with it" do
    command = "sleep 30 & echo $! > #{pidfile}; wait"
    statusline(command).call

    pid = grandchild_pid
    expect(pid).not_to be_nil
    expect(output.string).to eq("built-in line")
    expect(alive?(pid)).to be(false), "delegate's child #{pid} was left running after the timeout"
  end

  describe Workspace::ProjectSettings do
    let(:config) { Struct.new(:workspace_config_dir).new(File.join(tmpdir, "config")) }
    let(:settings) { described_class.new(config: config) }

    it "C3: a concurrent load_global never sees a missing statusline.command while config set rewrites the global config" do
      data = {"statusline" => {"command" => "my-statusline"}, "layouts" => {"pad" => "x"}}
      settings.save_global(data)

      writer = fork do
        loop { settings.save_global(data) }
      ensure
        exit!(0)
      end

      misses = 0
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline && misses.zero?
          misses += 1 unless settings.load_global.dig("statusline", "command") == "my-statusline"
        end
      ensure
        Process.kill(:KILL, writer)
        Process.wait(writer)
      end

      expect(misses).to eq(0), "a reader saw a truncated/empty global config mid-write"
    end
  end
end
