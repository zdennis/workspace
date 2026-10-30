require_relative "timed_process"

module Workspace
  # Asks ssh which real host a name in a remote URL stands for (`ssh -G NAME`, which reads
  # `~/.ssh/config` and makes no connection, but does run the user's own `Match exec` commands).
  class SshHostResolver
    TIMEOUT = 5
    HOST_TOKEN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    # @param runner [#call] `(argv, chdir:, timeout:)` returning `[stdout, stderr, success]`
    def initialize(runner: TimedProcess.method(:run))
      @runner = runner
      @answers = {}
    end

    # @param name [String] the host as written in a remote URL
    # @return [String, nil] the `hostname` ssh reports, lowercased; nil for a name that is not a plain
    #   hostname (ssh is not run), an answer that is not one, or a failed or timed-out ssh. Each name is
    #   asked once.
    def hostname(name)
      return nil unless name.to_s.match?(HOST_TOKEN)

      @answers.fetch(name) { @answers[name] = ask(name) }
    end

    private

    def ask(name)
      stdout, _, success = @runner.call(["ssh", "-G", "--", name], chdir: "/", timeout: TIMEOUT)
      return nil unless success

      host = stdout.to_s.lines.filter_map { |line| line.strip[/\Ahostname\s+(\S+)\z/i, 1] }.first
      host&.match?(HOST_TOKEN) ? host.downcase : nil
    rescue SystemCallError, Timeout::Error
      nil
    end
  end
end
