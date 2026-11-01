require "digest"

module Workspace
  # What an attempt records about itself in the run file: what it started from
  # ({#start}) and what it ended with ({#finish}, {#abandon}). It runs under the
  # run's lock, so every read is short, and a recording problem is a nil, never
  # an error: recording must not fail a step, a cancel or a kill.
  class WorkflowAttemptRecord
    # A produced file above this many bytes is recorded with its size and no hash.
    MAX_HASH_BYTES = 16 * 1024 * 1024

    # @param guard [Workspace::WorkflowGuard] reads the checkout's HEAD
    def initialize(guard:)
      @guard = guard
    end

    # Records the definition, the composed prompt, each pack and HEAD when an attempt begins.
    #
    # @param run [Hash{String=>Object}]
    # @param attempt [Hash{String=>Object}] changed in place
    # @param composed [Hash{String=>Object}] the composer's answer: "text" and "packs"
    # @return [Hash{String=>Object}] the attempt
    def start(run:, attempt:, composed:)
      attempt["head"] = {"before" => @guard.head(run["worktree"]), "after" => nil}
      attempt["definition_sha256"] = run["definition_sha256"]
      attempt["prompt_sha256"] = Digest::SHA256.hexdigest(composed["text"])
      attempt["packs"] = composed["packs"].map { |pack| {"ref" => pack["ref"], "sha256" => pack["sha256"]} }
      attempt.compact!
      attempt
    end

    # Records HEAD now and each declared `produces` file when an attempt passes or fails.
    #
    # @param run [Hash{String=>Object}]
    # @param step [Hash{String=>Object}] the step's definition
    # @param attempt [Hash{String=>Object}] changed in place
    # @return [Hash{String=>Object}] the attempt
    def finish(run:, step:, attempt:)
      attempt["head"] = (attempt["head"] || {"before" => nil}).merge("after" => @guard.head(run["worktree"]))
      attempt["outputs"] = Array(step["produces"]).map { |file| output(file, File.join(run["artifacts_dir"].to_s, file)) }
      attempt
    end

    # Closes the current step's attempt for a run that is cancelled or whose workspace was killed, if it is
    # still open (no `ended_at`). Never raises; a checkout that is gone gives a nil `head.after`.
    #
    # @param run [Hash{String=>Object}]
    # @return [Hash{String=>Object}, nil] the attempt closed; nil when there was none to close
    def abandon(run)
      attempt = run.dig("steps", run["current"], "attempts")&.last
      return nil if attempt.nil? || attempt["ended_at"]
      step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
      finish(run: run, step: step, attempt: attempt)
    rescue
      nil
    end

    private

    def output(file, path)
      content = WorkflowProduced.digest(path, max_bytes: MAX_HASH_BYTES)
      return {"file" => file, "sha256" => nil, "bytes" => nil} unless content
      record = {"file" => file, "sha256" => content.sha256, "bytes" => content.bytes}
      record["too_large"] = true if content.too_large
      record
    end
  end
end
