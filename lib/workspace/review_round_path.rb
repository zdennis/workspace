module Workspace
  # Where a review pane's round writes its verdict: the round directory
  # `<run's artifacts>/reviews/<step>.<attempt>.r<round>/`, from the reviewer
  # binding. The one derivation `session-event` uses to hash a verdict file
  # after a write ({Commands::SessionEvent}) and to refuse any other write
  # before it ({ReviewWriteGuard}).
  module ReviewRoundPath
    # The file the engine writes to a round's directory; no reviewer writes it.
    SUMMARY = "summary.md"

    # @param entry [Object] a pane binding
    # @return [Boolean] whether it is a complete reviewer binding of a run
    def self.reviewer?(entry)
      entry.is_a?(Hash) && entry["kind"] == "run" && entry["role"] == "reviewer" &&
        entry["id"].is_a?(String) && entry["step"].is_a?(String) &&
        entry["attempt"].is_a?(Integer) && entry["round"].is_a?(Integer)
    end

    # @param artifacts [String] the run's directory
    # @param step [String] the reviewed step's id
    # @param attempt [Integer] the reviewed attempt's n
    # @param round [Integer] the round
    # @return [String] the round's directory, `<artifacts>/reviews/<step>.<attempt>.r<round>`
    def self.round_dir(artifacts, step, attempt, round)
      File.join(artifacts, "reviews", "#{step}.#{attempt}.r#{round}")
    end

    # The path a tool call names, when it is a file under the round's directory
    # with no link on the way down. A part that does not exist yet is not a link,
    # so a file about to be created is accepted.
    #
    # @param entry [Hash] a reviewer binding ({reviewer?})
    # @param raw [Object] the tool's path as given
    # @param cwd [String, nil] the hook's working directory
    # @param direct [Boolean] accept only a file directly in the round directory, and never
    #   `summary.md`, which the engine writes
    # @return [String, nil] the absolute path, or nil for anything else
    def self.verdict_path(entry, raw, cwd, direct: false)
      return nil unless cwd.is_a?(String) && !cwd.empty? && raw.is_a?(String) && !raw.empty? && !raw.match?(/[[:cntrl:]]/)
      # The binding's `artifacts` is the run's directory. T30 records it on the reviewer
      # binding; until then (no value) the checkout found above the hook's cwd stands in.
      artifacts = entry["artifacts"]
      if artifacts.is_a?(String) && artifacts.start_with?("/") && !artifacts.match?(/[[:cntrl:]]/)
        base = File.expand_path(artifacts)
        linked = [base]
      else
        root = checkout_root(File.expand_path(cwd))
        return nil unless root
        base = File.join(root, ".workflow", entry["id"])
        linked = []
      end
      dir = round_dir(base, entry["step"], entry["attempt"], entry["round"])
      path = File.expand_path(raw, cwd)
      return nil unless path.start_with?("#{dir}/")
      return nil if direct && (path.delete_prefix("#{dir}/").include?("/") || File.basename(path) == SUMMARY)
      # No link on the way from the run's directory (or the checkout) down to the file, or
      # the write would land elsewhere. The checkout's own path may hold links.
      start = linked.empty? ? File.dirname(File.dirname(base)) : File.dirname(base)
      walked = linked.empty? ? start : base
      walk = (linked.empty? ? path.delete_prefix("#{start}/") : path.delete_prefix("#{base}/")).split("/")
      linked.each { |own| return nil if lstat_link?(own) }
      walk.each do |part|
        walked = File.join(walked, part)
        return nil if lstat_link?(walked)
      end
      path
    end

    # @param dir [String] an absolute directory
    # @return [String, nil] the nearest directory at or above it holding `.git`
    def self.checkout_root(dir)
      loop do
        return dir if File.exist?(File.join(dir, ".git"))
        parent = File.dirname(dir)
        return nil if parent == dir
        dir = parent
      end
    end

    # A part that is not there is no link; anything else that goes wrong raises.
    def self.lstat_link?(path)
      File.lstat(path).symlink?
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end
    private_class_method :lstat_link?
  end
end
