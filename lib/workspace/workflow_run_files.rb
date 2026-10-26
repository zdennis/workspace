module Workspace
  # Lists the files a workflow run keeps, from the run's own JSON: each
  # attempt's prompt and check log (when recorded) and each step's `produces`
  # entries. Reads nothing but `File.lstat`: a symlink is reported as a link
  # and never followed, so its target's size and contents are never touched.
  # A path outside the run's artifacts directory is left out.
  class WorkflowRunFiles
    # @param run [Hash] a run as {WorkflowRunStore#find} returns it
    # @return [Array<Hash>] rows with "path" (absolute), "kind" (`prompt`,
    #   `check_log` or `produces`), "step", "attempt" (nil for `produces`),
    #   "exists", "bytes" (nil when missing, a link or not a regular file)
    #   and, for a symlink, "link" true
    def list(run)
      dir = artifacts_dir(run)
      return [] unless dir
      artifacts = File.expand_path(dir)
      rows = []
      Array(run.dig("definition", "steps")).each do |step|
        id = step["id"]
        Array(run.dig("steps", id, "attempts")).each do |attempt|
          rows << row(artifacts, attempt["prompt_file"], "prompt", id, attempt["n"])
          rows << row(artifacts, attempt.dig("check", "log"), "check_log", id, attempt["n"])
        end
        Array(step["produces"]).each { |file| rows << row(artifacts, File.join(artifacts, file.to_s), "produces", id, nil) }
      end
      rows.compact
    end

    # @return [String, nil] the run's artifacts directory, `<worktree>/.workflow/<id>` for an older run without one; nil when it has neither
    def artifacts_dir(run)
      return run["artifacts_dir"] if run["artifacts_dir"]
      File.join(run["worktree"], ".workflow", run["id"].to_s) if run["worktree"].is_a?(String) && !run["worktree"].empty?
    end

    private

    def row(artifacts, path, kind, step, attempt)
      return nil unless path.is_a?(String) && !path.empty?
      path = File.expand_path(path)
      return nil unless inside?(artifacts, path)
      base = {"path" => path, "kind" => kind, "step" => step, "attempt" => attempt}
      stat = File.lstat(path)
      return base.merge("exists" => true, "bytes" => nil, "link" => true) if stat.symlink?
      base.merge("exists" => true, "bytes" => stat.file? ? stat.size : nil)
    rescue SystemCallError
      base.merge("exists" => false, "bytes" => nil)
    end

    # On a directory boundary, and not through a linked directory that leads out.
    def inside?(artifacts, path)
      return false unless path.start_with?(artifacts.chomp("/") + "/")
      real_root = File.realpath(artifacts)
      real_parent = File.realpath(File.dirname(path))
      real_parent == real_root || real_parent.start_with?(real_root.chomp("/") + "/")
    rescue SystemCallError
      true
    end
  end
end
