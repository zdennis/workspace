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
    WRAPPERS = %w[sudo command env exec nohup time builtin nice ionice timeout stdbuf doas caffeinate chroot arch watch xargs].freeze

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

    # @param piece [String] one piece as written
    # @return [String] the piece without its leading harmless wrappers (`timeout 5`, `nice -n 5`, `nohup`, `time`,
    #   `command`, `builtin`, `ionice`, `stdbuf`, `caffeinate`); assignments and other wrappers stay
    def unwrapped(piece)
      word, rest = leading(piece, only: HARMLESS_WRAPPERS)
      word ? "#{word} #{rest}".strip : piece.strip
    end

    # @param command [String] a Bash command
    # @return [Array<String>] each piece with its quotes removed and backslash escapes resolved, then stripped
    #   like {#pieces}, so `"rm" -rf /` and `r''m -rf /` show as `rm -rf /`
    def unquoted_pieces(command)
      split(command.scrub).flat_map { |piece| strip_prefix(unquote(piece)) }.map { |text| text[0, MAX_PIECE] }.reject(&:empty?).uniq
    end

    # Whether what a piece runs can't be told from its text: its command word (after wrappers and assignments)
    # holds a quote, backslash, `$`, `{` or glob character, is `eval`, `source` or `.`, is a shell given `-c`
    # (also in combined flags such as `-lc`), or is a compound keyword or brace such as `if`, `then`, `{` or `!`.
    # @param command [String] a Bash command
    # @return [Boolean]
    def opaque?(command)
      split(command.scrub).any? { |piece| opaque_piece?(piece) }
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
      escaped_at = -2
      continued = []
      index = 0
      while index < chars.size
        char = chars[index]
        if quote
          if char == "\\" && quote != "'"
            index += 1
          elsif char == quote.delete_prefix("$")
            quote = nil
          end
        elsif char == "\\" && chars[index + 1] == "\n"
          continued << index + 1
          index += 2
          next
        elsif char == "\\"
          escaped_at = index + 1
          index += 1
        elsif char == "$" && chars[index + 1] == "'"
          quote = "$'"
          index += 1
        elsif char == "'" || char == '"'
          quote = char
        elsif char == "#" && comment_start?(chars, index, escaped_at, continued)
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

    # Whether a `time` wrapper in a piece writes a file: `-o FILE`, `--output`, `-a` or `--append`, which the
    # wrapper skipping would otherwise hide.
    # @param command [String] a Bash command
    # @return [Boolean]
    def wrapper_writes?(command)
      split(command.scrub).any? { |piece| leading(piece)&.at(4) }
    end

    private

    KEYWORDS = %w(if then elif else fi do done while until for case esac function { } [[ !).freeze
    HARMLESS_WRAPPERS = %w[command builtin nohup time nice ionice timeout stdbuf caffeinate].freeze
    OPAQUE_PROGRAMS = %w[eval source . trap alias coproc awk gawk nawk mawk].freeze
    GIT_ALIAS_CONFIG = /(?:\A|\s)(?:-c|--config-env=?)\s*['"]?alias\./i
    SPLIT_STRING = /\A(-S|--split-string)/
    COMBINED_C = /\A-[a-zA-Z]*c[a-zA-Z]*\z/
    COMBINED_INLINE = /\A-[a-zA-Z]*[ecEC][a-zA-Z]*\z|\A--(eval|print|command)\z/
    SHELL_NAME = /\A(?:sh|bash|zsh|dash|ksh|fish)\z/
    INTERPRETER_NAME = /\A(?:perl|python[\d.]*|ruby|node|osascript|script|su)\z/
    INLINE_FLAGS = {SHELL_NAME => COMBINED_C, INTERPRETER_NAME => COMBINED_INLINE}.freeze
    OPAQUE_WORD = /['"\\${*?]/
    # `time` options that make it write a file (`-o FILE`, `--output`, `-a`/`--append`, alone or combined).
    TIME_WRITES = /\A(?:--(?:output|append)\b|-[a-zA-Z]*[oa])/

    def opaque_piece?(piece)
      word, rest, name, flagged = leading(piece)
      flagged || (!word.nil? && opaque_word?(word, name, rest))
    end

    def opaque_word?(word, name, rest)
      return true if word.match?(OPAQUE_WORD) || word.start_with?("-") || KEYWORDS.include?(word) || OPAQUE_PROGRAMS.include?(name)
      return true if name == "git" && rest.match?(GIT_ALIAS_CONFIG)
      options = rest.split(" ").select { |argument| argument.start_with?("-") }
      INLINE_FLAGS.any? { |pattern, flags| pattern.match?(name) && options.any? { |option| option.match?(flags) } }
    end

    # Quotes removed and backslash escapes resolved, as the shell would hand the words to the program.
    def unquote(text)
      chars = text.chars
      out = +""
      quote = nil
      index = 0
      while index < chars.size
        char = chars[index]
        if quote == "'"
          (char == "'") ? quote = nil : out << char
        elsif quote == "$'"
          if char == "\\"
            index += 1
            out << chars[index].to_s
          elsif char == "'"
            quote = nil
          else
            out << char
          end
        elsif quote == '"'
          if char == "\\" && ["$", "`", '"', "\\"].include?(chars[index + 1])
            index += 1
            out << chars[index]
          elsif char == '"'
            quote = nil
          else
            out << char
          end
        elsif char == "\\"
          index += 1
          out << chars[index].to_s
        elsif char == "$" && chars[index + 1] == "'"
          quote = "$'"
          index += 1
        elsif char == "'" || char == '"'
          quote = char
        else
          out << char
        end
        index += 1
      end
      out
    end

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

    # Whether a `#` at the index starts a comment: it follows an unescaped blank or newline, or the start,
    # looking back past line continuations.
    def comment_start?(chars, index, escaped_at, continued)
      before = index - 1
      before -= 2 while continued.include?(before)
      before < 0 || ([" ", "\t", "\n"].include?(chars[before]) && escaped_at != before)
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
      operator_at = -2
      blank_at = -2
      chars = command.chars
      index = 0
      while index < chars.size
        char = chars[index]
        if quote && char == "\\" && quote == '"' && chars[index + 1] == "\n"
          index += 2
          next
        elsif quote
          current << char
          if char == "\\" && quote != "'" && index + 1 < chars.size
            index += 1
            current << chars[index]
          elsif char == quote.delete_prefix("$")
            quote = nil
          end
        elsif char == "\\" && chars[index + 1] == "\n"
          blank_at = index + 1 if blank_at == index - 1
          index += 2
          next
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
        elsif char == "#" && (current.empty? || blank_at == index - 1)
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
        elsif char == "&" && (operator_at == index - 1 || (chars[index + 1] == ">" && chars[index - 1] != "&"))
          current << char
        elsif SEPARATORS.include?(char)
          arithmetic += 1 if char == "(" && arithmetic > 0
          arithmetic -= 1 if char == ")" && arithmetic > 0
          pieces << current
          current = +""
          index = skip_heredocs(chars, index, heredocs) if char == "\n" && heredocs.any?
        elsif char == " " || char == "\t"
          blank_at = index
          current << " " unless current.end_with?(" ")
        else
          operator_at = index if char == ">" || char == "<"
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

    # wrapper => the options it takes a value for and the flags it takes alone; any other option makes the piece opaque
    WRAPPER_OPTIONS = {
      "sudo" => {
        values: %w[-u -g -h -p -C -D -R -T -U --user --group --host --prompt --close-from --chdir --chroot --role --type
          --other-user --command-timeout],
        flags: %w[-A -b -B -E -e -H -i -K -k -l -n -P -S -s -V -v --askpass --background --preserve-env --login
          --non-interactive --stdin --shell --set-home --reset-timestamp --remove-timestamp --preserve-groups]
      },
      "env" => {values: %w[-u -C --unset --chdir], flags: %w[- -i -0 -v --ignore-environment --null --debug]},
      "command" => {values: [], flags: %w[-p -v -V]},
      "builtin" => {values: [], flags: []},
      "exec" => {values: %w[-a], flags: %w[-c -l]},
      "nohup" => {values: [], flags: []},
      "time" => {values: %w[-o -f --output --format], flags: %w[-p -v -a -l -h -q -V --portability --verbose --append --quiet]},
      "nice" => {values: %w[-n --adjustment], flags: []},
      "ionice" => {values: %w[-c -n -p -P -u --class --classdata --pid --pgid --uid], flags: %w[-t --ignore]},
      "timeout" => {values: %w[-s -k --signal --kill-after], flags: %w[-f -p -v --foreground --preserve-status --verbose]},
      "stdbuf" => {values: %w[-i -o -e --input --output --error], flags: []},
      "doas" => {values: %w[-u -C], flags: %w[-n -s -L]},
      "caffeinate" => {values: %w[-t -w], flags: %w[-d -i -m -s -u]},
      "chroot" => {values: %w[--userspec --groups], flags: %w[--skip-chdir]},
      "arch" => {values: %w[-e -d], flags: %w[-arm64 -arm64e -x86_64 -x86_64h -i386 -ppc -ppc64 -32 -64 -c -h]},
      "watch" => {
        values: %w[-n -q --interval --equexit],
        flags: %w[-b -c -d -e -g -p -t -x -w --beep --color --no-color --differences --errexit --chgexit --precise
          --no-title --exec --no-wrap]
      },
      "xargs" => {
        values: %w[-I -n -P -L -d -s -E -a --max-args --max-procs --max-lines --delimiter --max-chars --eof --arg-file],
        flags: %w[-0 -o -p -r -t -x -i -l --null --open-tty --interactive --no-run-if-empty --verbose --exit
          --show-limits]
      }
    }.freeze
    # wrapper => positional words to skip after its options
    WRAPPER_POSITIONALS = {"timeout" => 1, "chroot" => 1}.freeze
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
      word, rest, name = leading(piece)
      word ? commands(name, rest, word) : []
    end

    # Skips assignments, wrappers, their options and positional words (only the wrappers in `only` when given).
    # @return [Array, nil] the command word, the rest, the program name and whether a wrapper option hides a command
    #   (`env -S`); nil when nothing is left
    def leading(piece, only: nil)
      text = piece.strip
      wrapper = nil
      positionals = 0
      hidden = false
      writes = false
      until text.empty?
        word, rest = take(text)
        name = program_name(word)
        if only && (ASSIGNMENT.match?(word) || (WRAPPERS.include?(name) && !only.include?(name)))
          return [word, rest, name, hidden, writes]
        elsif ASSIGNMENT.match?(word)
          text = rest
        elsif WRAPPERS.include?(name)
          wrapper = name
          positionals = WRAPPER_POSITIONALS.fetch(name, 0)
          text = rest
        elsif wrapper && word.start_with?("-")
          hidden = true if wrapper == "env" && SPLIT_STRING.match?(word)
          text = rest
          kind = wrapper_option(wrapper, word)
          hidden = true if kind == :unknown
          writes = true if wrapper == "time" && TIME_WRITES.match?(word)
          text = take(rest).last if kind == :value
        elsif wrapper && positionals > 0
          positionals -= 1
          text = rest
        else
          return [word, rest, name, hidden, writes]
        end
      end
      hidden ? [nil, "", nil, true, writes] : nil
    end

    # @return [Symbol] `:value` when the option takes the next word, `:flag` when it stands alone (an attached
    #   value or `--opt=value` too), `:unknown` when the wrapper does not list it
    def wrapper_option(wrapper, word)
      options = WRAPPER_OPTIONS.fetch(wrapper)
      return :flag if word == "--"
      return :value if options[:values].include?(word)
      return :flag if options[:flags].include?(word)
      if word.start_with?("--")
        name = word.split("=", 2).first
        return (word.include?("=") && (options[:values] + options[:flags]).include?(name)) ? :flag : :unknown
      end
      return :flag if options[:values].include?(word[0, 2]) && word.length > 2
      return :flag if wrapper == "nice" && word.match?(/\A-\d+\z/)
      (word[1..].chars.all? { |char| options[:flags].include?("-#{char}") }) ? :flag : :unknown
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
