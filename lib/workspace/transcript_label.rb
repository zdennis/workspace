require "json"

module Workspace
  # Reads the title and last prompt Claude Code keeps in a session's
  # transcript, so `sessions --json` can label a pane by what it is doing.
  #
  # Claude rewrites the `ai-title` line as the session goes, and writes a
  # `last-prompt` line each turn, so the last of each near the end of the
  # file is the current one. Only those two JSON fields are read; the rest of
  # the transcript is never kept. A transcript can run to megabytes, so only
  # the tail is read, and the result is cached until the file changes.
  class TranscriptLabel
    # Bytes read from the end of a transcript.
    TAIL_BYTES = 256 * 1024

    # Longest title or prompt returned.
    MAX_LENGTH = 80

    # Transcripts remembered at once; the cache is cleared when it passes this.
    MAX_CACHED = 64

    EMPTY = {title: nil, last_prompt: nil}.freeze

    def initialize
      @cache = {}
    end

    # @param path [String, nil] a transcript path from a hook event
    # @return [Hash] `title:` the last `ai-title`, and `last_prompt:` the last
    #   `last-prompt`, each cleaned and cut to {MAX_LENGTH} characters, or nil.
    #   Both are nil for a path that is nil, not a `.jsonl` file, or unreadable.
    def read(path)
      return EMPTY unless path.is_a?(String) && path.end_with?(".jsonl")

      stat = File.stat(path)
      return EMPTY unless stat.file?

      key = [stat.mtime, stat.size]
      cached = @cache[path]
      return cached[:value] if cached && cached[:key] == key

      value = scan(path, stat.size)
      @cache.clear if @cache.size >= MAX_CACHED
      @cache[path] = {key: key, value: value}
      value
    rescue SystemCallError, IOError
      EMPTY
    end

    private

    def scan(path, size)
      lines = File.open(path, "rb") { |file|
        file.seek(size - TAIL_BYTES) if size > TAIL_BYTES
        file.read.to_s.force_encoding(Encoding::UTF_8).scrub.lines
      }
      # A tail read starts mid-line, so the first line may be a fragment.
      lines.shift if size > TAIL_BYTES
      {title: last_value(lines, "ai-title", "aiTitle"), last_prompt: last_value(lines, "last-prompt", "lastPrompt")}
    end

    def last_value(lines, type, field)
      lines.reverse_each do |line|
        next unless line.include?("\"#{type}\"")

        entry = JSON.parse(line)
        value = entry[field] if entry.is_a?(Hash) && entry["type"] == type
        cleaned = clean(value)
        return cleaned if cleaned
      rescue JSON::ParserError
        next
      end
      nil
    end

    def clean(value)
      return nil unless value.is_a?(String)

      text = value.gsub(/[[:space:][:cntrl:]]+/, " ").strip[0, MAX_LENGTH]
      text unless text.empty?
    end
  end
end
