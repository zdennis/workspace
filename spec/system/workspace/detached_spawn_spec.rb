require "spec_helper"
require "rbconfig"
require "tmpdir"

RSpec.describe Workspace::DetachedSpawn do
  around do |example|
    saved = ENV.values_at("TMUX", "TMUX_PANE")
    ENV["TMUX"] = "/tmp/tmux-test,1,2"
    ENV["TMUX_PANE"] = "%99"
    example.run
  ensure
    ENV["TMUX"], ENV["TMUX_PANE"] = saved
  end

  it "runs the command in a new session with TMUX and TMUX_PANE removed, stdin from /dev/null, its output and exit in the log" do
    Dir.mktmpdir do |dir|
      waits = []
      log = File.join(dir, "logs", "run.log")
      script = <<~'RUBY'
        puts "sid=#{Process.getsid(0)}"
        puts "pgid=#{Process.getpgid(0)}"
        puts "tmux=#{ENV["TMUX"].inspect} pane=#{ENV["TMUX_PANE"].inspect} mark=#{ENV["MARK"]}"
        puts "stdin_null=#{$stdin.stat.rdev == File.stat(File::NULL).rdev}"
        warn "to-stderr"
        exit 3
      RUBY
      spawner = described_class.new(reaper: ->(pid) { waits << Process.detach(pid) })

      pid = spawner.call([RbConfig.ruby, "-e", script], log_path: log, env: {"MARK" => "yes"})
      status = waits.first.value

      text = File.read(log)
      expect(status.exitstatus).to eq(3)
      expect(text[/sid=(\d+)/, 1].to_i).to eq(pid)
      expect(text[/sid=(\d+)/, 1].to_i).not_to eq(Process.getsid(0))
      expect(text[/pgid=(\d+)/, 1].to_i).not_to eq(Process.getpgid(0))
      expect(text).to include("tmux=nil pane=nil mark=yes", "stdin_null=true", "to-stderr")
      expect(text.lines.last).to match(/\A\[\S+\] exited 3\n\z/)
      expect(File.stat(log).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(log)).mode & 0o777).to eq(0o700)
    end
  end

  it "logs a command that can't start" do
    Dir.mktmpdir do |dir|
      waits = []
      log = File.join(dir, "run.log")
      described_class.new(reaper: ->(pid) { waits << Process.detach(pid) }).call([File.join(dir, "missing")], log_path: log)

      expect(waits.first.value.exitstatus).to eq(127)
      expect(File.read(log)).to match(/could not start .*missing/)
    end
  end
end
