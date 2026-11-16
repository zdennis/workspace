require "json"

module Workspace
  # One stream of a workspace's workflow decision lines (from its agent
  # daemon's hook event file) and the events of its workflow runs, oldest
  # first, with one cursor that resumes both.
  #
  # The daemon's lines come from an {EventStream} scoped to the workspace;
  # only the decision types ({DECISION_TYPES}) and the stream's gap lines are
  # yielded. The runs are the workspace's going runs when the watch opens,
  # plus any it finds going every {DISCOVER_EVERY} reads; each is read by line
  # number through {WorkflowRunStore#events}, wherever the archive moved it,
  # until its state file is in the archive ({WorkflowRunStore#archived?}, never
  # the terminal state alone: a finishing change writes that before its last
  # history lines) and its history is drained. Given +run:+, only that run is
  # followed, and only the decision lines naming it; a +run:+ run that is gone
  # from the store (pruned from the archive) ends the watch ({#done?}). If moving
  # a finished run to the archive fails, the watch keeps waiting for it until a
  # later change archives it; Ctrl-C stops the reader. A few writers append a
  # run's history lines without the run's lock, so a line appended just after
  # the run is archived and drained may not be shown.
  #
  # A look for runs takes every run of the workspace still in the runs directory
  # ({WorkflowRunStore#unarchived}, finished or not), then the archived runs that
  # ended within {FINISHED_MARGIN} of the last look (the cursor's, when resumed)
  # and were not followed to their end, so a run that started and ended between
  # two looks, or between two watches, is read once. Archived runs that ended
  # before a watch opened without a cursor are not read.
  #
  # Every yielded line is a Hash:
  #
  #   "source"    "daemon" (a decision line), "run" (a run event) or "watch" (a gap)
  #   "at"        the line's time (ISO 8601 UTC with milliseconds)
  #   "type"      the line's type, e.g. "workflow_advance_started", "step_dispatched", "gap"
  #   "workspace" the workspace watched
  #   "run_id"    the run the line is about; nil for a sweep line (its `run_ids` are in "event") or a gap
  #   "event"     the line as its file holds it (a run event keeps its line number as "n")
  #   "cursor"    the cursor for everything up to and including this line
  #
  # The cursor is {CURSOR_PREFIX} then {EventStream.encode_cursor}'s body over
  # `{"w" => workspace, "f" => the +run:+ filter or nil, "e" => the EventStream's cursor,
  # "r" => {run id => line number}, "t" => the last look for runs (ISO 8601),
  # "d" => {run id followed to its end => its ended_at}}`, so a `workspace events`
  # cursor and this one can't be taken for each other. A run in "d" is dropped once
  # it ended over {FINISHED_MARGIN} before "t". A cursor is resumed only by a watch of
  # the same workspace with the same filter.
  class DaemonWatch
    # The prefix naming this cursor's format: a "w" before {EventStream::CURSOR_PREFIX}.
    CURSOR_PREFIX = "w#{EventStream::CURSOR_PREFIX}"

    # Reads between looks for runs that started (about 2 seconds at a quarter-second poll).
    DISCOVER_EVERY = 8

    # Seconds before a cursor's last look for runs that a resumed watch still reads finished runs from.
    FINISHED_MARGIN = 60

    # The hook event lines that are the nudger's decisions.
    DECISION_TYPES = %w[workflow_advance_started workflow_run_skipped workflow_sweep_started workflow_process_exited].freeze

    # What a cursor this watch can't read says.
    INVALID_CURSOR = "That cursor can't be read; pass one a daemon watch line of this workspace printed, or leave out --since."

    # @param state [Hash] the watch's positions
    # @return [String]
    def self.encode_cursor(state)
      "w" + EventStream.encode_cursor(state)
    end

    # @param workspace [String] the workspace watched
    # @param stream [EventStream] an EventStream scoped to that workspace (+workspace:+, no lifecycle log)
    # @param store [WorkflowRunStore] the workflow runs
    # @param run [String, nil] follow only this run
    # @param discover_every [Integer] reads between looks for runs that started
    # @param clock [#now] time source, for the cursor's last look for runs
    def initialize(workspace:, stream:, store:, run: nil, discover_every: DISCOVER_EVERY, clock: Time)
      @clock = clock
      @ended = {}
      @workspace = workspace
      @stream = stream
      @store = store
      @run = run
      @discover_every = discover_every
      @runs = {}
      @reads = 0
      @done = false
    end

    # Opens the daemon's file and the runs: from the cursor when given one,
    # else at the end of each (+at: :end+) or at their start (+at: :start+).
    # A run the cursor doesn't name is read from its start, an archived one
    # included when it ended near or after the cursor's last look for runs.
    #
    # @param cursor [String, nil] a cursor a line of this watch carried
    # @param at [Symbol] :end or :start, for a watch with no cursor
    # @return [Array<Hash>] gap lines for the daemon's lines the cursor is older than
    # @raise [EventStream::InvalidCursor] when the cursor can't be read, is another workspace's, or has another +run:+ filter
    # @raise [Workspace::Error] code `unknown_run` when +run+ names no run
    def open(cursor: nil, at: :end)
      state = cursor && decode(cursor)
      @store.run(@run) if @run
      gaps = begin
        @stream.open(cursor: state&.dig("e"), at: at)
      rescue EventStream::InvalidCursor
        raise EventStream::InvalidCursor, INVALID_CURSOR
      end
      @stream_cursor = @stream.cursor_string
      @runs.update(state["r"]) if state
      @ended.update(state["d"]) if state
      discover(state ? :start : at, since: state&.dig("t"))
      skip_ended_before_open unless state || @run
      gaps.map { |gap| watch_line("watch", gap, nil).merge("cursor" => cursor_string) }
    end

    # Reads every complete line written since the last call, oldest first
    # across the daemon's file and the runs, each with the cursor as it
    # stands after it.
    #
    # @param discover [Boolean, nil] look for runs and a daemon file that appeared; nil does every {DISCOVER_EVERY} reads
    # @return [Array<Hash>] the lines, in the shape the class describes
    def read(discover: nil)
      @reads += 1
      discover = (@reads % @discover_every).zero? if discover.nil?
      discover(:start, since: @looked_at) if discover
      queues = {daemon: @stream.read(discover: discover).map { |line| [line["at"], line] }}
      results = {}
      @runs.each_key do |id|
        result = read_run(id)
        results[id] = result
        queues[id] = result ? result["events"].map { |event| [event["ts"], event] } : []
      end
      lines = merge(queues)
      @stream_cursor = @stream.cursor_string
      settle(results)
      lines
    end

    # @return [Boolean] whether the last {#read} left lines it will return next time
    def more?
      @stream.more? || @more
    end

    # @return [Boolean] with +run:+, whether the run has finished and every event of it was read, or is gone from the store
    def done?
      @done
    end

    # @return [String] the cursor for everything read so far
    def cursor_string
      self.class.encode_cursor("w" => @workspace, "f" => @run, "e" => @stream_cursor, "r" => @runs.dup, "t" => @looked_at, "d" => @ended.dup)
    end

    private

    def decode(cursor)
      raise EventStream::InvalidCursor, INVALID_CURSOR unless cursor.is_a?(String) && cursor.start_with?(CURSOR_PREFIX)
      state = EventStream.decode_cursor(cursor.delete_prefix("w"))
      raise EventStream::InvalidCursor, INVALID_CURSOR unless valid_state?(state)
      state
    rescue ArgumentError, JSON::ParserError
      raise EventStream::InvalidCursor, INVALID_CURSOR
    end

    def valid_state?(state)
      state.is_a?(Hash) && state["w"] == @workspace && state.key?("f") && state["f"] == @run && state["e"].is_a?(String) &&
        state["r"].is_a?(Hash) && state["r"].all? { |id, n| id.is_a?(String) && n.is_a?(Integer) && n >= 0 } &&
        time(state["t"]) && state["d"].is_a?(Hash) && state["d"].all? { |id, ended| id.is_a?(String) && (ended.nil? || ended.is_a?(String)) }
    end

    def time(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end

    # +since+, the last look (a resumed cursor's), also takes the archived runs that ended near or after it.
    # The runs directory is read before the archive, so a run moving between them is in one of the two.
    def discover(at, since: nil)
      now = @clock.now.utc
      ids = @run ? [@run] : @store.unarchived.select { |run| run.workspace == @workspace }.map(&:id)
      ids += ended_since(time(since) - FINISHED_MARGIN).map(&:id) if since && @run.nil?
      ids.each { |id| @runs[id] ||= (at == :end) ? end_of(id) : 0 unless @ended.key?(id) }
      @looked_at = now.iso8601(3)
      @ended.reject! { |_, ended| (t = time(ended)).nil? || t < now - FINISHED_MARGIN }
    end

    def ended_since(from)
      @store.finished_since(from).select { |run| run.workspace == @workspace && (t = time(run.ended_at)) && t >= from }
    end

    # A watch opened without a cursor starts now: runs that had ended are marked followed, so a look never reads them.
    def skip_ended_before_open
      ended_since(time(@looked_at) - FINISHED_MARGIN).each { |run| @ended[run.id] ||= run.ended_at unless @runs.key?(run.id) }
    end

    def end_of(id)
      since = 0
      loop do
        result = @store.events(id, since: since)
        since = result["next_since"]
        return since unless result["truncated"]
      end
    end

    # Whether the run is archived is read before its events, so a run seen finished has no event written
    # after the read. Between the archive's two renames its history is not found and reads as empty.
    def read_run(id)
      archived = @store.archived?(id)
      result = @store.events(id, since: @runs[id])
      result.merge("finished" => archived, "ended_at" => archived ? @store.run(id).ended_at : nil)
    rescue Workspace::Error => e
      raise unless e.code == "unknown_run"
      nil
    end

    # Takes the oldest next line of any source each time, so lines keep the order they have in their own file.
    def merge(queues)
      out = []
      loop do
        key, queue = queues.reject { |_, queue| queue.empty? }.min_by { |_, queue| queue.first.first.to_s }
        break unless key
        _, line = queue.shift
        if key == :daemon
          @stream_cursor = line["cursor"]
          out << watch_line("daemon", line, line["run_id"]).merge("cursor" => cursor_string) if decision?(line)
        else
          @runs[key] = line["n"]
          out << watch_line("run", line, key).merge("at" => line["ts"], "cursor" => cursor_string)
        end
      end
      out
    end

    def decision?(line)
      return true if line["type"] == "gap"
      return false unless DECISION_TYPES.include?(line["type"])
      @run.nil? || line["run_id"] == @run || (line["run_ids"].is_a?(Array) && line["run_ids"].include?(@run))
    end

    def settle(results)
      @more = false
      results.each do |id, result|
        if result.nil?
          # A run gone from the store has nothing more to read; a --run watch is over.
          @done = true if @run
          @runs.delete(id) unless @run
          next
        end
        @runs[id] = result["next_since"]
        @more ||= result["truncated"]
        drained = result["finished"] && !result["truncated"]
        @done = drained if id == @run
        next unless drained && @run.nil?
        @runs.delete(id)
        @ended[id] = result["ended_at"].is_a?(String) ? result["ended_at"] : nil
      end
    end

    def watch_line(source, line, run_id)
      event = line.except("cursor", "source")
      {"source" => (line["type"] == "gap") ? "watch" : source, "at" => line["at"], "type" => line["type"],
       "workspace" => @workspace, "run_id" => run_id.is_a?(String) ? run_id : nil, "event" => event}
    end
  end
end
