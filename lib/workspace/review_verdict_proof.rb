require "json"

module Workspace
  # Whether a verdict file in a review round's directory was written by a sub-agent of the round's review pane,
  # read from the agent daemon's hook event log ({HookEventLog}): the last successful Write, Edit or MultiEdit
  # (`tool_finished`, `ok: true`) on the file's checkout-relative path must come from the review pane, carry a
  # sub-agent's `agent_id`, and carry the `sha256` `session-event` took of the file on disk, which must still be
  # the file's hash now. An Edit after the Write is fine: only the last write counts. A line missing after that
  # write (a `seq` skipped, or another daemon's `boot_id`) may have been a later write, so it proves nothing.
  #
  # Not proven: that the hook lines are genuine (a process can send `session-event` a made-up payload).
  class ReviewVerdictProof
    # The tools whose writes `session-event` hashes for a review pane.
    TOOLS = %w[Write Edit MultiEdit].freeze

    # The largest verdict hashed, as `session-event` hashes it.
    MAX_BYTES = 1_048_576

    # @param hook_dir [String, nil] the directory of every daemon's hook event file ({Config#hook_events_dir});
    #   nil proves nothing
    # @param max_bytes [Integer] the largest file hashed
    def initialize(hook_dir:, max_bytes: MAX_BYTES)
      @hook_dir = hook_dir
      @max_bytes = max_bytes
    end

    # @param round_dir [String] the round's directory, absolute
    # @param path [String] the verdict file, absolute, in +round_dir+
    # @param review_pane [String] the round's review pane id
    # @param workspace [String] the run's workspace, whose daemon wrote the hook lines
    # @return [Hash{Symbol=>Object}] :ok, :agent_id and :sha256 of the write that proves it (nil when unknown),
    #   and :problem (nil when proven): `no_log`, `outside_checkout`, `no_write`, `log_gap`, `other_pane`,
    #   `main_thread`, `no_hash`, `unreadable` or `hash_mismatch`
    def proven?(round_dir:, path:, review_pane:, workspace:)
      files = log_files(workspace)
      return refused("no_log") if files.empty?
      relative = relative_path(round_dir, path)
      return refused("outside_checkout") unless relative
      last, gap = last_write(files, relative)
      return refused("no_write") unless last
      return refused("log_gap") if gap
      return refused("other_pane") unless last["pane_id"] == review_pane
      agent = last["agent_id"]
      return refused("main_thread") unless agent.is_a?(String) && !agent.empty?
      sha = last["sha256"]
      return refused("no_hash", agent) unless sha.is_a?(String) && sha.match?(/\A\h{64}\z/)
      content = WorkflowProduced.digest(path, max_bytes: @max_bytes)
      return refused("unreadable", agent) unless content&.sha256
      return refused("hash_mismatch", agent) unless content.sha256 == sha
      {ok: true, agent_id: agent, sha256: sha, problem: nil}
    end

    private

    def refused(problem, agent = nil) = {ok: false, agent_id: agent, sha256: nil, problem: problem}

    # The rotated file first, then the live one: their lines in the order they were written.
    def log_files(workspace)
      return [] unless @hook_dir.is_a?(String) && workspace.is_a?(String) && !workspace.empty?
      return [] unless File.basename(workspace) == workspace && !workspace.start_with?(".")
      live = HookEventLog.path_for(@hook_dir, workspace)
      ["#{live}.1", live].select { |file| File.file?(file) }
    end

    # The path as `session-event` writes it: relative to the checkout above the round's directory.
    def relative_path(round_dir, path)
      root = ReviewRoundPath.checkout_root(round_dir)
      (root && path.start_with?("#{root}/")) ? path.delete_prefix("#{root}/") : nil
    end

    # The last successful write to +relative+, and whether a line after it is missing.
    def last_write(files, relative)
      needle = JSON.generate(relative)
      last = nil
      gap = false
      previous = nil
      files.each do |file|
        File.foreach(file) do |text|
          # Lines before the first mention of the path are never needed.
          next unless last || text.include?(needle)
          line = parse(text)
          if last && !gap
            gap = true unless line && previous && line["boot_id"] == previous[0] && line["seq"] == previous[1] + 1
          end
          previous = (line && line["seq"].is_a?(Integer)) ? [line["boot_id"], line["seq"]] : nil
          if line && write?(line, relative)
            last = line
            gap = false
          end
        end
      end
      [last, gap]
    rescue SystemCallError, IOError
      [nil, false]
    end

    def write?(line, relative)
      line["type"] == "tool_finished" && line["ok"] == true && TOOLS.include?(line["tool"]) && line["path"] == relative
    end

    def parse(text)
      line = JSON.parse(text)
      line.is_a?(Hash) ? line : nil
    rescue JSON::ParserError
      nil
    end
  end
end
