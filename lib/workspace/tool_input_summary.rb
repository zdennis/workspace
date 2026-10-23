module Workspace
  # The short, safe summary of a tool call's input that `tool_started` and
  # `tool_finished` lines carry as `input`: the first line of a Bash command,
  # the file a file tool works on, a search's pattern, a fetch's URL. Any other
  # tool has none. File contents, Write bodies and edit text are never read.
  #
  # The summary has control characters blanked and is at most {MAX_BYTES}
  # bytes of UTF-8, cut on a character boundary; a cut summary ends with
  # {ELLIPSIS}, which counts toward the limit.
  module ToolInputSummary
    # Longest summary, in bytes.
    MAX_BYTES = 300

    # What ends a summary that was cut.
    ELLIPSIS = "…"

    # Tools that name one file in `file_path` or `notebook_path`.
    FILE_TOOLS = %w[Edit Write Read MultiEdit NotebookEdit NotebookRead].freeze

    # Tools that search by `pattern`, with an optional `path`.
    SEARCH_TOOLS = %w[Grep Glob].freeze

    # A search's path is shown only when it is this many characters or fewer.
    MAX_SEARCH_PATH = 80

    # @param tool [String, nil] the tool's name
    # @param input [Object] the tool's input, as the hook payload has it
    # @return [String, nil] the summary, or nil when the tool has none
    def self.call(tool, input)
      return nil unless tool.is_a?(String) && input.is_a?(Hash)

      raw = case tool
      when "Bash" then first_line(input["command"])
      when *FILE_TOOLS then string(input["file_path"]) || string(input["notebook_path"])
      when *SEARCH_TOOLS then search(input)
      when "WebFetch" then string(input["url"])
      end
      cap(raw)
    end

    # @param text [String, nil] any text
    # @return [String, nil] +text+ with control characters blanked and cut to {MAX_BYTES}; nil when empty
    def self.cap(text)
      return nil unless text.is_a?(String)

      cleaned = redact(text.scrub.gsub(/[[:cntrl:]  ]+/, " ").strip)
      return nil if cleaned.empty?
      return cleaned if cleaned.bytesize <= MAX_BYTES

      room = MAX_BYTES - ELLIPSIS.bytesize
      cut = cleaned.byteslice(0, room).scrub("")
      "#{cut.rstrip}#{ELLIPSIS}"
    end

    # Blanks the values that most often carry a secret: `NAME=value` where the
    # name suggests one, `Bearer`/`Basic` tokens, and `user:pass@` in a URL.
    # A best effort, not a guarantee.
    def self.redact(text)
      text
        .gsub(/(\b\w*(?:token|secret|key|pass(?:word|wd)?|auth|credential)\w*=)\S+/i, "\\1[redacted]")
        .gsub(/\b(Bearer|Basic)\s+[^\s'"]+/i, "\\1 [redacted]")
        .gsub(%r{(://[^/\s:@]+:)[^/\s@]+@}, "\\1[redacted]@")
    end

    def self.first_line(command)
      return nil unless command.is_a?(String)
      command.scrub.lines.map(&:strip).find { |line| !line.empty? }
    end

    def self.string(value)
      value if value.is_a?(String) && !value.empty?
    end

    def self.search(input)
      pattern = string(input["pattern"])
      return nil unless pattern
      path = string(input["path"])
      (path && path.length <= MAX_SEARCH_PATH) ? "#{pattern} (in #{path})" : pattern
    end

    private_class_method :redact, :first_line, :string, :search
  end
end
