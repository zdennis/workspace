require "time"

module Workspace
  # The one reading of the run files that `workflow stats` and `workflow compare` share: the runs of a workflow
  # that start inside a window, and the `run_resumed` events of a run's history. It reads and writes nothing else.
  class WorkflowRunLoader
    # @param store [Workspace::WorkflowRunStore] reads the run files and their histories
    # @param clock [#call] returns the current Time
    def initialize(store:, clock: -> { Time.now })
      @store = store
      @clock = clock
    end

    # The runs of a workflow that start inside the window, newest first. A run file that cannot be read as a
    # run counts in `unreadable` (it cannot be told which workflow it belongs to, so it is counted at any
    # scope). A run with no usable start time is left out of a window and named in `undated`.
    # A run found in both directories (caught while moving to the archive) is read once, from the runs directory.
    #
    # @param workflow [String] the definition id the runs were started from
    # @param last [Numeric, nil] only runs that started in the last this many seconds (a run that started exactly then is in)
    # @param include [#call, nil] given a {WorkflowRun}, true to keep it (a workspace or project filter)
    # @return [Hash{String=>Object}] "runs" (the stored runs as {WorkflowRun}s), "unreadable" (a count) and "undated" (a count)
    def load(workflow:, last: nil, include: nil)
      cutoff = last && (@clock.call - last)
      undated = 0
      kept = (@store.going + @store.finished).uniq(&:id).select do |run|
        next false unless run.workflow == workflow
        next false if include && !include.call(run)
        next true unless cutoff
        started = time_of(run.created_at) || time_of(run.started_at)
        undated += 1 unless started
        started && started >= cutoff
      end
      {"runs" => kept.sort_by { |run| [run.created_at.to_s, run.id.to_s] }.reverse, "unreadable" => @store.unreadable(archived: true).size, "undated" => undated}
    end

    # @param run [WorkflowRun, Hash{String=>Object}]
    # @return [Hash{String,nil=>Integer}] step id => `run_resumed` count, from `resume --from`'s `from` else the
    #   event's `step`; the key nil holds resumes that name no step
    def resumes(run)
      id = WorkflowRun.from_h(run).id
      counts = Hash.new(0)
      since = 0
      loop do
        page = @store.events(id, since: since)
        page["events"].each do |event|
          next unless event["type"] == "run_resumed"
          step = [event["from"], event["step"]].find { |value| value.is_a?(String) && !value.empty? }
          counts[step] += 1
        end
        break unless page["truncated"]
        since = page["next_since"]
      end
      counts
    end

    # @param text [Object]
    # @return [Time, nil] the ISO 8601 time, nil for anything else
    def time_of(text)
      text.is_a?(String) ? Time.iso8601(text) : nil
    rescue ArgumentError
      nil
    end
  end
end
