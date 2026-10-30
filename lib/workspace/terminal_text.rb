# frozen_string_literal: true

module Workspace
  # Text made safe to print to a terminal: control, bidi and zero-width
  # characters are shown as escapes, so posted text can't move the cursor,
  # recolor the screen, reorder what is read or fake a line. The invisible
  # characters below are written as \u escapes so this source can be audited.
  class TerminalText
    # C0 and C1 controls, line and paragraph separators, bidi marks, embeddings,
    # overrides and isolates, and zero-width or invisible characters (including the soft hyphen and U+180E).
    UNSAFE = /[\u0000-\u001f\u007f-\u009f\u00ad\u180e\u200b-\u200f\u2028-\u202e\u061c\u2060-\u2069\ufeff]/
    private_constant :UNSAFE

    NAMED = {"\e" => "\\e", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t"}.freeze
    private_constant :NAMED

    # @param text [#to_s] nil prints as an empty string
    # @param keep_tabs [Boolean] leave tab characters as they are
    # @return [String] the text with each unsafe character as `\n`, `\e`, `\r`, `\t` or `\uXXXX`;
    #   invalid UTF-8 bytes become U+FFFD
    def self.escape(text, keep_tabs: false)
      text.to_s.scrub.gsub(UNSAFE) do |char|
        next char if keep_tabs && char == "\t"
        NAMED.fetch(char) { format("\\u%04X", char.ord) }
      end
    end
  end
end
