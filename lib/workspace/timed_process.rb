require "open3"
require "timeout"

module Workspace
  # Runs one command with a time limit, without a prompt: stdin is closed, `gh`
  # and `git` are told not to ask, and the command runs in its own process group
  # that is stopped when the time is up.
  module TimedProcess
    NO_PROMPT = {"GH_PROMPT_DISABLED" => "1", "GIT_TERMINAL_PROMPT" => "0"}.freeze

    # @param argv [Array<String>] the command and its arguments
    # @param chdir [String] directory to run in
    # @param timeout [Numeric] seconds
    # @return [Array(String, String, Boolean)] stdout, stderr, success
    # @raise [Errno::ENOENT] if the command is not installed
    # @raise [Timeout::Error] if it ran past +timeout+
    def self.run(argv, chdir:, timeout:)
      Open3.popen3(NO_PROMPT, *argv, chdir: chdir, pgroup: true) do |stdin, stdout, stderr, waiter|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        [out, err].each { |reader| reader.report_on_exception = false }
        unless waiter.join(timeout)
          stop_group(waiter)
          raise Timeout::Error
        end
        [out.value, err.value, waiter.value.success?]
      end
    end

    def self.stop_group(waiter)
      Process.kill("TERM", -waiter.pid)
      Process.kill("KILL", -waiter.pid) unless waiter.join(1)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    private_class_method :stop_group
  end
end
