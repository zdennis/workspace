module Workspace
  # Builds the document behind `workspace tmux show --json`: a workspace's
  # tmuxinator file as session fields, windows and panes, with what each
  # pane's command looks like and what tmux is running now.
  #
  # Read-only. A file that can't be parsed is reported as data (message, line,
  # column), not raised.
  class TmuxinatorReport
    # Schema version of the document.
    JSON_SCHEMA_VERSION = 1

    # @param config [Workspace::Config] where the tmuxinator file lives
    # @param tmux [Workspace::Tmux] answers which sessions and panes are running
    def initialize(config:, tmux:)
      @config = config
      @tmux = tmux
    end

    # @param workspace [String] workspace name
    # @return [Hash] the `tmux show --json` document
    # @raise [Workspace::Error] code `unknown_workspace` when the workspace has no tmuxinator file
    def show(workspace)
      path = @config.config_path_for(workspace)
      unless File.exist?(path)
        raise Workspace::Error.new("No tmuxinator config for '#{workspace}': #{path}", code: "unknown_workspace", details: {"name" => workspace})
      end

      file = ConfigFile.read("tmuxinator", path)
      doc = {
        "schema_version" => JSON_SCHEMA_VERSION,
        "ok" => true,
        "workspace" => workspace,
        "file" => path,
        "etag" => file.etag,
        "erb" => File.read(path).include?("<%"),
        "parse_error" => file.parse_error
      }
      return doc.merge("session" => nil, "windows" => [], "running" => nil, "applies" => "relaunch") unless file.readable?

      session_name = file.data["name"] || workspace
      running = running?(session_name)
      live = running ? live_panes(session_name) : []
      doc.merge(
        "session" => session(file.data),
        "windows" => windows(file.data["windows"], pane_lines(File.read(path)), live),
        "running" => running,
        "applies" => "relaunch"
      )
    end

    private

    def session(data)
      {
        "name" => data["name"],
        "root" => data["root"],
        "startup_pane" => data["startup_pane"],
        "tmux_options" => data["tmux_options"],
        "attach" => data["attach"],
        "on_project_start" => data["on_project_start"]
      }
    end

    def running?(session_name)
      @tmux.sessions.include?(session_name)
    rescue Workspace::Error
      nil
    end

    # Live panes grouped by window, in window order, so the nth window in the
    # file pairs with the nth window in tmux whatever tmux's base-index is.
    def live_panes(session_name)
      @tmux.pane_start_commands(session_name).group_by { |pane| pane[:window] }.sort.map { |_, panes| panes.sort_by { |pane| pane[:index] } }
    end

    def windows(entries, lines, live)
      Array(entries).each_with_index.map do |entry, index|
        name, config = entry.is_a?(Hash) ? entry.first : [entry, nil]
        panes = panes_of(config).each_with_index.map do |pane, pane_index|
          pane_row(pane, pane_index, lines.dig(index, pane_index), live.dig(index, pane_index))
        end
        {"index" => index, "name" => name, "layout" => layout_of(config), "panes" => panes}
      end
    end

    # A window's value is a mapping with `panes`, or the command (a string) or commands (a list) of its one pane.
    def panes_of(config)
      case config
      when Hash then Array(config["panes"])
      when nil then []
      else [config]
      end
    end

    def layout_of(config) = config.is_a?(Hash) ? config["layout"] : nil

    def pane_row(pane, index, line, live)
      title, command = command_of(pane)
      kind = kind_of(command)
      row = {"index" => index, "title" => title, "command" => command, "kind" => kind, "line" => line}
      row["flags"] = flags_of(command) if kind == "claude"
      row["live"] = live ? {"pane_id" => live[:id], "start_command" => live[:start_command]} : nil
      row
    end

    # A pane is a command string, nil (a bare shell), a list of commands, or
    # a one-pair hash of title to command.
    def command_of(pane)
      title = nil
      if pane.is_a?(Hash)
        title, pane = pane.first
      end
      command = pane.is_a?(Array) ? pane.join("\n") : pane
      [title, command&.to_s&.chomp]
    end

    def kind_of(command)
      return "shell" if command.nil? || command.strip.empty?
      return "claude" if command.match?(CLAUDE_INVOCATION)
      return "agentd" if command.match?(/\bagentd\b/)
      return "banner" if command.match?(/ascii-banner|figlet/)
      "command"
    end

    # `claude` as a command word: at the start or after whitespace or a shell
    # separator, so a project named `claude-tools` in a banner doesn't match.
    CLAUDE_INVOCATION = /(?:\A|[\s;&|(])claude(?:\s|\z)/
    private_constant :CLAUDE_INVOCATION

    def flags_of(command)
      segment = command[/#{CLAUDE_INVOCATION.source}([^|;&]*)/, 1].to_s
      segment.split.select { |word| word.start_with?("--") }
    end

    # 1-based line of each pane's node, by window then pane.
    def pane_lines(text)
      root = Psych.parse(text)&.root
      windows = value_of(root, "windows")
      return [] unless windows.is_a?(Psych::Nodes::Sequence)

      windows.children.map do |window|
        config = window.is_a?(Psych::Nodes::Mapping) ? window.children[1] : nil
        panes = value_of(config, "panes")
        if panes.is_a?(Psych::Nodes::Sequence)
          panes.children.map { |node| node.start_line + 1 }
        elsif config && !config.is_a?(Psych::Nodes::Mapping)
          [config.start_line + 1]
        else
          []
        end
      end
    end

    def value_of(mapping, key)
      return nil unless mapping.is_a?(Psych::Nodes::Mapping)
      mapping.children.each_slice(2).find { |k, _| k.is_a?(Psych::Nodes::Scalar) && k.value == key }&.last
    end
  end
end
