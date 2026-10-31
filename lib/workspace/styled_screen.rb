# frozen_string_literal: true

module Workspace
  # A pane's screen read from `tmux capture-pane -e -p`, which keeps the
  # styling: for each character it knows whether the text was drawn faint
  # (SGR 2), as a suggestion is. Only SGR 2 counts; a grey foreground is
  # an ordinary colour and does not.
  #
  # A line is "proven" when every escape on it was understood. A link
  # (OSC 8) is dropped and has no effect on that. A shift character
  # (\016, \017), any other escape, or a cell drawn in reverse video
  # without faint (where a cursor may sit) leaves only its own line
  # unproven, so odd output elsewhere on screen does not hide a
  # suggestion; callers keep today's refusal for an unproven line.
  class StyledScreen
    COLOR_INTRODUCERS = %w[38 48 58].freeze
    OSC_8 = /\A\e\]8;[^\a\e]*(?:\a|\e\\)/
    OSC_ANY = /\A\e\][^\a\e]*(?:\a|\e\\)?/
    CSI = /\A\e\[([0-?]*)([ -\/]*)([@-~])/
    SHIFT_CHARACTERS = "\u000e\u000f"

    # Parses raw `capture-pane -e -p` output.
    #
    # @param raw [String, nil] the captured screen
    # @return [StyledScreen, nil] nil when +raw+ is nil
    def self.parse(raw)
      return nil if raw.nil?

      new(raw)
    end

    # @return [String] the plain screen: the same text `capture-pane -p`
    #   gives, with trailing spaces cut from every line
    attr_reader :text

    # @param raw [String] captured screen with escape sequences
    def initialize(raw)
      @faint = []
      @proven = []
      @text = +""
      state = {faint: false, reverse: false}
      raw.scrub.split("\n", -1).each_with_index do |line, index|
        cells, proven = read_line(line, state)
        @faint << cells.map(&:first)
        @proven << proven
        @text << cells.map(&:last).join.rstrip
        @text << "\n" if index < raw.count("\n")
      end
    end

    # Whether the character at a position was drawn faint.
    #
    # @param line [Integer] zero-based line of the screen
    # @param column [Integer] zero-based character position on that line
    # @return [Boolean] false for a position that is not on the screen
    def faint?(line, column)
      cells = @faint[line]
      return false if cells.nil? || column.negative?

      cells[column] == true
    end

    # Whether every escape on a line was understood, so its styling can be
    # trusted.
    #
    # @param line [Integer] zero-based line of the screen
    # @return [Boolean] false for a line that is not on the screen
    def proven?(line)
      @proven[line] == true
    end

    # @return [Integer] the number of lines
    def size
      @faint.size
    end

    private

    def read_line(line, state)
      cells = []
      proven = true
      rest = line
      until rest.empty?
        if rest.start_with?("\e")
          if (match = rest.match(OSC_8))
            rest = match.post_match
          elsif (match = rest.match(CSI))
            if match[3] == "m" && match[1].match?(/\A[0-9;:]*\z/) && match[2].empty?
              proven = false unless apply_sgr(match[1], state)
            else
              proven = false
            end
            rest = match.post_match
          elsif (match = rest.match(OSC_ANY))
            proven = false
            rest = match.post_match
          else
            proven = false
            rest = rest[2..].to_s
          end
        else
          char = rest[0]
          rest = rest[1..]
          if SHIFT_CHARACTERS.include?(char)
            proven = false
          else
            proven = false if state[:reverse] && !state[:faint]
            cells << [state[:faint], char]
          end
        end
      end
      [cells, proven]
    end

    def apply_sgr(params, state)
      groups = params.split(";", -1)
      groups = [""] if groups.empty?
      index = 0
      while index < groups.size
        parts = groups[index].split(":", -1)
        first = parts.first.to_s
        if COLOR_INTRODUCERS.include?(first)
          extra = color_arguments(groups, index, parts)
          return false if extra.nil?

          index += extra
        elsif parts.size > 1
          return false unless first == "4"
        else
          apply_parameter(first, state)
        end
        index += 1
      end
      true
    end

    # @return [Integer, nil] how many groups the colour takes after its own,
    #   nil when it is malformed
    def color_arguments(groups, index, parts)
      return 0 if parts.size > 1

      case groups[index + 1]
      when "5" then (groups.size > index + 2) ? 2 : nil
      when "2" then (groups.size > index + 4) ? 4 : nil
      end
    end

    def apply_parameter(part, state)
      return reset(state) if part.empty?
      return unless part.match?(/\A[0-9]+\z/)

      case Integer(part, 10)
      when 0 then reset(state)
      when 2 then state[:faint] = true
      when 22 then state[:faint] = false
      when 7 then state[:reverse] = true
      when 27 then state[:reverse] = false
      end
    end

    def reset(state)
      state[:faint] = false
      state[:reverse] = false
    end
  end
end
