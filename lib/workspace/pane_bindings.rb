require "json"
require "fileutils"
require "time"

module Workspace
  # Maps a tmux pane to the subject it works on (a workflow run, a PR
  # review, or a library play sent by `start --play`/`launch --play`), in `bindings.json` under workspace's state directory.
  #
  # The `session-event` hook reads it on every SessionStart, so a bound pane
  # gets a short reminder of its subject after a restart, `/clear`, resume or
  # compaction. Entries are keyed on the tmux pane id, never the index, and
  # carry the tmux session and pane slot they were made for: a pane id from
  # another session, or one reused after a tmux restart, is not the same pane.
  #
  # Only short structured fields are stored, never prompt text.
  class PaneBindings
    # Subjects a pane can be bound to.
    KINDS = %w[run review play].freeze

    # Optional single-line text fields of an entry.
    TEXT_FIELDS = %w[step focus instructions artifacts].freeze

    # Key prefix of a binding whose pane id was taken by another pane (see {#move}).
    PARKED = "slot:"
    private_constant :PARKED

    # Longest value stored for `id` or any text field.
    MAX_FIELD_LENGTH = 200

    # @param path [String] path to `bindings.json`
    # @param clock [#call] returns the current Time, injected for specs
    # @param logger [Workspace::Logger] debug logger
    # @param error_output [IO] where a warning about a corrupt file is written
    def initialize(path:, clock: -> { Time.now }, logger: Workspace::Logger.new, error_output: $stderr)
      @path = path
      @error_output = error_output
      @clock = clock
      @logger = logger
    end

    # Binds a pane, replacing any earlier binding for the same pane id.
    #
    # @param pane_id [String] a tmux pane id (e.g. "%5")
    # @param fields [Hash{String=>Object}] `kind` and `id` (required), `attempt`,
    #   and any of {TEXT_FIELDS}; plus the `workspace`, tmux `session` and `pane_slot` it was made for
    # @return [Hash{String=>Object}] the stored entry
    # @raise [Workspace::UsageError] for an unknown kind, a missing or oversized id, an
    #   attempt below 1, or a field that is not one line of text
    # @raise [SystemCallError] if the file can't be written
    def bind(pane_id, fields)
      entry = validate(fields).merge("pane_id" => pane_id, "bound_at" => @clock.call.utc.iso8601)
      update { |all| all[pane_id] = entry }
      entry
    end

    # @param pane_id [String]
    # @return [Hash{String=>Object}, nil] the binding, or nil when the pane is not
    #   bound or the file is missing or unreadable
    def binding_for(pane_id)
      entry = read[pane_id]
      entry.is_a?(Hash) ? entry : nil
    end

    # @param pane_id [String]
    # @return [Hash{String=>Object}, nil] the binding that was removed, nil if there was none
    def unbind(pane_id)
      removed = nil
      update { |all| removed = all.delete(pane_id) }
      removed
    end

    # Moves bindings to the panes that replaced theirs, for `restore`: after a
    # tmux restart a pane has a new id, and the binding follows its slot. A
    # binding is moved only if it was made for the move's session and old
    # slot; one without a recorded slot is left alone.
    #
    # Pane ids start over when tmux restarts, so a new pane can carry the id
    # another bound pane had. All moves happen in one write and every binding
    # is picked before any is placed, so moves never replace each other. A
    # binding found at a new pane's id that no move picked is not lost while
    # it can still be used: if it is that pane's own (same session and slot)
    # it stays and the move is not made; otherwise it belongs to a pane that
    # is gone, and it is kept under `slot:<its slot>` until a later move for
    # that slot claims it. Only one with no recorded slot, which no move
    # could ever claim, is replaced.
    #
    # @param moves [Array<Hash>] `:from` and `:to` pane ids, the tmux `:session`,
    #   and the pane's `:from_slot` and `:to_slot`
    # @return [Hash{String=>Hash}] new pane id => the binding now stored for it
    # @raise [SystemCallError] if the file can't be written
    def move(moves)
      current = read
      return {} unless moves.any? { |move| source_key(current, move) }

      moved = {}
      update do |all|
        picked = moves.filter_map do |move|
          key = source_key(all, move)
          [move, key, all[key]] if key
        end
        picked.each { |_, key, _| all.delete(key) }
        picked.each do |move, key, entry|
          resident = all[move[:to]]
          if resident.is_a?(Hash) && resident["session"] == move[:session] && [nil, move[:to_slot]].include?(resident["pane_slot"])
            all[key] ||= entry
            next
          end
          all["#{PARKED}#{resident["pane_slot"]}"] = resident if resident.is_a?(Hash) && resident["pane_slot"]
          moved[move[:to]] = all[move[:to]] = entry.merge("pane_id" => move[:to], "pane_slot" => move[:to_slot])
        end
      end
      moved
    end

    # A binding only counts for the tmux session and pane slot it was made in:
    # a pane id from another session, or one reused after a tmux restart, is
    # not the same pane. The SessionStart hook stays quiet for a stale binding,
    # `binding show` marks it, and `instructions compose` leaves it out.
    #
    # @param entry [Hash{String=>Object}] a binding
    # @param session [String, nil] the tmux session the pane is in now; nil when tmux can't find it
    # @param pane_slot [String, nil] the pane's slot now (`session:window.pane`)
    # @return [Boolean] true when the pane is in another session or slot than the binding's
    def stale?(entry, session:, pane_slot:)
      return true unless entry["session"] == session
      !entry["pane_slot"].nil? && entry["pane_slot"] != pane_slot
    end

    # The block the SessionStart hook hands the agent as `additionalContext`.
    # Short on purpose: the instructions file holds the bulk.
    #
    # @param entry [Hash{String=>Object}] a binding
    # @return [String]
    def context_for(entry)
      where = (" in #{entry["workspace"]}" if entry["workspace"])
      return play_context(entry, where) if entry["kind"] == "play"

      subject = (entry["kind"] == "review") ? "review" : "workflow run"
      lines = ["This pane is bound to #{subject} #{entry["id"]}#{where}."]
      lines << "Step: #{entry["step"]}#{" (attempt #{entry["attempt"]})" if entry["attempt"]}." if entry["step"]
      lines << "Focus: #{entry["focus"]}." if entry["focus"]
      lines << "Instructions: #{entry["instructions"]}. Reread them if your context was compacted." if entry["instructions"]
      lines << "Artifacts: #{entry["artifacts"]}." if entry["artifacts"]
      lines.join("\n")
    end

    private

    # A play is a file the agent was told to read and follow; after `/clear` it
    # has to read it again to keep following it.
    def play_context(entry, where)
      lines = ["This pane is following play #{entry["id"]}#{where}."]
      lines << "Instructions: #{entry["instructions"]}. Read it again and keep following it if it is no longer in your context." if entry["instructions"]
      lines.join("\n")
    end

    # Where the binding a move is for sits: under its old pane id, or under
    # its slot if a pane that took that id displaced it.
    def source_key(all, move)
      [move[:from], "#{PARKED}#{move[:from_slot]}"].find { |key| movable?(all[key], move) }
    end

    def movable?(entry, move)
      entry.is_a?(Hash) && entry["session"] == move[:session] && !entry["pane_slot"].nil? && entry["pane_slot"] == move[:from_slot]
    end

    def validate(fields)
      kind = fields["kind"]
      unless KINDS.include?(kind)
        raise UsageError, "Unknown binding kind #{kind.to_s[0, 40].inspect}: one of #{KINDS.join(", ")}."
      end
      entry = {"kind" => kind, "id" => line!("id", fields["id"])}
      attempt = fields["attempt"]
      unless attempt.nil?
        raise UsageError, "attempt must be a whole number of 1 or more." unless attempt.is_a?(Integer) && attempt >= 1
        entry["attempt"] = attempt
      end
      TEXT_FIELDS.each { |key| entry[key] = line!(key, fields[key]) unless fields[key].nil? }
      %w[workspace session pane_slot].each { |key| entry[key] = fields[key] if fields[key] }
      entry
    end

    def line!(key, value)
      text = value.to_s
      if text.strip.empty? || text.length > MAX_FIELD_LENGTH || text.match?(/[[:cntrl:]]/)
        raise UsageError, "#{key} must be one line of text, 1 to #{MAX_FIELD_LENGTH} characters."
      end
      text
    end

    # With keep_corrupt, a file that can't be parsed is copied to `<path>.corrupt` before the
    # caller replaces it, and a warning is written; a plain read (the hook) stays quiet.
    def read(keep_corrupt: false)
      parsed = JSON.parse(File.read(@path))
      parsed.is_a?(Hash) ? parsed : set_aside_corrupt(keep_corrupt)
    rescue JSON::ParserError, EncodingError => e
      @logger.debug { "pane_bindings: read failed (#{e.class}: #{e.message})" }
      set_aside_corrupt(keep_corrupt)
    rescue SystemCallError => e
      @logger.debug { "pane_bindings: read failed (#{e.class}: #{e.message})" } unless e.is_a?(Errno::ENOENT)
      {}
    end

    def set_aside_corrupt(keep_corrupt)
      if keep_corrupt
        FileUtils.cp(@path, "#{@path}.corrupt")
        @error_output.puts "Warning: #{@path} was not valid; its old contents are kept in #{@path}.corrupt."
      end
      {}
    end

    # Writers hold an exclusive lock on a sidecar file and replace the file
    # whole, so a reader never sees a torn write.
    def update
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        all = read(keep_corrupt: true)
        yield all
        temp = "#{@path}.#{Process.pid}.tmp"
        begin
          File.write(temp, JSON.pretty_generate(all), perm: 0o600)
          File.rename(temp, @path)
        ensure
          FileUtils.rm_f(temp)
        end
      end
    end
  end
end
