require "digest"
require "json"
require "time"

module Workspace
  # What an attempt records about itself in the run file: what it started from
  # ({#start}) and what it ended with ({#finish}, {#abandon}). It runs under the
  # run's lock, so every read is short, and a recording problem is a nil, never
  # an error: recording must not fail a step, a cancel or a kill.
  class WorkflowAttemptRecord
    # A produced file above this many bytes is recorded with its size and no hash.
    MAX_HASH_BYTES = 16 * 1024 * 1024

    # The last bytes of the session ledger read to find an attempt's session; a ledger is never rotated.
    MAX_LEDGER_BYTES = 1024 * 1024

    # The last bytes of a transcript read for an attempt's usage, model and version. Attempt recording
    # runs under the run's lock, so a transcript is never read whole; when the tail does not reach back
    # to the attempt's start, `usage` is recorded as nil rather than a count that leaves tokens out.
    MAX_TRANSCRIPT_BYTES = 4 * 1024 * 1024

    # An attempt's start is recorded a moment before its session's hook may have been.
    START_SLACK = 5

    SESSION_ID = /\A[A-Za-z0-9._-]{1,128}\z/
    TRANSCRIPT_PATH = %r{\A/[^\x00-\x1f\x7f]{1,4095}\.jsonl\z}
    VERSION = /\A[A-Za-z0-9._+-]{1,50}\z/
    MODEL = /\A[A-Za-z0-9._:\/\[\]-]{1,100}\z/
    KIND = /\A[a-z][a-z0-9_-]{0,31}\z/
    USAGE_KEYS = %w[input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens].freeze
    private_constant :START_SLACK, :SESSION_ID, :TRANSCRIPT_PATH, :VERSION, :MODEL, :KIND, :USAGE_KEYS

    # @param guard [Workspace::WorkflowGuard] reads the checkout's HEAD
    # @param ledger [Workspace::SessionLedger, nil] finds an attempt's session; nil records none
    # @param clock [#call] returns the current Time
    # @param session_names [#call] given a workspace name, the names the session hook may have recorded
    #   its panes under (the workspace's, and its tmux session's)
    # @param server_for [#call] given a pane id, the pid of its tmux server, or nil
    # @param evidence [Workspace::WorkflowEvidence, nil] copies the attempt's files aside; nil keeps none
    def initialize(guard:, ledger: nil, clock: -> { Time.now }, session_names: ->(workspace) { [workspace] }, server_for: ->(_pane) {}, evidence: nil)
      @evidence = evidence
      @guard = guard
      @ledger = ledger
      @clock = clock
      @session_names = session_names
      @server_for = server_for
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
      # The prompt is copied as it is written, before it is delivered: the agent has not seen it yet.
      attempt["evidence"] = @evidence.prompt(run: run, step_id: run["current"], attempt: attempt) if @evidence && attempt["prompt_file"]
      attempt
    end

    # Records HEAD now and each declared `produces` file when an attempt passes or fails, and copies its
    # prompt, check log and those files to the evidence directory (`evidence`, see {WorkflowEvidence}).
    # A check log is complete here for a passed or failed check; a cancel or kill that stops a check
    # keeps the log as it stood, and what the stopped check writes later is not copied.
    #
    # @param run [Hash{String=>Object}]
    # @param step [Hash{String=>Object}] the step's definition
    # @param attempt [Hash{String=>Object}] changed in place
    # @return [Hash{String=>Object}] the attempt
    def finish(run:, step:, attempt:)
      attempt["head"] = (attempt["head"] || {"before" => nil}).merge("after" => @guard.head(run["worktree"]))
      copies = @evidence ? @evidence.copy(run: run, step: step, attempt: attempt) : []
      attempt["outputs"] = outputs(step, run, copies)
      attempt.merge!(agent_facts(run, attempt))
      attempt["evidence"] = Array(attempt["evidence"]).select { |each| each["kind"] == "prompt" } + copies if @evidence
      attempt
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
    # @param run [Hash{String=>Object}] changed in place
    # @param was_open [Array(String, Integer), nil] {#open_attempt} read before the change
    # @return [nil]
    def reasons(run:, was_open: nil)
      current = effective_reason(run)
      _, entry = open_entry(run)
      return nil if entry && current && entry["code"] == current["code"] && entry["since"] == current["since"]
      reopened = current && closed_entry(run, current)
      # A park replaced by a park keeps the mark, so the wait under it can still be reopened.
      each_entry(run) { |each| each.delete("parked") unless each.equal?(entry) } unless entry && entry["code"] == "parked"
      if entry
        entry["until"] = @clock.call.utc.iso8601
        entry["parked"] = true if current && current["code"] == "parked"
      end
      return nil unless current
      # A wait that a park interrupted and the park gave back is one wait: the entry the park closed (marked
      # `parked` while the park stands) is reopened, its `until` cleared, rather than a second one opened.
      if reopened
        reopened.delete("parked")
        reopened["until"] = nil
        return nil
      end
      owner = reason_owner(run, was_open, current)
      owner << {"code" => current["code"], "since" => current["since"], "until" => nil}.merge(owner.equal?(run["reasons"]) ? {"step" => run["current"]} : {})
      nil
    rescue
      nil
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

    def effective_reason(run)
      parked = run["parked"]
      return {"code" => "parked", "since" => parked["requested_at"]} if parked.is_a?(Hash)
      reason = run["reason"]
      (reason.is_a?(Hash) && reason["code"].is_a?(String)) ? reason : nil
    end

    def each_entry(run, &block)
      lists = [run["reasons"]] + run["steps"].to_h.values.flat_map { |state| Array(state["attempts"]).map { |attempt| attempt["reasons"] } }
      lists.compact.each { |list| list.each(&block) }
    end

    def closed_entry(run, current)
      found = nil
      each_entry(run) { |each| found ||= each if each["parked"] && each["code"] == current["code"] && each["since"] == current["since"] }
      found
    end

    def open_entry(run)
      lists = [run["reasons"]] + run["steps"].to_h.values.flat_map { |state| Array(state["attempts"]).map { |attempt| attempt["reasons"] } }
      lists.compact.each do |list|
        entry = list.find { |each| each["until"].nil? }
        return [list, entry] if entry
      end
      [nil, nil]
    end

    def reason_owner(run, was_open, current)
      attempt = run.dig("steps", run["current"], "attempts")&.last
      if attempt && (attempt["ended_at"].nil? || (was_open == [run["current"], attempt["n"]] && set_by_ending?(current, attempt)))
        return (attempt["reasons"] ||= [])
      end
      run["reasons"] ||= []
    end

    def set_by_ending?(reason, attempt)
      details = reason["details"].is_a?(Hash) ? reason["details"] : {}
      (reason["code"] == "failed_check" && details["attempt"] == attempt["n"]) || (reason["code"] == "waiting_you" && details["kind"] == "gate")
    end

    # The agent, session and usage of the attempt that is ending. Every part is nil when it can't be told.
    #
    # The session that counts is the latest one started in the run's pane (this workspace's, on this tmux
    # server) at or before the attempt ended, unless it ended before the attempt began. A fresh-conversation
    # restart (and a `/clear`) starts a session after the attempt's record is made, so the last one is the
    # conversation that did the attempt's work. One that began before the attempt and never ended is chosen
    # only when its transcript has a line inside the attempt's window, since a pane id can outlive its tmux
    # server. Tokens are the main thread's, summed from transcript lines inside the attempt's own time
    # window, so a resumed attempt in the same session does not count earlier attempts.
    def agent_facts(run, attempt)
      none = {"agent" => nil, "session" => nil, "usage" => nil}
      started = Time.iso8601(attempt["started_at"].to_s)
      ended = attempt["ended_at"] ? Time.iso8601(attempt["ended_at"].to_s) : @clock.call
      server = @server_for.call(run["pane"])
      entry, ended_session = session_entry(run, started, ended, server)
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
      {"session" => {"id" => entry["session_id"], "transcript" => path},
       "agent" => {"kind" => kind, "version" => read && read[:version], "model" => read && read[:model]},
       "usage" => read && read[:usage]}
    rescue
      {"agent" => nil, "session" => nil, "usage" => nil}
    end

    # @return [Array(Hash, Boolean), nil] the chosen SessionStart entry and whether a SessionEnd for it was seen
    def session_entry(run, started, ended, server)
      pane = run["pane"]
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
    def read_transcript(path, from, to, session_at)
      return nil unless File.lstat(path).file?
      lines, complete = tail_lines(path)
      floor = (session_at && session_at >= from) ? session_at : from
      messages = {}
      version = nil
      reached = complete
      unreadable = seen = false
      lines.each_with_index do |line, index|
        entry = parse_line(line) or next
        next if entry["isSidechain"] == true
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
      {usage: (reached && !unreadable) ? total(counted.map { |record| record[:usage] }) : nil,
       model: counted.reverse_each.find { |record| record[:model] }&.fetch(:model), version: version, seen: seen}
    rescue SystemCallError, IOError
      nil
    end

    def tail_lines(path)
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        return [[], false] unless file.stat.file?
        start = [file.size - MAX_TRANSCRIPT_BYTES, 0].max
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
      content = WorkflowProduced.digest(path, max_bytes: MAX_HASH_BYTES)
      return {"file" => file, "sha256" => nil, "bytes" => nil} unless content
      record = {"file" => file, "sha256" => content.sha256, "bytes" => content.bytes}
      record["too_large"] = true if content.too_large
      record
    end
  end
end
