require "fileutils"
require "rbconfig"

module Workspace
  # Starts a command that outlives the terminal it was started from: a Ruby wrapper that first
  # leaves the caller's session and process group (`Process.setsid`, so the hangup tmux sends a
  # killed session's process group never reaches it), then runs the command and appends one line
  # with its exit to the log. stdin is `/dev/null`, stdout and stderr the log; `TMUX` and
  # `TMUX_PANE` are removed, so nothing in it thinks it runs inside the caller's tmux session.
  # Its only caller is {CLI::Relauncher#detach}.
  class DetachedSpawn
    # Run by the spawned Ruby: setsid, the command, then its exit as the log's last line.
    WRAPPER = <<~'RUBY'
      Process.setsid
      $stdout.sync = true
      begin
        pid = Process.spawn(*ARGV)
        _, status = Process.wait2(pid)
        $stdout.puts "[#{Time.now.utc.iso8601}] exited #{status.exitstatus.nil? ? "on signal #{status.termsig}" : status.exitstatus}"
        exit(status.exitstatus || 1)
      rescue SystemCallError => e
        $stdout.puts "[#{Time.now.utc.iso8601}] could not start #{ARGV.first}: #{e.message}"
        exit 127
      end
    RUBY

    # @param ruby [String] the Ruby that runs the wrapper
    # @param spawner [#call] `Process.method(:spawn)`'s shape, replaced in specs that check the arguments
    # @param reaper [#call] given the pid, so the child is never left a zombie (`Process.method(:detach)`)
    def initialize(ruby: RbConfig.ruby, spawner: Process.method(:spawn), reaper: Process.method(:detach))
      @ruby = ruby
      @spawner = spawner
      @reaper = reaper
    end

    # @param argv [Array<String>] the command, run without a shell
    # @param log_path [String] appended to (made 0600, its directory 0700)
    # @param env [Hash{String=>String}] added to the environment
    # @return [Integer] the wrapper's pid
    # @raise [SystemCallError] when the log can't be made or the wrapper can't start; nothing ran then
    def call(argv, log_path:, env: {})
      FileUtils.mkdir_p(File.dirname(log_path), mode: 0o700)
      child_env = {"TMUX" => nil, "TMUX_PANE" => nil}.merge(env)
      pid = @spawner.call(child_env, @ruby, "-rtime", "-e", WRAPPER, "--", *argv,
        :in => File::NULL, [:out, :err] => [log_path, File::WRONLY | File::CREAT | File::APPEND, 0o600])
      @reaper.call(pid)
      pid
    end
  end
end
