require "json"

module Workspace
  # Tells whether a workflow run is still going, for the lock store: a
  # `kind: "run"` lock holder or waiter lives exactly as long as its run.
  #
  # A run is alive while `<dir>/<run id>.json` exists and its `state` is not
  # a finished one. A run with no file is not alive, so a run file has to be
  # written before the run takes its first lock.
  class RunLiveness
    # The run states after which a run holds nothing.
    TERMINAL_STATES = %w[completed failed cancelled].freeze

    # Run ids become file names, so only names that can't leave +dir+ count.
    ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    # @param dir [String] the directory holding one `<run id>.json` per run
    def initialize(dir:)
      @dir = dir
    end

    # @param run_id [String]
    # @return [Boolean] whether the run has a run file that is not finished
    # @raise [Workspace::Error] if the run file exists but can't be read or
    #   parsed, since the run's state is then unknown rather than finished
    def alive?(run_id)
      return false unless run_id.is_a?(String) && ID_PATTERN.match?(run_id)
      path = File.join(@dir, "#{run_id}.json")
      run = JSON.parse(File.read(path))
      raise Workspace::Error, "#{path} is not a run file" unless run.is_a?(Hash)
      !TERMINAL_STATES.include?(run["state"])
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    rescue JSON::ParserError, SystemCallError => e
      raise Workspace::Error, "could not read #{path} (#{e.class})"
    end
  end
end
