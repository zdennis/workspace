module Workspace
  # Reads and writes run results to ~/.workspace-runs/.
  #
  # File layout for a given UUID:
  #   <uuid>.json    — complete result (written atomically via rename)
  #   <uuid>.stdout  — raw stdout (written by shell redirection before report-run-status)
  #   <uuid>.stderr  — raw stderr (written by shell redirection before report-run-status)
  #
  # Result files accumulate indefinitely — there is no TTL or automatic cleanup.
  # Callers that generate many runs are responsible for pruning the directory.
  class RunResultStore
    DEFAULT_POLL_INTERVAL = 0.1
    DEFAULT_TIMEOUT = 300

    # @param config [Workspace::Config]
    def initialize(config:)
      @config = config
    end

    # @return [void]
    def ensure_dir
      FileUtils.mkdir_p(@config.run_results_dir)
    end

    # @param result [Workspace::RunResult]
    # @return [void]
    def write(result)
      ensure_dir
      path = @config.run_result_path(result.uuid)
      tmp = "#{path}.tmp"
      File.write(tmp, result.to_json)
      File.rename(tmp, path)
    end

    # @param uuid [String]
    # @return [Workspace::RunResult, nil]
    def read(uuid)
      path = @config.run_result_path(uuid)
      return nil unless File.exist?(path)
      RunResult.from_json(File.read(path))
    end

    # @param uuid [String]
    # @return [Boolean]
    def exist?(uuid)
      File.exist?(@config.run_result_path(uuid))
    end

    # @param uuid [String]
    # @return [String]
    def read_stdout(uuid)
      path = @config.run_stdout_path(uuid)
      File.exist?(path) ? File.read(path) : ""
    end

    # @param uuid [String]
    # @return [String]
    def read_stderr(uuid)
      path = @config.run_stderr_path(uuid)
      File.exist?(path) ? File.read(path) : ""
    end

    # Block until result JSON appears or timeout.
    #
    # @param uuid [String]
    # @param timeout [Numeric]
    # @param poll_interval [Numeric]
    # @return [Workspace::RunResult]
    # @raise [Workspace::Error] on timeout, or if the result file vanishes mid-read
    def wait(uuid, timeout: DEFAULT_TIMEOUT, poll_interval: DEFAULT_POLL_INTERVAL)
      elapsed = 0.0
      until exist?(uuid)
        if elapsed >= timeout
          raise Workspace::Error,
            "Timed out waiting for run #{uuid} to complete (#{timeout}s).\n" \
            "Ensure 'workspace' is on PATH in the tmux pane's shell."
        end
        sleep poll_interval
        elapsed += poll_interval
      end

      # exist? and read are separate stats, so the file can disappear in between.
      result = read(uuid)
      unless result
        raise Workspace::Error, "Run result for #{uuid} disappeared before it could be read"
      end
      result
    end
  end
end
