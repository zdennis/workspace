require "open3"
require "securerandom"
require "time"

module Workspace
  module Commands
    # Runs a shell command as a Ruby subprocess, captures stdout/stderr/exit,
    # stores the result via RunResultStore, and returns the RunResult.
    class RunAndReport
      # @param run_result_store [Workspace::RunResultStore]
      def initialize(run_result_store:)
        @run_result_store = run_result_store
      end

      # Run +command+ in a subprocess and return the captured RunResult.
      #
      # @param command [String]
      # @param project [String, nil]
      # @param dir [String, nil]
      # @return [Workspace::RunResult]
      def call(command, project: nil, dir: nil)
        uuid = SecureRandom.uuid
        started_at = Time.now.utc.iso8601

        capture_opts = {}
        if dir
          unless File.directory?(dir)
            raise Workspace::Error, "run-and-report: directory does not exist: #{dir}"
          end
          capture_opts[:chdir] = dir
        end

        stdout, stderr, process_status = Open3.capture3("sh", "-c", command, **capture_opts)

        finished_at = Time.now.utc.iso8601

        result = RunResult.new(
          uuid: uuid,
          project: project,
          command: command,
          # exitstatus is nil when the child was killed by a signal; fall back to the
          # shell convention of 128 + signal number so callers always see an integer.
          status: process_status.exitstatus || (128 + process_status.termsig.to_i),
          stdout: stdout,
          stderr: stderr,
          started_at: started_at,
          finished_at: finished_at
        )

        @run_result_store.write(result)
        result
      end
    end
  end
end
