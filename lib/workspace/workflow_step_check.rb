require "tmpdir"
require "fileutils"

module Workspace
  # Runs one workflow step's `status:` command outside a run, so a check can be tested without
  # spending one. The command, its time limit and its environment come from
  # {WorkflowEngine#check_plan} and {WorkflowCheck}, the code a run's check goes through. It
  # takes no lock and writes no run file or event; the log and, when none is given, the
  # artifacts directory live in a fresh temporary directory, never in a run's area.
  class WorkflowStepCheck
    # Seconds after which a check's temporary directory is removed by the next check.
    STALE_AFTER = 24 * 60 * 60

    # The names {Dir.mktmpdir} gives the directories this class makes.
    MADE = /\Aworkspace-check-\d{8}-\d+-[a-z0-9]+\z/

    # @param engine [Workspace::WorkflowEngine]
    # @param checker [Workspace::WorkflowCheck]
    # @param tmp_root [String] where the temporary directory is made
    # @param clock [#call] monotonic seconds
    # @param wall_clock [#call] the current Time, which ages old temporary directories
    # @param lstat [#call] reads a path's status without following a link, as +File.lstat+ does
    def initialize(engine:, checker:, tmp_root: Dir.tmpdir, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, wall_clock: -> { Time.now },
      lstat: File.method(:lstat))
      @lstat = lstat
      @engine = engine
      @checker = checker
      @tmp_root = tmp_root
      @clock = clock
      @wall_clock = wall_clock
    end

    # @param definition [Workspace::WorkflowDefinition]
    # @param step [String] a step id
    # @param worktree [String] the checkout the command runs in
    # @param artifacts [String, nil] an existing directory for `WORKSPACE_RUN_ARTIFACTS`; nil makes an empty one
    # @return [Hash{String=>Object}] the plan ({WorkflowEngine#check_plan}) plus "passed", "exit_code",
    #   "timed_out", "error" (why there is no exit code, or nil), "duration" (seconds), "log", "artifacts"
    #   and "artifacts_created"
    # @raise [Workspace::Error] code `artifacts_not_directory`, and the plan's
    def call(definition:, step:, worktree:, artifacts: nil)
      plan = @engine.check_plan(definition: definition, step: step, worktree: worktree)
      given = artifacts && resolve(artifacts)
      sweep(keep: given)
      scratch = Dir.mktmpdir("workspace-check-", @tmp_root)
      dir = given || File.join(scratch, "artifacts").tap { |path| FileUtils.mkdir_p(path) }
      log = File.join(scratch, "check.log")
      env = WorkflowCheck.env_for("id" => plan["run"], "artifacts_dir" => dir, "base_sha" => plan["base_sha"])
      started = @clock.call
      result = @checker.call(command: plan["command"], cwd: worktree, timeout: plan["timeout"], log: log, env: env)
      plan.merge("passed" => result[:exit_code] == 0 && !result[:timed_out], "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
        "error" => result[:error], "duration" => (@clock.call - started).round(1), "log" => log, "artifacts" => dir, "artifacts_created" => given.nil?)
    end

    private

    def resolve(path)
      File.realpath(path).tap do |real|
        raise SystemCallError.new(nil, Errno::ENOTDIR::Errno) unless File.directory?(real)
      end
    rescue SystemCallError
      raise Workspace::Error.new("--artifacts #{path[0, 200].inspect} is not a directory that exists.",
        code: "artifacts_not_directory", details: {"path" => path[0, 200]})
    end

    # Removes this user's directories of the names {MADE} a day old or more, a link never followed, and any that
    # holds +keep+ (the artifacts directory being given).
    def sweep(keep:)
      cutoff = @wall_clock.call - STALE_AFTER
      Dir.children(@tmp_root).grep(MADE).each do |name|
        path = File.join(@tmp_root, name)
        info = @lstat.call(path)
        next unless info.directory? && info.uid == Process.uid && info.mtime < cutoff
        next if keep && (File.realpath(path) + File::SEPARATOR).then { |prefix| (keep + File::SEPARATOR).start_with?(prefix) }
        FileUtils.rm_rf(path)
      rescue SystemCallError
        next
      end
    rescue SystemCallError
      nil
    end
  end
end
