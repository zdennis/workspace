module Workspace
  # The status line a step's agent ends its turn with, and the tolerant reader of it. Pure: every method is a class
  # method over a String, reads no clock, store or process, and never raises.
  module WorkflowReportedStatus
    # The states an agent may report: the step is finished, still going, waiting on a person, or cannot go on.
    STATES = %w[done running needs_input stuck].freeze

    # The line the instructions ask for as the last line of the agent's final message. `<detail>` is optional.
    FORMAT = "WORKFLOW_STATUS: <state> — <detail>"

    # How many characters from the end of a message the reader looks in.
    TAIL_CHARS = 200

    LINE = /WORKFLOW_STATUS:[ \t]*([A-Za-z_]+)(.*)/mi
    SEPARATOR = /\A[ \t]*(?:—|--|\||-)?[ \t]*/
    private_constant :LINE, :SEPARATOR

    # Reads the status line from the tail of an agent's last message.
    #
    # State is matched without regard to case. The detail runs to the end of its line and on through following lines,
    # up to a blank line or a code fence; its lines are joined with one space.
    #
    # @param message [String, nil] the agent's last message
    # @return [Hash{Symbol=>String}, nil] `{state:, detail:}` (detail "" when absent), or nil when no line with a
    #   known state is found
    def self.parse(message)
      return nil unless message.is_a?(String)
      tail = message.scrub[-TAIL_CHARS..] || message.scrub
      match = tail.to_enum(:scan, LINE).map { Regexp.last_match }.last
      return nil unless match
      state = match[1].downcase
      return nil unless STATES.include?(state)
      {state: state, detail: detail_from(match[2])}
    rescue
      nil
    end

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
