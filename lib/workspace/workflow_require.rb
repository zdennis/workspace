module Workspace
  # The engine's check of a step's `require:` list: built-in proofs about the
  # repository and the run's files, run when an attempt's turn ends, after
  # `produces` and before `status:`. Each proof is a single-key mapping of the
  # step's definition (`{"commits" => 1}`) and the first that fails stops the
  # check. A proof that can't be read (no recorded starting commit, git not
  # answering, a file or plan that can't be read) fails as unproven: it never
  # passes. Nothing here raises.
  #
  # The proofs: `commits` (at least N commits since the attempt began, from the
  # attempt's `head.before`), `nonempty` (a file under the run's artifacts
  # directory is a non-empty regular file, not a link), `plan_status` (the
  # workspace plan's `status:` is the value) and `tracked_clean` (no tracked
  # file differs from HEAD and no rebase, merge, cherry-pick, revert or bisect is under way; submodules and
  # `assume-unchanged`/`skip-worktree` files are not seen). Git runs through {WorkflowGuard}, so it ignores
  # the user's and the system's config and every inherited `GIT_*` variable.
  class WorkflowRequire
    # The proofs a definition may name.
    PROOFS = %w[commits nonempty plan_status tracked_clean].freeze

    # @param guard [Workspace::WorkflowGuard] reads the checkout through hardened git calls
    # @param notes_dir_of [#call] given a workspace name, its notes directory, or nil when it can't be found
    def initialize(guard:, notes_dir_of:)
      @guard = guard
      @notes_dir_of = notes_dir_of
    end

    # @param run [Hash{String=>Object}] a stored run
    # @param step [Hash{String=>Object}] the step's definition; a step without "require" passes
    # @param attempt [Hash{String=>Object}] the attempt that ended
    # @return [Hash{String=>Object}, nil] nil when every proof passes; else "proof" (the name), "code"
    #   (`require_<name>`), "detail" (what was required and found), "unproven" (true when it could not be
    #   checked) and, for `commits`, "required", "found" and "base"
    def check(run:, step:, attempt:)
      Array(step["require"]).each do |entry|
        name, value = entry.first
        found = prove(name, value, run, attempt)
        return found.merge("proof" => name, "code" => "require_#{name}") if found
      end
      nil
    rescue => e
      {"proof" => "unknown", "code" => "require_unknown", "unproven" => true, "detail" => "a required proof could not be checked",
       "error" => "#{e.class}: #{e.message}"[0, 300]}
    end

    private

    def prove(name, value, run, attempt)
      case name
      when "commits" then commits(value, run, attempt)
      when "nonempty" then nonempty(value, run)
      when "plan_status" then plan_status(value, run)
      when "tracked_clean" then tracked_clean(run)
      else unproven("unknown proof #{name.inspect}")
      end
    end

    def commits(required, run, attempt)
      base = attempt.dig("head", "before")
      short = base.to_s[0, 7]
      noun = "#{required} commit#{"s" unless required == 1}"
      return unproven("required #{noun}, but this attempt has no recorded starting commit") if base.nil?
      count = @guard.commits_since(run["worktree"], base)
      return unproven("required #{noun} since #{short}, but git could not count them") if count.nil?
      if count == :history_rewritten
        detail = "required #{noun} since #{short}, but #{short} is not an ancestor of HEAD, so history was rewritten"
        return unproven(detail).merge("reason" => "history_rewritten", "base" => base)
      end
      return nil if count >= required
      {"detail" => "required #{noun} since #{short}, found #{count}", "required" => required, "found" => count, "base" => base}
    end

    def nonempty(file, run)
      dir = run["artifacts_dir"]
      return unproven("required #{file} to be non-empty, but the run has no artifacts directory recorded") unless dir.is_a?(String) && !dir.empty?
      path = File.join(dir, file)
      result = WorkflowProduced.inspect_file(path, strict: true)
      return {"detail" => "required #{file} to be non-empty, found it missing"} unless result.exists
      return {"detail" => "required #{file} to be non-empty, found #{RULE_TEXT.fetch(result.rule, result.rule)}"} if result.rule
      return nil if inside?(File.realpath(path), File.realpath(dir))
      {"detail" => "required #{file} to be non-empty, found it outside the artifacts directory (through a linked directory)"}
    rescue SystemCallError
      unproven("required #{file} to be non-empty, but the file could not be read")
    end

    def inside?(real, real_dir)
      real.start_with?(real_dir.end_with?("/") ? real_dir : "#{real_dir}/")
    end

    RULE_TEXT = {"empty" => "it empty", "symlink" => "a symbolic link", "not_regular_file" => "something that is not a regular file"}.freeze
    private_constant :RULE_TEXT

    def plan_status(wanted, run)
      dir = @notes_dir_of.call(run["workspace"])
      return unproven("required plan status #{wanted}, but the workspace's notes directory could not be found") if dir.nil?
      plan = PlanFile.read(File.join(dir, PlanFile::FILE_NAME))
      return {"detail" => "required plan status #{wanted}, found no #{PlanFile::FILE_NAME}"} if plan.nil?
      return unproven("required plan status #{wanted}, but the plan could not be read") if plan.warnings.any? { |w| w["code"] == "unreadable" }
      written = plan.frontmatter["status"]
      unless PlanFile::STATUSES.include?(written)
        return unproven("required plan status #{wanted}, but the plan's status: is #{written.nil? ? "missing" : "not one of #{PlanFile::STATUSES.join(", ")}"}")
      end
      return nil if written == wanted
      {"detail" => "required plan status #{wanted}, found #{written}"}
    end

    def tracked_clean(run)
      paths = @guard.dirty_paths(run["worktree"])
      return unproven("required no changed tracked files, but git could not say") if paths.nil?
      return {"detail" => "required no changed tracked files, found a rebase, merge, cherry-pick, revert or bisect in progress (or git could not say)"} if @guard.operation_in_progress?(run["worktree"])
      return nil if paths.empty?
      {"detail" => "required no changed tracked files, found #{"at least " if paths.size >= WorkflowGuard::MAX_PATHS}#{paths.size} (#{paths.first(5).join(", ")})", "paths" => paths}
    end

    def unproven(detail)
      {"detail" => detail, "unproven" => true}
    end
  end
end
