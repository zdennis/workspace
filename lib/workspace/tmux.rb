require "open3"

module Workspace
  # Manages tmux session operations for the workspace CLI.
  class Tmux
    # @param config [Workspace::Config] configuration for path lookups
    def initialize(config:)
      @config = config
    end

    # @return [Array<String>] list of active tmux session names
    def sessions
      stdout, _, status = Open3.capture3("tmux", "list-sessions", "-F", "\#{session_name}")
      status.success? ? stdout.strip.lines.map(&:strip) : []
    end

    # @return [void]
    def start_server
      system("tmux", "start-server")
    end

    # @param name [String] tmux session name
    # @return [void]
    def kill_session(name)
      system("tmux", "kill-session", "-t", name)
    end

    # @param session_name [String] tmux session name
    # @param window_index [String, Integer] window index
    # @param new_name [String] new window name
    # @return [void]
    def rename_window(session_name, window_index, new_name)
      system("tmux", "rename-window", "-t", "#{session_name}:#{window_index}", new_name)
    end

    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1" for window 0, pane 1)
    # @param text [String] text to send (sent in literal mode to avoid key-name interpretation)
    # @param enter [Boolean] whether to press Enter after sending
    # @return [Boolean] true if send succeeded
    def send_keys(session_name, pane, text, enter: true)
      target = "#{session_name}:#{pane}"
      return false unless system("tmux", "send-keys", "-l", "-t", target, text)
      return false if enter && !system("tmux", "send-keys", "-t", target, "Enter")
      true
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
