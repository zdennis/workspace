module Workspace
  # The strict rule for whether an iTerm2 window is a leftover tmux -CC gateway window: its screen
  # holds the launch command typed at a shell prompt, iTerm's tmux Command Menu, `Detached`, and then
  # that same prompt again with nothing typed after it, and only login shells run on its tty. Any
  # doubt answers false.
  module GatewayWindowMatch
    MENU_HEADING = "Command Menu"
    MENU_LINES = [/\Aesc\s+Detach cleanly/, /\AX\s+Force-quit tmux mode/, /\AL\s+Toggle logging/, /\AC\s+Run tmux command/].freeze
    LOGIN_SHELLS = %w[zsh bash fish sh login].freeze

    # @param contents [String, nil] the window's screen text
    # @param launch_commands [Array<String>, nil] command lines the window may have been launched with;
    #   one counts only where it is followed by whitespace or the end of a line
    # @param tty_commands [Array<String>, nil] command names running on the window's tty
    # @return [Boolean]
    def self.match?(contents:, launch_commands:, tty_commands:)
      return false unless login_shells_only?(tty_commands)

      commands = Array(launch_commands).map(&:to_s).reject(&:empty?)
      return false if contents.nil? || contents.empty? || commands.empty?

      lines = contents.lines.map(&:chomp)
      menu = menu_span(lines)
      return false unless menu

      prompt = launch_prompt(lines[0...menu.first], commands)
      return false if prompt.nil? || prompt.strip.empty?

      detached_then_prompt?(lines[(menu.last + 1)..], prompt)
    end

    def self.login_shells_only?(tty_commands)
      return false unless tty_commands.is_a?(Array) && !tty_commands.empty?

      tty_commands.all? { |name| LOGIN_SHELLS.include?(name.to_s.strip.sub(/\A-/, "").split("/").last.to_s) }
    end

    # The heading's line index and the last key line's index of the last complete menu, or nil. The
    # four key lines follow the heading in order, with nothing but a rule or blank lines between.
    def self.menu_span(lines)
      best = nil
      lines.each_index do |start|
        next unless lines[start].strip == MENU_HEADING

        body = ((start + 1)...lines.size).reject { |i| lines[i].strip.empty? || lines[i].strip.match?(/\A-+\z/) }
        keys = body.first(MENU_LINES.size)
        next unless keys.size == MENU_LINES.size
        next unless keys.each_with_index.all? { |i, n| lines[i].strip.match?(MENU_LINES[n]) }
        next unless keys.each_cons(2).all? { |a, b| ((a + 1)...b).all? { |i| lines[i].strip.empty? } }

        best = [start, keys.last]
      end
      best
    end

    # The text on the line before the last launch command, which is the shell prompt it was typed at.
    # The lines are joined so a command iTerm wrapped across lines still counts.
    def self.launch_prompt(lines, commands)
      joined = +""
      ends = []
      lines.each do |line|
        joined << line
        ends << joined.size
      end

      found = []
      commands.each do |command|
        offset = 0
        while (at = joined.index(command, offset))
          after = at + command.size
          found << at if after == joined.size || ends.include?(after) || joined[after].match?(/\s/)
          offset = at + 1
        end
      end

      # A chained launch line holds more than one command; its prompt is what comes before the first.
      found.sort.reverse_each do |at|
        line_start = ends.reverse.find { |e| e <= at } || 0
        prefix = joined[line_start...at]
        return prefix unless prefix.strip.empty? || commands.any? { |command| prefix.include?(command) }
      end
      nil
    end

    # After the menu: a line that reads `Detached`, then only blank lines and one line that is the
    # launch prompt again with nothing after it.
    def self.detached_then_prompt?(after, prompt)
      at = after.index { |line| line.strip == "Detached" }
      return false unless at

      rest = after[(at + 1)..].reject { |line| line.strip.empty? }
      rest.size == 1 && rest.first.rstrip == prompt.rstrip
    end

    private_class_method :login_shells_only?, :menu_span, :launch_prompt, :detached_then_prompt?
  end
end
