require "time"

module Workspace
  # Reads the attempts a stored run recorded (see {WorkflowAttemptRecord}) into the rows
  # `workflow attempts` shows. It reads the run hash it is given and writes nothing. A run
  # stored before a key existed has no such key: the row holds `nil` for it, never an error.
  class WorkflowAttempts
    # The `check` keys a row carries.
    CHECK_KEYS = %w[command log started_at ended_at exit_code timed_out].freeze

    # @param run [Hash{String=>Object}] a stored run, going or finished
    # @param step [String, nil] only this step's attempts (and the reasons held outside any attempt for it)
    # @return [Hash{String=>Object}] `"attempts"`, one row per attempt in the order they began, and
    #   `"unowned_reasons"`, the run's own `reasons` (waits that had no attempt to own them, each with a
    #   `step`), oldest first
    # @raise [Workspace::Error] code `unknown_step` when +step+ is not one of the run's steps
    def read(run, step: nil)
      ids = step_ids(run)
      if step && !ids.include?(step)
        raise Workspace::Error.new("Run #{run["id"]} has no step #{step.to_s[0, 60].inspect}. Its steps: #{ids.join(", ")}.",
          code: "unknown_step", details: {"run_id" => run["id"], "step" => step.to_s[0, 60], "steps" => ids})
      end
      rows = ids.each_with_index.flat_map do |id, index|
        next [] if step && id != step
        attempts_of(run, id).map { |attempt| [row(id, attempt), index] }
      end
      rows = rows.sort_by { |each, index| [each["started_at"].to_s, index, each["attempt"].to_i] }.map(&:first)
      unowned = Array(run["reasons"]).grep(Hash).select { |each| step.nil? || each["step"] == step }
      {"attempts" => rows, "unowned_reasons" => unowned.map { |each| each.slice("step", "code", "since", "until") }
        .sort_by { |each| each["since"].to_s }}
    end

    private

    def step_ids(run)
      defined = Array(run.dig("definition", "steps")).grep(Hash).filter_map { |each| each["id"] }
      (defined + (run["steps"].is_a?(Hash) ? run["steps"].keys : [])).uniq
    end

    def attempts_of(run, id)
      state = run["steps"].is_a?(Hash) ? run["steps"][id] : nil
      state.is_a?(Hash) ? Array(state["attempts"]).grep(Hash) : []
    end

    def row(step, attempt)
      check = attempt["check"].is_a?(Hash) ? attempt["check"].slice(*CHECK_KEYS) : nil
      {"step" => step, "attempt" => attempt["n"], "outcome" => attempt["outcome"], "code" => attempt["code"],
       "started_at" => attempt["started_at"], "ended_at" => attempt["ended_at"],
       "agent" => attempt["agent"], "session" => attempt["session"], "head" => attempt["head"],
       "definition_sha256" => attempt["definition_sha256"], "prompt_sha256" => attempt["prompt_sha256"],
       "packs" => attempt["packs"], "outputs" => attempt["outputs"], "check" => check,
       "reported" => attempt["reported"], "proofs" => attempt["proofs"], "usage" => attempt["usage"], "evidence" => attempt["evidence"], "reasons" => attempt["reasons"],
       "warnings" => attempt["warnings"],
       "redelivered" => (attempt["redelivered"] == true) ? true : nil}
    end
  end
end
