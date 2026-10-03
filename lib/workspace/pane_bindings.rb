require "json"
require "fileutils"
require "time"

module Workspace
  # Maps a tmux pane to the subject it works on (a workflow run or a PR
  # review), in `bindings.json` under workspace's state directory.
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
    KINDS = %w[run review].freeze

    # Optional single-line text fields of an entry.
    TEXT_FIELDS = %w[step focus instructions artifacts].freeze

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

    # The block the SessionStart hook hands the agent as `additionalContext`.
    # Short on purpose: the instructions file holds the bulk.
    #
    # @param entry [Hash{String=>Object}] a binding
    # @return [String]
    def context_for(entry)
      subject = (entry["kind"] == "review") ? "review" : "workflow run"
      lines = ["This pane is bound to #{subject} #{entry["id"]}#{" in #{entry["workspace"]}" if entry["workspace"]}."]
      lines << "Step: #{entry["step"]}#{" (attempt #{entry["attempt"]})" if entry["attempt"]}." if entry["step"]
      lines << "Focus: #{entry["focus"]}." if entry["focus"]
      lines << "Instructions: #{entry["instructions"]}. Reread them if your context was compacted." if entry["instructions"]
      lines << "Artifacts: #{entry["artifacts"]}." if entry["artifacts"]
      lines.join("\n")
    end

    private

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
