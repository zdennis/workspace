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

    # @param project [String] project/config name
    # @param reattach [Boolean] whether to reattach to existing session
    # @return [String] the shell command to start/attach the project
    def command_for(project, reattach: false)
      if reattach && sessions.include?(project)
        "tmux -CC attach -t #{project}"
      else
        "tmuxinator start #{project} --attach"
      end
    end

    # @param config_name [String] tmuxinator config file name (without .yml)
    # @return [String] the tmux session name from the config file
    def session_name_for(config_name)
      config_path = @config.config_path_for(config_name)
      return config_name unless File.exist?(config_path)
      File.readlines(config_path).each do |line|
        if line.match?(/^name:\s/)
          return line.split(/\s+/, 2).last.strip
        end
      end
      config_name
    end
  end
end
