require "digest"
require "json"
require "time"

module Workspace
  # What an attempt records about itself in the run file: what it started from
  # ({#start}) and what it ended with ({#finish}, {#abandon}). It runs under the
  # run's lock, so every read is short, and a recording problem is a nil (or the
  # value given, unchanged), never an error: recording must not fail a step, a
  # cancel or a kill. Each method returns a new value and changes nothing it is given.
  class WorkflowAttemptRecord
    # A produced file above this many bytes is recorded with its size and no hash.
    MAX_HASH_BYTES = 16 * 1024 * 1024

    # The last bytes of the session ledger read to find an attempt's session; a ledger is never rotated.
    MAX_LEDGER_BYTES = 1024 * 1024

    # The last bytes of a transcript read for an attempt's usage, model and version. Attempt recording
    # runs under the run's lock, so a transcript is never read whole; when the tail does not reach back
    # to the attempt's start, `usage` is recorded as nil rather than a count that leaves tokens out.
    MAX_TRANSCRIPT_BYTES = 4 * 1024 * 1024

    # Evidence entries {#finish} keeps from before it copies: the prompt, and a review round's verdicts.
    KEPT_EVIDENCE = %w[prompt review].freeze

    # An attempt's start is recorded a moment before its session's hook may have been.
    START_SLACK = 5

    SESSION_ID = /\A[A-Za-z0-9._-]{1,128}\z/
    TRANSCRIPT_PATH = %r{\A/[^\x00-\x1f\x7f]{1,4095}\.jsonl\z}
    VERSION = /\A[A-Za-z0-9._+-]{1,50}\z/
    MODEL = /\A[A-Za-z0-9._:\/\[\]-]{1,100}\z/
    KIND = /\A[a-z][a-z0-9_-]{0,31}\z/
    USAGE_KEYS = %w[input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens].freeze
    # A sub-agent transcript's file name, and the most of them one attempt reads (more is uncounted).
    SUBAGENT_FILE = /\Aagent-[A-Za-z0-9._-]{1,128}\.jsonl\z/
    MAX_SUBAGENT_FILES = 64
    # The most directory entries looked at before the attempt gives up as uncounted.
    MAX_SUBAGENT_ENTRIES = 4096
    private_constant :KEPT_EVIDENCE, :SUBAGENT_FILE, :MAX_SUBAGENT_FILES, :MAX_SUBAGENT_ENTRIES, :START_SLACK, :SESSION_ID, :TRANSCRIPT_PATH, :VERSION, :MODEL, :KIND, :USAGE_KEYS

    # @param guard [Workspace::WorkflowGuard] reads the checkout's HEAD
    # @param ledger [Workspace::SessionLedger, nil] finds an attempt's session; nil records none
    # @param clock [#call] returns the current Time
    # @param session_names [#call] given a workspace name, the names the session hook may have recorded
    #   its panes under (the workspace's, and its tmux session's)
    # @param server_for [#call] given a pane id, the pid of its tmux server, or nil
    # @param evidence [Workspace::WorkflowEvidence, nil] copies the attempt's files aside; nil keeps none
    # @param max_hash_bytes [Integer] the largest `produces` file hashed
    # @param max_transcript_bytes [Integer] how much of a transcript's tail is read
    def initialize(guard:, ledger: nil, clock: -> { Time.now }, session_names: ->(workspace) { [workspace] }, server_for: ->(_pane) {}, evidence: nil, max_hash_bytes: MAX_HASH_BYTES, max_transcript_bytes: MAX_TRANSCRIPT_BYTES)
      @max_hash_bytes = max_hash_bytes
      @max_transcript_bytes = max_transcript_bytes
      @evidence = evidence
      @guard = guard
      @ledger = ledger
      @clock = clock
      @session_names = session_names
      @server_for = server_for
    end

    # Records the definition, the composed prompt, each pack and HEAD when an attempt begins.
    #
    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param attempt [WorkflowRun::Attempt, Hash{String=>Object}] left as it is
    # @param composed [Hash{String=>Object}] the composer's answer: "text" and "packs"
    # @return [WorkflowRun::Attempt] the attempt with what it started from
    def start(run:, attempt:, composed:)
      run = WorkflowRun.from_h(run)
      attempt = mutable(attempt)
      attempt["head"] = {"before" => @guard.head(run.worktree), "after" => nil}
      attempt["definition_sha256"] = run.definition_sha256
      attempt["prompt_sha256"] = Digest::SHA256.hexdigest(composed["text"])
      attempt["packs"] = composed["packs"].map { |pack| {"ref" => pack["ref"], "sha256" => pack["sha256"]} }
      attempt.compact!
      # The prompt is copied as it is written, before it is delivered: the agent has not seen it yet.
      attempt["evidence"] = @evidence.prompt(run: run, step_id: run.current, attempt: attempt) if @evidence && attempt["prompt_file"]
      WorkflowRun::Attempt.from_h(attempt)
    end

    # Records HEAD now and each declared `produces` file when an attempt passes or fails, and copies its
    # prompt, check log and those files to the evidence directory (`evidence`, see {WorkflowEvidence}).
    # A check log is complete here for a passed or failed check; a cancel or kill that stops a check
    # keeps the log as it stood, and what the stopped check writes later is not copied.
    #
    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param step [Hash{String=>Object}] the step's definition
    # @param attempt [WorkflowRun::Attempt, Hash{String=>Object}] left as it is
    # @return [WorkflowRun::Attempt] the attempt with what it ended with
    def finish(run:, step:, attempt:)
      run = WorkflowRun.from_h(run)
      attempt = mutable(attempt)
      attempt["head"] = (attempt["head"] || {"before" => nil}).merge("after" => @guard.head(run.worktree))
      copies = @evidence ? @evidence.copy(run: run, step: step, attempt: attempt) : []
      attempt["outputs"] = outputs(step, run.to_h, copies)
      attempt.merge!(agent_facts(run.to_h, attempt))
      attempt["evidence"] = Array(attempt["evidence"]).select { |each| KEPT_EVIDENCE.include?(each["kind"]) } + copies if @evidence
      WorkflowRun::Attempt.from_h(attempt)
    end

    # Keeps the history of a run's reason: every change of the effective reason (the stored one, or
    # `parked` while a resume is parked) closes the open entry with `until` and opens one with its `since`.
    # An open entry with the same code and `since` is left alone wherever it sits. A new entry lives:
    #
    # * on the step's open attempt, when there is one;
    # * else on the attempt this same change just ended, only when its ending set the reason (a
    #   `failed_check` for that attempt, or a gate wait);
    # * else in the run's own `reasons` list, with the `step` it concerns (a wait for a lock before the
    #   first attempt, or before a retry's attempt exists; a dispatch that could not start).
    #
    # A reason that stands when a later attempt opens stays on the attempt it began on. A parked resume
    # that times out is worked out when read and never stored, so its entry stays open until a change drops
    # the park. Never raises.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param was_open [Array(String, Integer), nil] {#open_attempt} read before the change
    # @return [WorkflowRun] the run with its reason history kept; the run given, unchanged, on any error
    def reasons(run:, was_open: nil)
      given = WorkflowRun.from_h(run)
      run = given.thawed
      current = effective_reason(run)
      at, entry = open_entry(run)
      return given if entry && current && entry["code"] == current["code"] && entry["since"] == current["since"]
      reopened = current && closed_entry(run, current)
      # A park replaced by a park keeps the mark, so the wait under it can still be reopened.
      each_entry(run) { |place, each| each.delete("parked") unless place == at } unless entry && entry["code"] == "parked"
      if entry
        entry["until"] = @clock.call.utc.iso8601
        entry["parked"] = true if current && current["code"] == "parked"
      end
      return WorkflowRun.from_h(run) unless current
      # A wait that a park interrupted and the park gave back is one wait: the entry the park closed (marked
      # `parked` while the park stands) is reopened, its `until` cleared, rather than a second one opened.
      if reopened
        reopened.delete("parked")
        reopened["until"] = nil
        return WorkflowRun.from_h(run)
      end
      owner, on_run = reason_owner(run, was_open, current)
      owner << {"code" => current["code"], "since" => current["since"], "until" => nil}.merge(on_run ? {"step" => run["current"]} : {})
      WorkflowRun.from_h(run)
    rescue
      WorkflowRun.from_h(given || run)
    end

    # @param run [Hash{String=>Object}]
    # @return [Array(String, Integer), nil] the step and number of the attempt that is open now
    def open_attempt(run)
      attempt = run.dig("steps", run["current"], "attempts")&.last
      (attempt.nil? || attempt["ended_at"]) ? nil : [run["current"], attempt["n"]]
    rescue
      nil
    end

    # Closes the current step's attempt for a run that is cancelled or whose workspace was killed, if it is
    # still open (no `ended_at`): the end fields of {#finish}, `ended_at` now and outcome `cancelled`. A
    # `check` or `proofs` row that was running keeps its own open state (no `ended_at`, `exit_code`).
    # Never raises; a checkout that is gone gives a nil `head.after`. A step being reviewed has no open
    # attempt (it ended `checks_passed`), so nothing is closed here: its round is ended by
    # {WorkflowProgress#end_round}, which records it through {#finish_round}.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @return [WorkflowRun] the run with that attempt closed; the run given, unchanged, when there was none
    #   to close or on any error
    def abandon(run)
      value = WorkflowRun.from_h(run)
      attempt = value.current_step&.last_attempt
      return value if attempt.nil? || attempt.ended_at
      step = value.definition["steps"].find { |each| each["id"] == value.current }
      # One clock read stamps the end and bounds the usage window ({#agent_facts} reads `ended_at`).
      ended = attempt.thawed.merge("ended_at" => @clock.call.utc.iso8601, "outcome" => "cancelled")
      value.with_attempt(value.current, finish(run: value, step: step, attempt: ended))
    rescue
      WorkflowRun.from_h(run)
    end

    # How the verdicts a review round read were made: by sub-agents of the round's own review pane. Every row of a
    # round's `reviews` carries it as `isolation`, so a later reader can tell these verdicts from any other kind.
    ISOLATION = "review_pane"

    # What an ended review round records about itself: its pane, the session that ran in that pane during the
    # round, and that session's usage over the round's time (main thread and sub-agents, by {#finish}'s rules).
    # A round that read verdicts (its `reviews`) gives each row `isolation` ({ISOLATION}) and copies each verdict file
    # it read to the evidence directory ({WorkflowEvidence#review}); the copies come back as `evidence`, which the
    # caller adds to the reviewed attempt's own `evidence`, never in place of it.
    # Never raises: what can't be told is nil, and a round that never recorded a pane has no session or usage.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is; on the step being reviewed
    # @param round [Hash{String=>Object}] the step's `review` ("round", "pane", "started_at", "reviews", ...)
    # @return [Hash{String=>Object}] "round", "pane", "started_at", "ended_at", "session", "agent" and "usage"; when the
    #   round read verdicts, also "reviews" and "evidence" (the copies; empty with no evidence collaborator); when its
    #   delivery recorded them, "packs" (one `{"reviewer", "ref", "sha256"}` per reviewer pack composed in)
    def finish_round(run:, round:)
      ended_at = round["ended_at"] || @clock.call.utc.iso8601
      record = {"round" => round["round"], "pane" => round["pane"], "started_at" => round["started_at"], "ended_at" => ended_at,
                "session" => nil, "agent" => nil, "usage" => nil}
      # The reviewer packs its delivery composed in, as an attempt keeps its own `packs`.
      record["packs"] = round["packs"] if round["packs"].is_a?(Array)
      reviews = marked_reviews(round["reviews"])
      if reviews
        record["reviews"] = reviews
        record["evidence"] = []
      end
      value = WorkflowRun.from_h(run)
      pane = round["pane"]
      facts = (pane.is_a?(String) && !pane.empty?) ? agent_facts(value.to_h, record, pane: pane) : {}
      record.merge!("session" => facts["session"], "agent" => facts["agent"], "usage" => facts["usage"])
      record["evidence"] = verdict_copies(value, round, reviews) if reviews
      record
    rescue
      record || {"round" => round["round"], "pane" => round["pane"], "started_at" => round["started_at"], "ended_at" => nil,
                 "session" => nil, "agent" => nil, "usage" => nil}
    end

    private

    def marked_reviews(rows)
      return nil unless rows.is_a?(Array)
      rows.map { |row| row.is_a?(Hash) ? row.merge("isolation" => ISOLATION) : row }
    end

    def verdict_copies(run, round, reviews)
      attempt = run.current_step&.last_attempt
      return [] unless @evidence && attempt
      @evidence.review(run: run, step_id: run.current, attempt: attempt.to_h, round: round["round"], reviews: reviews, rerun: round["reruns"])
    rescue
      []
    end

    def effective_reason(run)
      parked = run["parked"]
      return {"code" => "parked", "since" => parked["requested_at"]} if parked.is_a?(Hash)
      reason = run["reason"]
      (reason.is_a?(Hash) && reason["code"].is_a?(String)) ? reason : nil
    end

    # Each reason entry with its place: the list it sits in (nil for the run's own, else the step and the
    # attempt's n) and its index there.
    def each_entry(run)
      lists = [[nil, run["reasons"]]] + run["steps"].to_h.flat_map { |id, state| Array(state["attempts"]).map { |attempt| [[id, attempt["n"]], attempt["reasons"]] } }
      lists.each do |owner, list|
        next unless list
        list.each_with_index { |each, index| yield [owner, index], each }
      end
    end

    def closed_entry(run, current)
      found = nil
      each_entry(run) { |_, each| found ||= each if each["parked"] && each["code"] == current["code"] && each["since"] == current["since"] }
      found
    end

    def open_entry(run)
      each_entry(run) { |place, each| return [place, each] if each["until"].nil? }
      [nil, nil]
    end

    # @return [Array(Array, Boolean)] the list a new entry goes in, and whether it is the run's own
    def reason_owner(run, was_open, current)
      attempt = run.dig("steps", run["current"], "attempts")&.last
      if attempt && (attempt["ended_at"].nil? || (was_open == [run["current"], attempt["n"]] && set_by_ending?(current, attempt)))
        return [attempt["reasons"] ||= [], false]
      end
      [run["reasons"] ||= [], true]
    end

    def mutable(attempt)
      attempt.is_a?(WorkflowRun::Attempt) ? attempt.thawed : WorkflowRun.deep_thaw(attempt)
    end

    def set_by_ending?(reason, attempt)
      details = reason["details"].is_a?(Hash) ? reason["details"] : {}
      (%w[failed_check retry_backoff].include?(reason["code"]) && details["attempt"] == attempt["n"]) || (reason["code"] == "waiting_you" && details["kind"] == "gate")
    end

    # The agent, session and usage of the attempt that is ending. Every part is nil when it can't be told.
    #
    # The session that counts is the latest one started in the pane (the run's, or a review round's; this workspace's, on this tmux
    # server) at or before the attempt ended, unless it ended before the attempt began. A fresh-conversation
    # restart (and a `/clear`) starts a session after the attempt's record is made, so the last one is the
    # conversation that did the attempt's work. One that began before the attempt and never ended is chosen
    # only when its transcript has a line inside the attempt's window, since a pane id can outlive its tmux
    # server. Tokens are the main thread's, summed from transcript lines inside the attempt's own time
    # window, so a resumed attempt in the same session does not count earlier attempts.
    def agent_facts(run, attempt, pane: run["pane"])
      none = {"agent" => nil, "session" => nil, "usage" => nil}
      started = Time.iso8601(attempt["started_at"].to_s)
      ended = attempt["ended_at"] ? Time.iso8601(attempt["ended_at"].to_s) : @clock.call
      server = @server_for.call(pane)
      entry, ended_session = session_entry(run, pane, started, ended, server)
      return none unless entry
      kind = entry["kind"].nil? ? "claude" : entry["kind"]
      kind = nil unless kind.is_a?(String) && KIND.match?(kind)
      path = entry["transcript_path"]
      path = nil unless path.is_a?(String) && TRANSCRIPT_PATH.match?(path)
      # Only a startup or a /clear begins a new transcript file; a resume or a compact goes on in the old one.
      new_file = %w[startup clear].include?(entry["source"])
      read = if kind == "claude" && path
        read_transcript(path, started, ended, new_file ? time(entry["at"]) : nil)
      end
      return none if carried?(entry, started, server) && !ended_session && !(read && read[:seen])
      usage = (read && read[:ok]) ? with_subagents(read, path, entry["session_id"], started, ended) : nil
      {"session" => {"id" => entry["session_id"], "transcript" => path},
       "agent" => {"kind" => kind, "version" => read && read[:version], "model" => read && read[:model]},
       "usage" => usage}
    rescue
      {"agent" => nil, "session" => nil, "usage" => nil}
    end

    # @return [Array(Hash, Boolean), nil] the chosen SessionStart entry and whether a SessionEnd for it was seen
    def session_entry(run, pane, started, ended, server)
      return nil unless @ledger && pane.is_a?(String) && !pane.empty?
      names = Array(@session_names.call(run["workspace"])).select { |name| name.is_a?(String) && !name.empty? }
      entries = @ledger.recent_entries(max_bytes: MAX_LEDGER_BYTES, matching: pane)
      start = entries.reverse_each.find do |entry|
        entry["event"] == "session_start" && entry["pane_id"] == pane && names.include?(entry["workspace"]) &&
          (server.nil? || entry["tmux_server"].nil? || entry["tmux_server"].to_s == server.to_s) &&
          entry["session_id"].is_a?(String) && SESSION_ID.match?(entry["session_id"]) && (at = time(entry["at"])) && at <= ended
      end
      return nil unless start
      # Only an end at or after this start closes it: a session resumed under the same id starts again.
      start_at = time(start["at"])
      end_at = entries.find do |entry|
        entry["event"] == "session_end" && entry["session_id"] == start["session_id"] && (stop = time(entry["at"])) && stop >= start_at
      end&.fetch("at", nil)
      return nil if end_at && time(end_at) < started
      [start, !end_at.nil?]
    end

    # A session that began before the attempt (past a small slack) is carried over into it. It is trusted
    # without proof only when the pane's tmux server is known and is the one the session started under,
    # which rules out a restart that reused the pane id; otherwise its transcript has to show a line in the window.
    def carried?(entry, started, server)
      at = time(entry["at"])
      return false unless at && at < started - START_SLACK
      !(server && entry["tmux_server"] && entry["tmux_server"].to_s == server.to_s)
    end

    def time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # Reads the tail of the transcript once. A message written on several lines is one message: it is in the
    # window by its first line and counts as its last line says. Usage is nil, never a smaller count, when:
    # the tail starts after the window does (it must reach the attempt's start, or the chosen session's
    # first line when that came later), a usage line has no readable time, or a count is not a whole number
    # at least 0. Sub-agent (`isSidechain`) lines are left out.
    #
    # With `sidechain` true the file is a sub-agent's own transcript: its lines are all sidechain and all
    # count, and the answer's `ok` says whether it can be trusted. A file with nothing in the window is `ok` with no `records`
    # (and a nil `usage`).
    def read_transcript(path, from, to, session_at, sidechain: false)
      return nil unless File.lstat(path).file?
      lines, complete = tail_lines(path)
      floor = (session_at && session_at >= from) ? session_at : from
      messages = {}
      version = nil
      reached = complete
      unreadable = seen = false
      lines.each_with_index do |line, index|
        entry = parse_line(line) or next
        next if entry["isSidechain"] == true && !sidechain
        message = (entry["type"] == "assistant" && entry["message"].is_a?(Hash)) ? entry["message"] : nil
        at = time(entry["timestamp"])
        unless at
          unreadable = true if message&.key?("usage")
          next
        end
        unreadable = true if message&.key?("usage") && !message["usage"].is_a?(Hash)
        reached = true if at <= floor
        inside = at.between?(from, to)
        seen = true if inside
        version = entry["version"] if inside && entry["version"].is_a?(String) && VERSION.match?(entry["version"])
        next unless message
        record = (messages[message["id"].is_a?(String) ? message["id"] : index] ||= {first: at})
        record[:usage] = message["usage"] if message["usage"].is_a?(Hash)
        record[:model] = message["model"] if message["model"].is_a?(String) && MODEL.match?(message["model"]) && message["model"] != "<synthetic>"
      end
      counted = messages.values.select { |record| record[:usage] && record[:first] >= from && record[:first] <= to }
      records = counted.map { |record| record[:usage] }
      {usage: (reached && !unreadable) ? total(records) : nil, records: records, ok: reached && !unreadable,
       model: counted.reverse_each.find { |record| record[:model] }&.fetch(:model), version: version, seen: seen}
    rescue SystemCallError, IOError
      nil
    end

    # The attempt's usage with its sub-agents': each `agent-*.jsonl` under `<transcript dir>/<session id>/subagents/`
    # is read with the main transcript's window and tail rules and summed with the main thread's. The
    # directory is derived from the session's own transcript path, never from a hook payload, and no link is
    # followed. The session id must be the transcript file's own name (so it can never be `.` or `..` or
    # name another directory); when it is not, the usage is nil (uncounted), as it is for a sub-agent file
    # that can't be read whole enough, a link, a directory with too many entries or one that can't be listed.
    # A file last written before the attempt began can't hold a line inside it and is not read or counted
    # toward the cap of {MAX_SUBAGENT_FILES}. No such directory adds nothing.
    def with_subagents(main, path, session_id, from, to)
      return nil unless session_id.is_a?(String) && SESSION_ID.match?(session_id) && !%w[. ..].include?(session_id) &&
        session_id == File.basename(path, ".jsonl")
      session_dir = File.join(File.dirname(path), session_id)
      dir = File.join(session_dir, "subagents")
      [session_dir, dir].each do |each|
        return nil unless File.lstat(each).directory?
      end
      seen = 0
      names = []
      Dir.each_child(dir) do |name|
        return nil if (seen += 1) > MAX_SUBAGENT_ENTRIES
        next unless SUBAGENT_FILE.match?(name)
        next if File.lstat(File.join(dir, name)).mtime < from - START_SLACK
        names << name
        return nil if names.size > MAX_SUBAGENT_FILES
      end
      records = main[:records].dup
      names.sort.each do |name|
        read = read_transcript(File.join(dir, name), from, to, nil, sidechain: true)
        return nil unless read && read[:ok]
        records.concat(read[:records])
      end
      total(records)
    rescue Errno::ENOENT, Errno::ENOTDIR
      main[:usage]
    rescue SystemCallError, IOError
      nil
    end

    def tail_lines(path)
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        return [[], false] unless file.stat.file?
        start = [file.size - @max_transcript_bytes, 0].max
        file.seek(start)
        lines = file.read.to_s.force_encoding(Encoding::UTF_8).scrub.split("\n")
        lines.shift if start > 0
        [lines, start == 0]
      end
    end

    def parse_line(line)
      entry = JSON.parse(line)
      entry.is_a?(Hash) ? entry : nil
    rescue JSON::ParserError
      nil
    end

    def total(usages)
      return nil if usages.empty?
      return nil unless usages.all? { |usage| USAGE_KEYS.all? { |key| !usage.key?(key) || (usage[key].is_a?(Integer) && usage[key] >= 0) } }
      sums = USAGE_KEYS.to_h { |key| [key, usages.sum { |usage| usage[key] || 0 }] }
      sums.reject { |key, value| value.zero? && key.start_with?("cache_") }
    end

    # With an evidence copy that holds the file, its hash is the copy's, so the two records can't differ and
    # the file is read once. For a file the copy did not take (over the attempt's budget, a failed write, a
    # missing file, one outside the artifacts directory) the file is hashed here, as it is with no collaborator (except one refused as `outside_artifacts`, which records nil).
    def outputs(step, run, copies)
      copied = copies.select { |each| each["kind"] == "output" }
      Array(step["produces"]).each_with_index.map do |file, index|
        copy = copied[index]
        # A file evidence refused as outside the artifacts directory is not read here either.
        next {"file" => file, "sha256" => nil, "bytes" => nil} if copy && copy["problem"] == "outside_artifacts"
        next output(file, File.join(run["artifacts_dir"].to_s, file)) unless copy && copy["sha256"]
        {"file" => file, "sha256" => copy["sha256"], "bytes" => copy["bytes"]}
      end
    end

    def output(file, path)
      content = WorkflowProduced.digest(path, max_bytes: @max_hash_bytes)
      return {"file" => file, "sha256" => nil, "bytes" => nil} unless content
      record = {"file" => file, "sha256" => content.sha256, "bytes" => content.bytes}
      record["too_large"] = true if content.too_large
      record
    end
  end
end
