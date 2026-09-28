require "stringio"

module Workspace
  module Commands
    # Stops workspace projects and their tmux sessions.
    # Handles launcher window cleanup, only closing windows when
    # all tracked projects within them are being stopped.
    # Projects can be restarted with Commands::Launch.
    class Stop
      # @param state [Workspace::State] state persistence
      # @param iterm [Workspace::ITerm] iTerm session/pane automation
      # @param window_manager [Workspace::WindowManager] iTerm window operations
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(state:, iterm:, window_manager:, tmux:, output: $stdout, error_output: $stderr)
        @state = state
        @iterm = iterm
        @window_manager = window_manager
        @tmux = tmux
        @output = output
        @error_output = error_output
      end

      # Stops the specified projects (or all active projects if none specified).
      #
      # The state entries are removed and saved before any tmux session is
      # killed: the caller may be running inside one of those sessions, and
      # killing it ends this process before later statements run.
      #
      # @param projects [Array<String>] project names to stop (empty = all)
      # @param quiet [Boolean] print nothing to the output stream
      # @return [Array<String>] names of stopped projects
      def call(projects = [], quiet: false)
        out = quiet ? StringIO.new : @output
        @state.load

        if @state.empty?
          out.puts "No active workspace projects."
          return []
        end

        targets = resolve_targets(projects)

        if targets.empty?
          out.puts "No matching workspace projects to stop."
          return []
        end

        killed_projects = targets.dup

        launcher_window_ids_to_close = find_launcher_windows_to_close(targets)
        remove_from_state(targets)
        @state.save

        out.puts "Stopped #{killed_projects.size} project(s): #{killed_projects.join(", ")}"
        kill_tmux_sessions(targets, out)
        close_launcher_windows(launcher_window_ids_to_close, out)
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

      # Headless projects have no launcher pane, so iTerm2 is only asked about
      # targets that have one: a headless-only stop never runs AppleScript.
      def find_launcher_windows_to_close(targets)
        return [] unless targets.any? { |p| @state[p].is_a?(Hash) && @state[p]["unique_id"] }

        existing = @iterm.find_existing_sessions(@state)
        launcher_uids = targets.filter_map { |p| existing[p] }
        windows_to_close = []

        if launcher_uids.any?
          live_sessions = @iterm.session_map
          candidate_window_ids = launcher_uids.filter_map { |uid| live_sessions[uid] }.uniq
          candidate_window_ids.each do |wid|
            sessions_in_window = live_sessions.select { |_, w| w == wid }.keys
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

      def kill_tmux_sessions(targets, out)
        active_sessions = @tmux.sessions
        targets.each do |project|
          session_name = @tmux.session_name_for(project)
          if active_sessions.include?(session_name)
            out.puts "Killing tmux session: #{session_name}"
            @tmux.kill_session(session_name)
          end
        end
      end

      def close_launcher_windows(window_ids, out)
        window_ids.each do |wid|
          out.puts "Closing launcher window #{wid}"
          @window_manager.close_window(wid)
        end
      end

      def remove_from_state(targets)
        targets.each do |p|
          @state.delete(p)
        end
      end
    end
  end
end
