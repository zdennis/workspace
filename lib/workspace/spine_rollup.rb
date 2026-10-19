module Workspace
  # The one roll-up of a stage's children, as the app's `model.ts` `rollUp` defines it. It reads each
  # child's effective state, so a folder-only child (no status of its own) counts as what its own
  # sub-stages roll up to. `SpineTree::Stage#rollup` uses it for the file statuses; an evaluation
  # passes states that may also hold `disputed`, `checking` and `check_failed`.
  module SpineRollup
    # The counts a roll-up lists, in this order.
    STATES = %w[completed in_progress not_started blocked skipped unknown disputed checking check_failed].freeze

    # @param states [Array<String>] each child's effective state (`disputed`, `checking` and `check_failed` count as in progress, never as done)
    # @return [Hash, nil] `status` (never `unknown`), `done` and `total` (skipped children left out of both)
    #   and `counts` (every child, by state); nil without children
    def self.call(states)
      return nil if states.empty?
      counts = STATES.to_h { |state| [state, 0] }
      states.each { |state| counts[STATES.include?(state) ? state : "unknown"] += 1 }
      total = states.size - counts["skipped"]
      done = counts["completed"]
      status = if total.zero?
        "skipped"
      elsif done == total
        "completed"
      elsif counts["blocked"].positive?
        "blocked"
      elsif (counts["in_progress"] + done + counts["disputed"] + counts["checking"] + counts["check_failed"]).positive?
        "in_progress"
      else
        "not_started"
      end
      {"status" => status, "done" => done, "total" => total, "counts" => counts}
    end

    # @param status [String] the stage's own status, `unknown` when it has none
    # @param rollup [Hash, nil] the stage's roll-up
    # @return [String] the status, or the roll-up's when the stage has none of its own and has sub-stages
    def self.effective(status, rollup)
      (status == "unknown" && rollup) ? rollup["status"] : status
    end
  end
end
