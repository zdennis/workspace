module Workspace
  # Cuts a Bash command into the pieces a policy matches, without running or
  # evaluating anything. Shared by {WorkflowDeny} and the agent permission policy.
  #
  # How a command is cut:
  # - At `;`, `&&`, `||`, `|`, `&`, newlines, parentheses and backticks that are
  #   not inside quotes, so `cd x && git push` is two pieces. A quoted `;` stays
  #   inside its piece. Parentheses and backticks also cut, so the inside of
  #   `$(...)` is a piece.
  # - Runs of blanks outside quotes count as one space, comments and
  #   here-document bodies are skipped.
  #
  # {#pieces} then strips each piece of leading `NAME=value` assignments, the
  # wrappers `sudo`, `command`, `env`, `exec`, `nohup`, `time` (and the
  # `-option` words right after them, with the value of `sudo -u`), a path
  # before the program (`/usr/bin/git`), and git's and gh's global options
  # (`git -C dir`, `gh -R repo`).
  class BashCommandPieces
    # Wrapper words skipped before the command proper.
    WRAPPERS = %w[sudo command env exec nohup time].freeze

    # The longest piece that {#pieces} returns, so a huge command can't take long.
    MAX_PIECE = 4096

    ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/

    # @param command [String] a Bash command
    # @return [Array<String>] the pieces of the command, each without its leading assignments and wrappers
    #   (a program given with a path is listed with and without the path)
    def pieces(command)
      split(command.scrub).flat_map { |piece| strip_prefix(piece) }.map { |text| text[0, MAX_PIECE] }.reject(&:empty?)
    end

    # @param command [String] a Bash command
    # @return [Array<String>] the pieces of the command as written, trimmed, with no wrapper or assignment stripping
    def raw_pieces(command)
      split(command.scrub).map(&:strip).reject(&:empty?)
    end

    # @param command [String] a Bash command
    # @return [Boolean] whether it holds `$(`, `${`, `$'`, a backtick, `<(` or `>(` anywhere, quotes included
    def substitution?(command)
      command.scrub.match?(/\$[({']|`|<\(|>\(/)
    end

    # @param command [String] a Bash command
    # @return [Boolean] whether an unquoted redirection reads or writes a file (a here-document or here-string too);
    #   false for fd duplication (`2>&1`, `>&2`, `<&0`, `N>&-`) and for a target of exactly `/dev/null`
    def redirect?(command)
      chars = command.scrub.chars
      quote = nil
      index = 0
      while index < chars.size
        char = chars[index]
        if quote
          if char == "\\" && quote != "'"
            index += 1
          elsif char == quote.delete_prefix("$")
            quote = nil
          end
        elsif char == "\\"
          index += 1
        elsif char == "$" && chars[index + 1] == "'"
          quote = "$'"
          index += 1
        elsif char == "'" || char == '"'
          quote = char
        elsif char == "#" && (index.zero? || [" ", "\t", "\n"].include?(chars[index - 1]))
          index += 1 until index >= chars.size || chars[index] == "\n"
          next
        elsif char == ">" || char == "<"
          result, index = redirection_at(chars, index)
          return true if result
          next
        end
        index += 1
      end
      false
    end

    private

    REDIRECT_END = [" ", "\t", "\n", ";", "&", "|", "<", ">", "(", ")", "`"].freeze

    # @return [Array] whether the operator at the index writes or reads a file, and the index after it and its target
    def redirection_at(chars, index)
      char = chars[index]
      following = chars[index + 1]
      return [false, index + 2] if following == "("
      return [true, index + 2] if char == "<" && following == "<"
      position = index + 1
      if following == "&"
        word, position = redirect_word(chars, position + 1)
        return [!word.match?(/\A(\d+-?|-)\z/), position]
      end
      position += 1 if following == "|" || (char == ">" && following == ">") || (char == "<" && following == ">")
      word, position = redirect_word(chars, position)
      [word != File::NULL, position]
    end

    def redirect_word(chars, position)
      position += 1 while [" ", "\t"].include?(chars[position])
      word = +""
      if ["'", '"'].include?(chars[position])
        mark = chars[position]
        position += 1
        while position < chars.size && chars[position] != mark
          word << chars[position]
          position += 1
        end
        position += 1
      else
        while position < chars.size && !REDIRECT_END.include?(chars[position])
          word << chars[position]
          position += 1
        end
      end
      [word, position]
    end

    SEPARATORS = [";", "&", "|", "\n", "(", ")", "`"].freeze
    DELIMITER_END = [" ", "\t", ";", "&", "|", "<", ">", "(", ")", "`", "\n"].freeze

    # Cuts at unquoted separators, folds runs of blanks outside quotes to one
    # space, and leaves out here-document bodies (everything after the line
    # holding `<<WORD`, `<<-WORD` or `<<'WORD'` up to a line that is WORD, or
    # to the end of the text when WORD never comes).
    def split(command)
      pieces = []
      current = +""
      quote = nil
      heredocs = []
      arithmetic = 0
      chars = command.chars
      index = 0
      while index < chars.size
        char = chars[index]
        if quote
          current << char
          if char == "\\" && quote != "'" && index + 1 < chars.size
            index += 1
            current << chars[index]
          elsif char == quote.delete_prefix("$")
            quote = nil
          end
        elsif char == "\\" && index + 1 < chars.size
          current << char << chars[index + 1]
          index += 1
        elsif char == "$" && chars[index + 1] == "'"
          quote = "$'"
          current << "$'"
          index += 2
          next
        elsif char == "'" || char == '"'
          quote = char
          current << char
        elsif char == "#" && (current.empty? || current.end_with?(" "))
          index += 1 until index >= chars.size || chars[index] == "\n"
          next
        elsif char == "$" && chars[index + 1] == "(" && chars[index + 2] == "("
          current << "$(("
          arithmetic = 2
          index += 3
          next
        elsif char == "<" && chars[index + 1] == "<" && arithmetic.zero?
          raw, delimiter, index = heredoc_at(chars, index)
          current << raw
          heredocs << delimiter if delimiter
          next
        elsif SEPARATORS.include?(char)
          arithmetic += 1 if char == "(" && arithmetic > 0
          arithmetic -= 1 if char == ")" && arithmetic > 0
          pieces << current
          current = +""
          index = skip_heredocs(chars, index, heredocs) if char == "\n" && heredocs.any?
        elsif char == " " || char == "\t"
          current << " " unless current.end_with?(" ")
        else
          current << char
        end
        index += 1
      end
      pieces << current
    end

    # A `<<<` here-string has no delimiter word (a word can't start with `<`), so it starts no skip.
    # @return [Array] the raw text read, the delimiter and whether it is `<<-` (nil when there is none) and the next index
    def heredoc_at(chars, index)
      position = index + 2
      dash = chars[position] == "-"
      position += 1 if dash
      position += 1 while [" ", "\t"].include?(chars[position])
      delimiter = +""
      if ["'", '"'].include?(chars[position])
        mark = chars[position]
        position += 1
        while position < chars.size && chars[position] != mark
          delimiter << chars[position]
          position += 1
        end
        position += 1
      else
        while position < chars.size && !DELIMITER_END.include?(chars[position])
          delimiter << chars[position]
          position += 1
        end
      end
      [chars[index...position].join, delimiter.empty? ? nil : [delimiter, dash], position]
    end

    # Moves past the bodies of the pending here-documents; returns the index of the last newline read.
    def skip_heredocs(chars, newline_index, heredocs)
      index = newline_index
      heredocs.shift(heredocs.size).each do |delimiter, dash|
        while index < chars.size
          stop = ((index + 1)...chars.size).find { |at| chars[at] == "\n" } || chars.size
          line = chars[(index + 1)...stop].join
          index = stop
          break if (dash ? line.sub(/\A\t+/, "") : line) == delimiter
        end
      end
      index
    end

    # option => takes a value, for the wrappers whose options matter
    WRAPPER_VALUE_OPTIONS = {
      "sudo" => %w[-u -g -h -p -C -D -R -T -U],
      "env" => %w[-u -C -S]
    }.freeze
    GIT_VALUE_OPTIONS = %w[-C -c --git-dir --work-tree --namespace --super-prefix --config-env --exec-path].freeze
    GH_VALUE_OPTIONS = %w[-R --repo].freeze

    WORD = /\A((?:'[^']*'|"(?:\\.|[^"\\])*"|\\.|[^\s'"\\])+)\s*(.*)\z/m
    private_constant :WORD

    # The first word of the text, a quoted part kept whole, and the rest.
    def take(text)
      match = WORD.match(text)
      return [match[1], match[2]] if match
      word, rest = text.split(" ", 2)
      [word, rest || ""]
    end

    # @return [Array<String>] the piece as it is matched: the program without its path and, when it had one, as written
    def strip_prefix(piece)
      text = piece.strip
      wrapper = nil
      until text.empty?
        word, rest = take(text)
        name = program_name(word)
        if ASSIGNMENT.match?(word)
          text = rest
        elsif WRAPPERS.include?(name)
          wrapper = name
          text = rest
        elsif wrapper && word.start_with?("-")
          text = rest
          text = take(rest).last if WRAPPER_VALUE_OPTIONS.fetch(wrapper, []).include?(word)
        else
          return commands(name, rest, word)
        end
      end
      []
    end

    def program_name(word)
      word.include?("/") ? File.basename(word) : word
    end

    # `git -C x push` is `git push`, `gh -R o/r pr comment` is `gh pr comment`.
    def commands(name, rest, word)
      value_options = {"git" => GIT_VALUE_OPTIONS, "gh" => GH_VALUE_OPTIONS}[name]
      text = rest
      while value_options && text.start_with?("-")
        option, text = take(text)
        text = take(text).last if value_options.include?(option)
      end
      [name, word].uniq.map { |program| "#{program} #{text}".strip }
    end
  end
end
