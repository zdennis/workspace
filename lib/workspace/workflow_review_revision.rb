require "digest"

module Workspace
  # The revision of what a review round judges: one SHA-256 over the step's `produces` files (each through
  # {WorkflowProduced.digest}, so a link or a non-regular file is never read), the checkout's HEAD, the digest of
  # its tracked tree ({WorkflowGuard#tree_digest}) and, when the step's `review.revision` is set, that command's
  # output. The command's output is added to the hash, never put in its place, so a subject outside the checkout
  # (a workspace plan) and one git does not see (a file under `.workflow/`) both move it. Taken when a round is
  # delivered and again when it ends; a different answer is a stale round.
  #
  # The command runs through {WorkflowCheck} in the checkout with {WorkflowCheck.env_for}, under {TIMEOUT}. Only its
  # stdout is hashed (a warning on stderr is not a change); stdout goes to a log under the run's `steps/` directory
  # and stderr to a file beside it, which a problem names. A command that fails, times out or can't run is a
  # `problem`, never a revision. Nothing here raises.
  class WorkflowReviewRevision
    # The most seconds the git reads of one recompute can take: HEAD ({WorkflowGuard::HEAD_TIMEOUT}), then git's
    # version, the `filter.*` entries and the diff ({WorkflowGuard::GIT_TIMEOUT} each).
    GIT_SECONDS = WorkflowGuard::HEAD_TIMEOUT + 3 * WorkflowGuard::GIT_TIMEOUT

    # Seconds kept spare beyond every limit counted, for the file reads and the two changes under the run's lock.
    SPARE_SECONDS = 15

    # Seconds the `review.revision` command may run: what is left of {WorkflowTransitions::DELIVERY_WINDOW} (the age
    # at which a recompute that never reported back counts as lost) after the git reads, the command's stop
    # ({WorkflowCheck::KILL_GRACE}, {WorkflowCheck::STOP_POLL}) and {SPARE_SECONDS}, so a live recompute is never taken for lost.
    TIMEOUT = WorkflowTransitions::DELIVERY_WINDOW - GIT_SECONDS - WorkflowCheck::KILL_GRACE - WorkflowCheck::STOP_POLL - SPARE_SECONDS

    # Most bytes of a `produces` file or of the command's log that are hashed; past it the revision is a problem.
    MAX_BYTES = 16 * 1024 * 1024

    # What the hash starts with, so a later change to what it covers can't read as the same revision.
    FORMAT = "workspace-review-revision-1"

    # @param guard [Workspace::WorkflowGuard] reads HEAD and the tracked tree's digest
    # @param checker [Workspace::WorkflowCheck] runs the `review.revision` command
    def initialize(guard:, checker:)
      @guard = guard
      @checker = checker
    end

    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on the step whose round is judged
    # @param step [Hash{String=>Object}] that step's definition
    # @param stop_when [#call, nil] passed to the command's {WorkflowCheck#call}: true stops it (the round moved on)
    # @return [Hash{Symbol=>Object}] :revision (a hex SHA-256, nil with a problem) and :problem (a sentence, nil without one)
    def call(run:, step:, stop_when: nil)
      read = WorkflowRun.from_h(run)
      digest = Digest::SHA256.new
      feed(digest, FORMAT)
      Array(step["produces"]).each do |file|
        content = WorkflowProduced.digest(File.join(read.artifacts_dir.to_s, file), max_bytes: MAX_BYTES)
        return problem("#{file} is larger than #{MAX_BYTES} bytes") if content&.too_large
        feed(digest, "produces", file, content ? content.sha256 : "missing")
      end
      worktree = read.worktree.to_s
      feed(digest, "head", @guard.head(worktree) || "none")
      tree = @guard.tree_digest(worktree, base: read)
      return problem("the checkout's tracked files could not be read") unless tree
      feed(digest, "tree", tree)
      command = WorkflowDefinition.review(step)&.dig("revision")
      if command
        output = command_output(read, step, command, stop_when)
        return problem(output[:problem]) if output[:problem]
        feed(digest, "command", output[:sha256])
      end
      {revision: digest.hexdigest, problem: nil}
    rescue SystemCallError, IOError => e
      problem("the revision could not be read (#{e.class})")
    end

    private

    def command_output(run, step, command, stop_when)
      log = log_path(run, step)
      err_log = log.sub(/\.log\z/, ".err")
      result = @checker.call(command: command, cwd: run.worktree.to_s, timeout: TIMEOUT, log: log, err_log: err_log, stop_when: stop_when, env: WorkflowCheck.env_for(run))
      return {problem: "the review revision command ran past #{TIMEOUT} seconds (stderr #{err_log})"} if result[:timed_out]
      return {problem: "the review revision command did not finish: #{result[:error]} (stderr #{err_log})"} if result[:error]
      return {problem: "the review revision command exited #{result[:exit_code]} (stderr #{err_log})"} unless result[:exit_code] == 0
      content = WorkflowProduced.digest(log, max_bytes: MAX_BYTES)
      return {problem: "the review revision command's output is larger than #{MAX_BYTES} bytes (#{log})"} if content&.too_large
      return {problem: "the review revision command's output could not be read (#{log})"} unless content&.sha256
      {sha256: content.sha256}
    end

    # `steps/<step>.<n>.r<round>.revision.log` (stdout; stderr in `.revision.err`), beside the step's check logs; the
    # round directory stays the reviewers'.
    def log_path(run, step)
      state = run.steps[step["id"]]
      attempt = state&.last_attempt&.n
      round = state&.review&.dig("round")
      File.join(run.artifacts_dir.to_s, "steps", "#{step["id"]}.#{attempt}.r#{round}.revision.log")
    end

    def feed(digest, *parts)
      parts.each do |part|
        digest.update(part.to_s.b)
        digest.update("\0")
      end
    end

    def problem(text) = {revision: nil, problem: text}
  end
end
