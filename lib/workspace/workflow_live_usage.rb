require "fileutils"
require "json"
require "time"

module Workspace
  # Reads the tokens a run's running attempt has used so far, while its agent is still at work: the attempt
  # {WorkflowBudget.reading} leaves out. It finds the attempt's session in the ledger on every call, by the
  # rules {WorkflowAttemptRecord} records `usage` by ({TranscriptUsage.session_entry}, {.agent_kind},
  # {.floor}, {.carried?} and {.subagent_files}), and counts the transcript lines as that record does: a
  # message is in the window by its first line and counts as its last usage line says, sub-agent files included.
  #
  # Each call reads only what is new. A cache per run under `<dir>/<run id>/` keeps, for the main transcript
  # and each sub-agent file, the byte offset read up to (always just after a newline), how far back from
  # there the first scan has got, and the messages seen. One call reads at most `max_read_bytes` in all,
  # across every file, forward and back, so a long transcript or many sub-agent files are caught up over
  # several calls. The cache resets when its key (run, step, attempt, pane, tmux server, session, session
  # start, transcript path) or a file's device and inode differ, or a file is shorter than the offset. A lost
  # cache write only costs reading those bytes again.
  #
  # The figure is nil whenever there is doubt: no running attempt, no session, another agent than Claude
  # Code, a transcript that can't be read, a back scan that has not yet reached the attempt's start, a file
  # with bytes still unread, a usage line with no readable time, or a sub-agent file that can't be read.
  class WorkflowLiveUsage
    CACHE_FILE = "usage.json"
    STATES = %w[running checking].freeze
    # One call's read budget, and whether it changed the cache.
    Pass = Struct.new(:left, :dirty)
    private_constant :CACHE_FILE, :STATES, :Pass

    # @param dir [String] where the caches live: `<workflow runs dir>/live`, never the runs dir itself
    # @param ledger [Workspace::SessionLedger, nil] finds an attempt's session; nil finds none
    # @param session_names [#call] given a workspace name, the names the session hook may have recorded its panes under
    # @param server_for [#call] given a pane id, the pid of its tmux server, or nil
    # @param max_read_bytes [Integer] the most bytes one call reads, over every file
    # @param read_bytes [#call] `(file, offset, length) -> String`, the one read of a file's bytes
    def initialize(dir:, ledger:, session_names: ->(workspace) { [workspace] }, server_for: ->(_pane) {},
      max_read_bytes: TranscriptUsage::MAX_TRANSCRIPT_BYTES, read_bytes: ->(file, offset, length) {
        file.seek(offset)
        file.read(length).to_s
      })
      @dir = dir
      @ledger = ledger
      @session_names = session_names
      @server_for = server_for
      @max_read_bytes = max_read_bytes
      @read_bytes = read_bytes
    end

    # The tokens (`input_tokens`, `output_tokens` and `cache_creation_input_tokens`, as
    # {WorkflowBudget.tokens_of} counts them) the run's running attempt has used up to `now`. A run with no
    # running attempt has its cache removed.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param now [Time] the end of the attempt's window
    # @return [Integer, nil] nil unless the figure can be trusted
    def reading(run, now:)
      run = WorkflowRun.from_h(run)
      id = run.id
      return nil unless id.is_a?(String) && RunLiveness::ID_PATTERN.match?(id)
      attempt = running_attempt(run)
      return forget(id) unless attempt
      started = TranscriptUsage.time(attempt.started_at) or return nil
      server = @server_for.call(run.pane)
      entry, ended_session = TranscriptUsage.session_entry(ledger: @ledger, names: @session_names.call(run.workspace),
        pane: run.pane, started: started, ended: now, server: server)
      return nil unless entry && TranscriptUsage.agent_kind(entry) == "claude"
      path = entry["transcript_path"]
      return nil unless TranscriptUsage.transcript_path?(path)
      key = {"run" => id, "step" => run.current, "attempt" => attempt.n, "pane" => run.pane,
             "tmux_server" => entry["tmux_server"]&.to_s, "session_id" => entry["session_id"], "session_at" => entry["at"],
             "transcript" => path}
      window = {from: started, to: now}
      pass = Pass.new(@max_read_bytes, false)
      cache = load(id, key, pass)
      main = advance(cache["main"], path, pass, floor: TranscriptUsage.floor(entry, started), sidechain: false, **window)
      cache["main"] = main && main[:state]
      subagents = main && subagent_reads(cache, path, entry["session_id"], pass, **window)
      save(id, cache) if pass.dirty
      return nil unless main && main[:ok] && subagents
      return nil if TranscriptUsage.carried?(entry, started, server) && !ended_session && !main[:state]["seen"]
      usage = ([main] + subagents).flat_map { |read| counted(read[:state], **window) }
      return 0 if usage.empty?
      WorkflowBudget.tokens_of(TranscriptUsage.total(usage))
    rescue
      nil
    end

    # Removes the caches of runs that are no longer going.
    #
    # @param going_ids [Array<String>] the ids of the runs still going
    # @return [Array<String>] the run ids whose caches were removed
    def prune(going_ids)
      keep = Array(going_ids).map(&:to_s)
      Dir.children(@dir).sort.filter_map do |name|
        next if keep.include?(name)
        path = File.join(@dir, name)
        next unless File.lstat(path).directory?
        FileUtils.rm_rf(path)
        name
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      []
    end

    private

    def running_attempt(run)
      step = run.current_step
      return nil unless step && STATES.include?(step.state)
      step.last_attempt
    end

    def forget(id)
      path = File.join(@dir, id)
      FileUtils.rm_rf(path) if File.lstat(path).directory?
      nil
    rescue SystemCallError
      nil
    end

    def cache_path(id) = File.join(@dir, id, CACHE_FILE)

    def load(id, key, pass)
      cache = JSON.parse(File.read(cache_path(id)))
      valid = cache.is_a?(Hash) && cache["key"] == key && cache["subagents"].is_a?(Hash) &&
        (cache["main"].nil? || state?(cache["main"])) && cache["subagents"].values.all? { |state| state?(state) }
      valid ? cache : fresh(key, pass)
    rescue SystemCallError, IOError, JSON::ParserError
      fresh(key, pass)
    end

    def fresh(key, pass)
      pass.dirty = true
      {"key" => key, "main" => nil, "subagents" => {}}
    end

    def state?(state)
      state.is_a?(Hash) && %w[dev ino].all? { |name| state[name].is_a?(Integer) } &&
        %w[fwd back].all? { |name| state[name].nil? || (state[name].is_a?(Integer) && state[name] >= 0) } &&
        state["messages"].is_a?(Hash) && state["messages"].values.all? { |record| record?(record) }
    end

    def record?(record)
      record.is_a?(Hash) && record["first_pos"].is_a?(Integer) && TranscriptUsage.time(record["first_at"]) &&
        (record["usage"].nil? || (record["usage"].is_a?(Hash) && record["usage_pos"].is_a?(Integer)))
    end

    def save(id, cache)
      FileUtils.mkdir_p(File.join(@dir, id), mode: 0o700)
      AtomicFile.write(cache_path(id), JSON.generate(cache), fsync: false, tag: Thread.current.object_id)
    rescue SystemCallError, IOError
      nil
    end

    # Reads what is new in one file into its state, out of the pass's budget: forward from the offset, then
    # back from where the first scan has got. nil when the file can't be read; else its new state and whether
    # it can be trusted (the scan reached the floor or the file's start, nothing complete is left unread past
    # the offset, and no usage line was unreadable).
    def advance(state, path, pass, floor:, sidechain:, from:, to:)
      return nil unless File.lstat(path).file?
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        stat = file.stat
        return nil unless stat.file?
        size = stat.size
        same = state && state["dev"] == stat.dev && state["ino"] == stat.ino && (state["fwd"].nil? || size >= state["fwd"])
        unless same
          pass.dirty = true
          state = {"dev" => stat.dev, "ino" => stat.ino, "fwd" => nil, "back" => nil, "reached" => false, "unreadable" => false, "seen" => false, "messages" => {}}
        end
        lines = {floor: floor, sidechain: sidechain, from: from, to: to}
        behind = state["fwd"] ? scan_forward(file, state, size, pass, **lines) : false
        scan_back(file, state, size, pass, **lines) unless state["reached"]
        drop_before(state, from) if state["reached"] && pass.dirty
        {state: state, ok: state["reached"] && !behind && !state["unreadable"]}
      end
    rescue SystemCallError, IOError
      nil
    end

    # @return [Boolean] whether bytes are left past this call's read
    def scan_forward(file, state, size, pass, **lines)
      offset = state["fwd"]
      return false if offset >= size
      length = [size - offset, pass.left].min
      data = bytes(file, offset, length, pass)
      cut = data.rindex("\n")
      return length < size - offset unless cut
      feed(state, data.byteslice(0, cut + 1), offset, **lines)
      state["fwd"] = offset + cut + 1
      length < size - offset
    end

    # The first scan starts at the file's last newline and goes back a chunk per call. A chunk that starts
    # inside a line leaves that line to the next chunk; a line longer than a chunk never lets the scan go on.
    def scan_back(file, state, size, pass, **lines)
      high = state["back"] || size
      low = [high - pass.left, 0].max
      data = bytes(file, low, high - low, pass)
      if state["fwd"].nil?
        cut = data.rindex("\n")
        if cut.nil? && low == 0
          # Nothing but a line still being written: the scan has reached the start.
          state["fwd"] = state["back"] = 0
          state["reached"] = true
          return
        end
        return unless cut
        data = data.byteslice(0, cut + 1)
        state["fwd"] = low + cut + 1
      end
      start = low
      if low > 0
        first = data.index("\n") or return
        start = low + first + 1
        data = data.byteslice(first + 1, data.bytesize)
      end
      feed(state, data, start, **lines)
      state["back"] = start
      state["reached"] = true if start == 0
    end

    def bytes(file, offset, length, pass)
      return "".b if length <= 0
      data = @read_bytes.call(file, offset, length).b
      pass.left -= data.bytesize
      pass.dirty = true unless data.empty?
      data
    end

    # Once the scan reaches back past the window, a message that began before it can never count: one with no
    # id can't come again and is dropped; one with an id keeps only its first line, so a later line of it
    # still reads as a message that began before the window.
    def drop_before(state, from)
      state["messages"].delete_if do |key, record|
        next false unless TranscriptUsage.time(record["first_at"]) < from
        record.delete("usage")
        record.delete("usage_pos")
        key.start_with?("@")
      end
    end

    # Applies whole lines by the per-line rules every usage reader shares ({TranscriptUsage.read_line}). A
    # message keeps the time of its line at the lowest byte position and the usage of its line at the highest,
    # so lines read backward count as lines read in file order do.
    def feed(state, data, base, floor:, sidechain:, from:, to:)
      position = base
      data.each_line("\n") do |raw|
        at = position
        position += raw.bytesize
        read = TranscriptUsage.read_line(raw.chomp("\n").force_encoding(Encoding::UTF_8).scrub) or next
        next if read.sidechain && !sidechain
        state["unreadable"] = true if read.unreadable
        next unless read.at
        state["reached"] = true if read.at <= floor
        state["seen"] = true if read.at.between?(from, to)
        next unless read.message
        record = (state["messages"][read.id || "@#{at}"] ||= {})
        if record["first_pos"].nil? || at < record["first_pos"]
          record["first_pos"] = at
          record["first_at"] = read.at.utc.iso8601(6)
        end
        if read.usage && (record["usage_pos"].nil? || at > record["usage_pos"])
          record["usage_pos"] = at
          record["usage"] = read.usage.slice(*TranscriptUsage::USAGE_KEYS)
        end
      end
    end

    def counted(state, from:, to:)
      state["messages"].values.filter_map do |record|
        record["usage"] if record["usage"] && TranscriptUsage.time(record["first_at"]).between?(from, to)
      end
    end

    # Each file {TranscriptUsage.subagent_files} lists, read with its own state out of the same pass.
    # @return [Array<Hash>, nil] each file's read; nil when the listing is nil or any file can't be trusted yet
    def subagent_reads(cache, path, session_id, pass, from:, to:)
      files = TranscriptUsage.subagent_files(path, session_id, from) or return nil
      states = {}
      reads = files.map do |file|
        name = File.basename(file)
        read = advance(cache["subagents"][name], file, pass, floor: from, sidechain: true, from: from, to: to)
        states[name] = read[:state] if read
        read
      end
      pass.dirty = true unless states.keys.sort == cache["subagents"].keys.sort
      cache["subagents"] = states
      (reads.all? { |read| read && read[:ok] }) ? reads : nil
    end
  end
end
