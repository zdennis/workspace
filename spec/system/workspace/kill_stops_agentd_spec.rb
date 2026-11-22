require "spec_helper"
require "open3"
require "tmpdir"
require "socket"

# A real `workspace agentd` in a throwaway HOME, torn down by the real
# `workspace stop NAME`. Nothing here signals a process this spec did not spawn.
RSpec.describe "workspace stop and a real agent daemon" do
  let(:home) { Dir.mktmpdir("wsagd", "/tmp") }
  let(:name) { "stopagentd#{Process.pid}" }
  let(:env) do
    {
      "HOME" => home,
      "XDG_CONFIG_HOME" => File.join(home, "config"),
      "XDG_STATE_HOME" => File.join(home, "state"),
      "XDG_CACHE_HOME" => File.join(home, "cache"),
      "XDG_DATA_HOME" => File.join(home, "data"),
      "TMUX_TMPDIR" => home,
      "TMUX" => nil,
      "TMUX_PANE" => nil
    }
  end
  let(:bin) { File.join(PROJECT_ROOT, "bin", "workspace") }
  let(:log) { File.join(home, "agentd.out") }

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    true
  end

  def socket_files
    Dir.glob(File.join(home, "**", "*#{name}*.sock"), File::FNM_DOTMATCH)
  end

  def answering?
    socket_files.any? do |path|
      UNIXSocket.open(path, &:close)
      true
    rescue SystemCallError
      false
    end
  end

  let(:config_path) { File.join(home, ".config", "tmuxinator", "workspace.#{name}.yml") }

  it "ends the daemon and removes its socket when its workspace is stopped by name" do
    FileUtils.mkdir_p(File.dirname(config_path))
    File.write(config_path, "name: #{name}\nroot: #{home}\nwindows:\n  - main: echo\n")
    pid = Process.spawn(env, RbConfig.ruby, bin, "agentd", "--name", name, out: log, err: log, in: File::NULL)
    reaper = Process.detach(pid)
    begin
      expect(wait_until(20) { answering? }).to be(true), "daemon never answered; log: #{File.exist?(log) ? File.read(log) : "no log"}"

      File.delete(config_path) # as `kill` removes the config before the daemon is stopped

      out, status = Open3.capture2e(env, RbConfig.ruby, bin, "stop", name)
      expect(status).to be_success, out

      expect(out).to include("Stopped agent daemon for #{name}")
      expect(wait_until(10) { !alive?(pid) && reaper.join(0) }).to be(true), "daemon still running; stop said: #{out}"
      expect(socket_files).to be_empty
    ensure
      Process.kill("KILL", pid) if alive?(pid) && reaper.alive?
      reaper.join
      FileUtils.remove_entry(home)
    end
  end
end
