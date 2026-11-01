require "json"

module Workspace
  # Denies a Bash command that matches a pattern in the `deny:` list of the
  # workflow definition the calling pane's run keeps, from the PreToolUse
  # `session-event` hook beside {LockEnforcer}.
  #
  # A tripwire for an agent that was misled or made a mistake, not a sandbox:
  # `bash -c '...'`, a script, an alias or a variable holding the command
  # get past it (see docs/README.workflow.md for the list).
  #
  # How a command is matched:
  # - It is cut into pieces at `;`, `&&`, `||`, `|`, `&`, newlines, parentheses and backticks that are
  #   not inside quotes, so `cd x && git push` is checked as `git push`. A
  #   quoted `;` stays inside its piece, so `git commit -m "a; git push"`
  #   is one piece and is not denied. Parentheses and backticks also cut, so
  #   the inside of `$(...)` is checked.
  # - Runs of blanks outside quotes count as one space, and here-document bodies are skipped.
  # - Each piece loses leading whitespace, leading `NAME=value` assignments and
  #   the wrappers `sudo`, `command`, `env`, `exec`, `nohup`, `time` (and the
  #   `-option` words right after them, with the value of `sudo -u`),
  #   a path before the program (`/usr/bin/git`), and git's and gh's global
  #   options (`git -C dir`, `gh -R repo`).
  # - What is left must match a pattern whole, as a shell glob where `*` and
  #   `?` match any character (`File.fnmatch`, so no text is evaluated).
  #
  # Nearly free for the common case: a pane with no run binding costs one read
  # of the bindings file. It never raises; an unreadable binding or run file
  # allows the tool call, because blocking every tool on a read error would
  # stop the agent for a fault the person can't see.
  class WorkflowDeny
    TOOL = "Bash"

    # Wrapper words skipped before the command proper.
    WRAPPERS = %w[sudo command env exec nohup time].freeze

    # The longest piece that is matched, so a huge command can't take long.
    MAX_PIECE = 4096

    # The longest command text kept in an event.
    MAX_RECORDED = 300

    FNMATCH_FLAGS = File::FNM_DOTMATCH

    ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/

    FINISHED = %w[completed failed cancelled].freeze
    private_constant :FINISHED

    # @param bound_run [Workspace::BoundRun] names the run the calling pane is bound to
    # @param run_store [Workspace::WorkflowRunStore] reads the run and writes its history
    # @param event_log [Workspace::EventLog, nil] gets `command_denied`
    # @param logger [Workspace::Logger] debug logger
    def initialize(bound_run:, run_store:, event_log: nil, logger: Workspace::Logger.new)
      @bound_run = bound_run
      @run_store = run_store
      @event_log = event_log
      @logger = logger
    end

    # @param tool_name [String, nil] the PreToolUse payload's tool_name
    # @param tool_input [Object] the payload's tool_input
    # @return [String, nil] a deny message for stderr, or nil to allow the tool call
    def check(tool_name:, tool_input:)
      return nil unless tool_name == TOOL && tool_input.is_a?(Hash)
      command = tool_input["command"]
      return nil unless command.is_a?(String) && !command.empty?

      run_id = @bound_run.run_id
      return nil unless run_id
      run = @run_store.find(run_id)
      return nil if FINISHED.include?(run["state"])
      patterns = WorkflowDefinition.deny(run["definition"])
      return nil if patterns.empty?

      pattern = first_match(command, patterns)
      return nil unless pattern

      record(run, command, pattern)
      message(run, pattern)
    rescue => e
      @logger.debug { "session-event: deny check failed (#{e.class}: #{e.message})" }
      nil
    end

    # @param command [String] a Bash command
    # @param patterns [Array<String>] shell globs
    # @return [String, nil] the first pattern a piece of the command matches
    def first_match(command, patterns)
      pieces(command).each do |piece|
        patterns.each { |pattern| return pattern if File.fnmatch(pattern, piece, FNMATCH_FLAGS) }
      end
      nil
    end

    # @param command [String]
    # @return [Array<String>] the pieces of the command, each without its leading assignments and wrappers
    #   (a program given with a path is listed with and without the path)
    def pieces(command)
      split(command.scrub).flat_map { |piece| strip_prefix(piece) }.map { |text| text[0, MAX_PIECE] }.reject(&:empty?)
    end

    private

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
          if char == "\\" && quote == '"' && index + 1 < chars.size
            index += 1
            current << chars[index]
          elsif char == quote
            quote = nil
          end
        elsif char == "\\" && index + 1 < chars.size
          current << char << chars[index + 1]
          index += 1
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

    def record(run, command, pattern)
      shown = TerminalText.escape(command[0, MAX_RECORDED])
      data = {"step" => run["current"], "pattern" => pattern, "command" => shown}
      @run_store.record_event(run["id"], "command_denied", data)
      @event_log&.record(type: "command_denied", project: run["workspace"],
        data: data.merge("run_id" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"]))
    end

    def step_clause(run)
      run["current"].is_a?(String) ? ", step #{TerminalText.escape(run["current"])}" : ""
    end

    def message(run, pattern)
      "denied by workflow #{TerminalText.escape(run["workflow"])}#{step_clause(run)}: " \
        "#{TerminalText.escape(pattern).inspect}. Report this and stop."
    end
  end
end
