module Workspace
  module Commands
    # Kills workspace projects and their tmux sessions.
    # Handles launcher window cleanup, only closing windows when
    # all tracked projects within them are being killed.
    class Kill
      # @param state [Workspace::State] state persistence
      # @param iterm [Workspace::ITerm] iTerm automation
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(state:, iterm:, tmux:, output: $stdout, error_output: $stderr)
        @state = state
        @iterm = iterm
        @tmux = tmux
        @output = output
        @error_output = error_output
      end

      # Kills the specified projects (or all active projects if none specified).
      #
      # @param projects [Array<String>] project names to kill (empty = all)
      # @return [Array<String>] names of killed projects
      def call(projects = [])
        @state.load

        if @state.empty?
          @output.puts "No active workspace projects."
          return []
        end

        targets = resolve_targets(projects)

        if targets.empty?
          @output.puts "No matching workspace projects to kill."
          return []
        end

        killed_projects = targets.dup

        launcher_window_ids_to_close = find_launcher_windows_to_close(targets)
        kill_tmux_sessions(targets)
        close_launcher_windows(launcher_window_ids_to_close)
        clear_window_ids(targets)

        @state.save

        @output.puts "Killed #{killed_projects.size} project(s): #{killed_projects.join(", ")}"
        killed_projects
      end

      private

      def resolve_targets(projects)
        if projects.empty?
          @state.keys
        else
          projects.select { |p| @state[p] }.tap do |found|
            not_found = projects - found
            not_found.each { |p| @error_output.puts "Warning: '#{p}' is not an active workspace project" }
          end
        end
      end

      def find_launcher_windows_to_close(targets)
        existing = @iterm.find_existing_sessions(@state)
        launcher_uids = targets.filter_map { |p| existing[p] }
        windows_to_close = []

        if launcher_uids.any?
          live_sessions = @iterm.session_map
          candidate_window_ids = launcher_uids.filter_map { |uid| live_sessions[uid] }.uniq
          candidate_window_ids.each do |wid|
            sessions_in_window = live_sessions.select { |_, w| w == wid }.keys
            tracked_in_window = []
            @state.each do |_, info|
              tracked_in_window << info if sessions_in_window.include?(info["unique_id"])
            end
            tracked_project_names = []
            @state.each do |project, info|
              tracked_project_names << project if sessions_in_window.include?(info["unique_id"])
            end
            if (tracked_project_names - targets).empty?
              windows_to_close << wid
            end
          end
        end

        windows_to_close
      end

      def kill_tmux_sessions(targets)
        targets.each do |project|
          if @tmux.sessions.include?(project)
            @output.puts "Killing tmux session: #{project}"
            @tmux.kill_session(project)
          end
        end
      end

      def close_launcher_windows(window_ids)
        window_ids.each do |wid|
          @output.puts "Closing launcher window #{wid}"
          @iterm.close_window(wid)
        end
      end

      def clear_window_ids(targets)
        targets.each do |p|
          info = @state[p]
          if info
            info.delete("iterm_window_id")
            @state[p] = info
          end
        end
      end
    end
  end
end
