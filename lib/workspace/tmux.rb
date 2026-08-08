require "open3"

module Workspace
  # Manages tmux session operations for the workspace CLI.
  class Tmux
    # @param config [Workspace::Config] configuration for path lookups
    # @param logger [Workspace::Logger] debug logger
    def initialize(config:, logger: Workspace::Logger.new)
      @config = config
      @logger = logger
    end

    # @return [Array<String>] list of active tmux session names
    def sessions
      @logger.debug { "tmux: listing sessions" }
      stdout, _, status = Open3.capture3("tmux", "list-sessions", "-F", "\#{session_name}")
      result = status.success? ? stdout.strip.lines.map(&:strip) : []
      @logger.debug { "tmux: found #{result.size} session(s): #{result.join(", ")}" }
      result
    end

    # @return [void]
    def start_server
      @logger.debug { "tmux: starting server" }
      system("tmux", "start-server")
    end

    # @param name [String] tmux session name
    # @return [void]
    def kill_session(name)
      @logger.debug { "tmux: killing session #{name}" }
      system("tmux", "kill-session", "-t", name)
    end

    # @param session_name [String] tmux session name
    # @param window_index [String, Integer] window index
    # @param new_name [String] new window name
    # @return [void]
    def rename_window(session_name, window_index, new_name)
      @logger.debug { "tmux: renaming window #{session_name}:#{window_index} to #{new_name}" }
      system("tmux", "rename-window", "-t", "#{session_name}:#{window_index}", new_name)
    end

    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1" for window 0, pane 1)
    # @param text [String] text to send (sent in literal mode to avoid key-name interpretation)
    # @param enter [Boolean] whether to press Enter after sending
    # @return [Boolean] true if send succeeded
    def send_keys(session_name, pane, text, enter: true)
      target = "#{session_name}:#{pane}"
      @logger.debug { "tmux: send-keys to #{target}" }
      return false unless system("tmux", "send-keys", "-l", "-t", target, text)
      return false if enter && !system("tmux", "send-keys", "-t", target, "Enter")
      true
    end

    # Sends a single key name to a tmux pane (non-literal mode).
    # Used for special keys like "C-c", "Enter", "Escape".
    #
    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1")
    # @param key_name [String] tmux key name (e.g. "C-c", "Enter")
    # @return [Boolean] true if send succeeded
    def send_key(session_name, pane, key_name)
      target = "#{session_name}:#{pane}"
      @logger.debug { "tmux: send-key #{key_name} to #{target}" }
      system("tmux", "send-keys", "-t", target, key_name)
    end

    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1")
    # @param size [String] size value (e.g. "10" for rows, "50%" for percentage)
    # @return [Boolean] true if resize succeeded
    def resize_pane(session_name, pane, size)
      target = "#{session_name}:#{pane}"
      system("tmux", "resize-pane", "-t", target, "-y", size)
    end

    # Lists pane indices for a given session window.
    #
    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @return [Array<Integer>] sorted pane indices, empty array on failure
    def panes(session_name, window: "0")
      target = "#{session_name}:#{window}"
      @logger.debug { "tmux: listing panes for #{target}" }
      stdout, _, status = Open3.capture3("tmux", "list-panes", "-t", target, "-F", "\#{pane_index}")
      return [] unless status.success?
      stdout.strip.lines.map { |l| l.strip.to_i }.sort
    end

    # Splits a pane in the given window.
    #
    # Uses `-P -F '#{pane_index}'` so the new pane's index is reported by tmux itself.
    # Callers must not re-query {#panes} and assume the last entry is the new pane —
    # that is racy and can be defeated by tmux pane index reuse.
    #
    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @param pane [Integer, nil] pane index to split; nil targets the window (tmux picks active pane)
    # @param vertical [Boolean] true = side-by-side (-h), false = top/bottom (-v, default)
    # @return [Integer, nil] index of the newly created pane, or nil if the split failed
    def split_window(session_name, window: "0", pane: nil, vertical: false)
      target = pane ? "#{session_name}:#{window}.#{pane}" : "#{session_name}:#{window}"
      @logger.debug { "tmux: split-window #{vertical ? "-h" : "-v"} -t #{target}" }
      stdout, _, status = Open3.capture3(
        "tmux", "split-window", (vertical ? "-h" : "-v"), "-t", target,
        "-P", "-F", "\#{pane_index}"
      )
      return nil unless status.success?
      new_index = stdout.strip
      return nil if new_index.empty?
      new_index.to_i
    end

    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @return [String, nil] the layout string, or nil if capture fails
    def capture_layout(session_name, window: "0")
      target = "#{session_name}:#{window}"
      stdout, _, status = Open3.capture3("tmux", "list-windows", "-t", target, "-F", "\#{window_layout}")
      status.success? ? stdout.strip : nil
    end

    # Captures the scrollback buffer of a tmux pane and returns it as a string.
    #
    # @param session_name [String] tmux session name
    # @param pane [Integer] zero-based pane index within window 0
    # @param lines [Integer] number of lines from the bottom to capture (default 100)
    # @param all [Boolean] capture the full history up to history-limit (overrides lines:)
    # @return [String, nil] the captured text, or nil if tmux reported failure
    def capture_pane(session_name, pane, lines: 100, all: false)
      target = "#{session_name}:0.#{pane}"
      @logger.debug { "tmux: capture-pane -t #{target} (all=#{all}, lines=#{lines})" }
      args = ["tmux", "capture-pane", "-t", target, "-p"]
      args += all ? ["-S", "-"] : ["-S", "-#{lines}"]
      stdout, _, status = Open3.capture3(*args)
      status.success? ? stdout : nil
    end

    # @param session_name [String] tmux session name
    # @param layout [String] tmux layout string
    # @param window [String] window index (default "0")
    # @return [Boolean] true if apply succeeded
    def apply_layout(session_name, layout, window: "0")
      target = "#{session_name}:#{window}"
      system("tmux", "select-layout", "-t", target, layout)
    end

    # @param project [String] project/config name
    # @param reattach [Boolean] whether to reattach to existing session
    # @return [String] the shell command to start/attach the project
    def command_for(project, reattach: false)
      if reattach
        tmux_session = session_name_for(project)
        if sessions.include?(tmux_session)
          return "tmux -CC attach -t #{tmux_session}"
        end
      end
      tmuxinator_name = File.basename(@config.config_path_for(project), ".yml")
      "tmuxinator start #{tmuxinator_name} --attach"
    end

    # @param config_name [String] tmuxinator config file name (without .yml)
    # @return [String] the tmux session name from the config file
    def session_name_for(config_name)
      config_path = @config.config_path_for(config_name)
      return config_name unless File.exist?(config_path)
      File.foreach(config_path) do |line|
        return line.split(/\s+/, 2).last.strip if line.match?(/^name:\s/)
      end
      config_name
    end
  end
end
