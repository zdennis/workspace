module Workspace
  # The status line a step's agent ends its turn with, and the tolerant reader of it. Pure: every method is a class
  # method over a String, reads no clock, store or process, and never raises.
  module WorkflowReportedStatus
    # The states an agent may report: the step is finished, still going, waiting on a person, or cannot go on.
    STATES = %w[done running needs_input stuck].freeze

    # The line the instructions ask for as the last line of the agent's final message. `<detail>` is optional.
    FORMAT = "WORKFLOW_STATUS: <state> — <detail>"

    # The words every surface (status, attempts, trace) prints for a stored report, so text matches across them.
    #
    # @param report [Hash, nil] a stored `status_report` (`state`, `detail`)
    # @return [String, nil] `state` or `state: detail`; nil when there is no report with a state
    def self.words(report)
      return nil unless report.is_a?(Hash) && report["state"].is_a?(String) && !report["state"].empty?
      detail = report["detail"].to_s
      detail.empty? ? report["state"] : "#{report["state"]}: #{detail}"
    end

    # The keys of a stored report the read surfaces carry.
    REPORT_KEYS = %w[state detail at].freeze

    # @param report [Hash, nil] a stored `status_report`
    # @return [Hash, nil] the report cut to {REPORT_KEYS}; nil when there is none
    def self.shown(report)
      (report.is_a?(Hash) && report["state"].is_a?(String)) ? report.slice(*REPORT_KEYS) : nil
    end

    # How many characters from the end of a message the reader looks in; the window then reaches back to the start of
    # the line this cut lands in, so a long last line is read whole.
    TAIL_CHARS = 200

    # How far before the {TAIL_CHARS} cut the reader looks for the start of the line the cut lands in.
    MAX_LINE_BACK = 2000

    LINE = /^[ \t]*WORKFLOW_STATUS:[ \t]*([A-Za-z_]+)(.*)/mi
    TAG_START = /^[ \t]*WORKFLOW_STATUS:/i
    SEPARATOR = /\A[ \t]*(?:—|--|\||-)?[ \t]*/
    private_constant :LINE, :TAG_START, :SEPARATOR

    # Reads the status line from the tail of an agent's last message: the last {TAIL_CHARS} characters, widened back
    # to the start of the line the cut lands in, but by at most {MAX_LINE_BACK} characters.
    #
    # The line is the last in that window that starts its own line with the tag (leading whitespace allowed), so a
    # sentence mentioning the tag, or a word that merely contains it, is not read as a report. State is matched
    # without regard to case. The detail runs to the end of its line and on through following lines, up to a blank
    # line or a code fence; its lines are joined with one space.
    #
    # @param message [String, nil] the agent's last message
    # @return [Hash{Symbol=>String}, nil] `{state:, detail:}` (detail "" when absent), or nil when no line with a
    #   known state is found
    def self.parse(message)
      return nil unless message.is_a?(String)
      text = message.scrub
      start = last_tag_start(text, window_start(text))
      match = start && LINE.match(text, start)
      return nil unless match
      state = match[1].downcase
      return nil unless STATES.include?(state)
      {state: state, detail: detail_from(match[2])}
    rescue
      nil
    end

    # @param text [String] the whole message
    # @return [Integer] where the reader's window starts: the start of the line the {TAIL_CHARS} cut lands in, or
    #   {MAX_LINE_BACK} characters before the cut when that line starts further back. That start can fall mid-line;
    #   matching from it with `LINE.match(text, pos)` still needs a real line start for `^`.
    def self.window_start(text)
      cut = text.length - TAIL_CHARS
      return 0 if cut <= 0
      newline = text.rindex("\n", cut - 1)
      line_start = newline ? newline + 1 : 0
      [line_start, cut - MAX_LINE_BACK].max
    end
    private_class_method :window_start

    # @param text [String] the whole message
    # @param from [Integer] where the window starts
    # @return [Integer, nil] where the last line that starts with the tag at or after `from` begins, or nil
    def self.last_tag_start(text, from)
      last = nil
      while (tag = TAG_START.match(text, from))
        last = tag.begin(0)
        from = tag.end(0)
      end
      last
    end
    private_class_method :last_tag_start

    # @param rest [String] the text after the state word
    # @return [String] the detail, separator removed, wrapped lines joined
    def self.detail_from(rest)
      lines = []
      rest.sub(SEPARATOR, "").each_line.with_index do |line, i|
        text = line.strip
        break if text.start_with?("```")
        break if text.empty? && i.positive?
        lines << text unless text.empty?
      end
      lines.join(" ")
    end
    private_class_method :detail_from
  end
end
