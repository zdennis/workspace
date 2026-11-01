require "time"

module Workspace
  # The runs `workflow status --needs-me` lists: the rows {WorkflowStatus} already built, narrowed to the
  # ones that wait for a person, each with the first of its own `actions` as the next command. It keeps no
  # table of its own from a reason to a command and reads nothing outside the rows.
  #
  # A going run with a shown reason is listed, so a reason code added later shows up here until it is
  # named in {CLEARS_BY_ITSELF}. Left out: `turn_ended_background` (a hold for background tasks), a
  # `retry_backoff` whose resume needs no other pane (the wait ends alone), and a `waiting_lock` for less
  # than {LOCK_WAIT_LIMIT} seconds, or with no `since` (a holder that does not let go in that time is stuck).
  # A lock wait with nothing but `cancel` to offer has a null `next_action`. A run with no reason is listed when {WorkflowStatus} reports it `stuck`. A run that is working or
  # parked has neither and is not listed.
  class WorkflowNeedsMe
    # Reason codes that end without anyone acting.
    CLEARS_BY_ITSELF = %w[turn_ended_background retry_backoff].freeze

    # Seconds a run may queue for a lock before it is listed.
    LOCK_WAIT_LIMIT = 30 * 60

    # @param clock [#call] returns the current Time
    def initialize(clock: -> { Time.now })
      @clock = clock
    end

    # @param runs [Array<Hash>] rows as {WorkflowStatus#runs} returns them
    # @return [Array<Hash>] one row per run that needs the person, longest wait first, a wait with no known start last:
    #   "run", "workflow", "workspace", "step", "attempt", "code" (the reason's code, or `stalled` / `idle`),
    #   "kind" (a `waiting_you` reason's kind, else null), "gate_file" (a gate's note as {WorkflowGateNote} found it, else null), "detail" (the failing check's code, a stall's cause, else null),
    #   "since" (ISO 8601 or null), "waiting_seconds" (whole seconds or null), "next_action" (the first of "actions"),
    #   "actions" (all, as {WorkflowStatus} gives them). "next_action" is a suggestion for a person who has read the run:
    #   a program must not run it unattended (approving a gate or cancelling a run is the person's call)
    def rows(runs)
      found = runs.filter_map { |run| row(run) }
      found.sort_by { |each| [each["since"] ? 0 : 1, each["since"].to_s, each["run"]] }
    end

    private

    def row(run)
      return nil if WorkflowRunStore::TERMINAL_STATES.include?(run["state"])
      current = run["current"] || {}
      reason = current["reason"]
      stuck = current["stuck"]
      source = reason || stuck
      return nil unless source
      since = parse(source["since"])
      return nil unless needs_person?(reason, stuck, since)
      actions = Array(source["actions"])
      details = reason&.fetch("details", nil) || {}
      {"run" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"], "step" => current["step"], "attempt" => current["attempt"],
       "code" => source["code"], "kind" => details["kind"], "gate_file" => details["gate_file"], "detail" => reason ? (details["code"] || details["cause"]) : stuck["cause"],
       "since" => since&.utc&.iso8601, "waiting_seconds" => since && [(@clock.call - since).to_i, 0].max,
       "next_action" => next_action(source, actions), "actions" => actions}
    end

    # The first action; for a lock wait never a bare cancel, which would end a run for waiting in a queue.
    def next_action(source, actions)
      first = actions.first
      (source["code"] == "waiting_lock" && first && first["action"] == "workflow cancel") ? nil : first
    end

    def needs_person?(reason, stuck, since)
      return true if stuck && !reason
      case reason["code"]
      when "waiting_lock" then !since.nil? && @clock.call - since > LOCK_WAIT_LIMIT
      when "retry_backoff" then Array(reason["actions"]).first&.fetch("needs", [])&.any? { |need| need["name"] == "pane" } || false
      else !CLEARS_BY_ITSELF.include?(reason["code"])
      end
    end

    def parse(time)
      Time.iso8601(time) if time.is_a?(String)
    rescue ArgumentError
      nil
    end
  end
end
