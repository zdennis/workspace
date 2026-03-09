module Workspace
  module Commands
    # Rebuilds workspace state from live iTerm windows.
    # Scans for windows with "workspace-{name}" titles and reconstructs
    # the state file from what's actually running.
    class Repair
      # @param state [Workspace::State] state persistence
      # @param iterm [Workspace::ITerm] iTerm session operations
      # @param window_manager [Workspace::WindowManager] window enumeration
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, iterm:, window_manager:, output: $stdout)
        @state = state
        @iterm = iterm
        @window_manager = window_manager
        @output = output
      end

      # Scans live iTerm windows and rebuilds state entries.
      #
      # @return [void]
      def call
        windows = @window_manager.iterm_windows
        workspace_windows = extract_workspace_windows(windows)

        if workspace_windows.empty?
          @output.puts "No workspace windows found."
          return
        end

        sessions = @iterm.session_map
        sessions_by_window = invert_session_map(sessions)

        @state.load
        rebuilt = []
        workspace_windows.each do |name, wid|
          uid = sessions_by_window[wid]&.first
          entry = @state[name] || {}
          entry["iterm_window_id"] = wid
          entry["unique_id"] = uid if uid
          @state[name] = entry
          rebuilt << name
          uid_info = uid ? " unique_id=#{uid}" : ""
          @output.puts "  #{name}: window_id=#{wid}#{uid_info}"
        end

        @state.save
        @output.puts "Repaired #{rebuilt.size} project(s)."
      end

      # Sets the window ID for a specific project.
      #
      # @param project [String] project name
      # @param window_id [Integer] window ID to assign
      # @return [void]
      def set_window_id(project, window_id)
        @state.load
        entry = @state[project] || {}
        entry["iterm_window_id"] = window_id
        @state[project] = entry
        @state.save
        @output.puts "Set window_id=#{window_id} for #{project}"
      end

      private

      # @param windows [Hash<Integer, String>] window_id => title
      # @return [Hash<String, Integer>] project_name => window_id
      def extract_workspace_windows(windows)
        result = {}
        windows.each do |wid, title|
          match = title.match(/workspace-(\S+)/)
          result[match[1]] = wid if match
        end
        result
      end

      # @param sessions [Hash<String, String>] unique_id => window_id
      # @return [Hash<Integer, Array<String>>] window_id => [unique_ids]
      def invert_session_map(sessions)
        result = {}
        sessions.each do |uid, wid|
          (result[wid.to_i] ||= []) << uid
        end
        result
      end
    end
  end
end
