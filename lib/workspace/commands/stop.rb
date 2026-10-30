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
      # @param window_positions [Workspace::WindowPositions, nil] saves each stopped window's bounds for
      #   the next launch; nil saves nothing
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(state:, iterm:, window_manager:, tmux:, window_positions: nil, output: $stdout, error_output: $stderr)
        @state = state
        @iterm = iterm
        @window_manager = window_manager
        @tmux = tmux
        @window_positions = window_positions
        @output = output
        @error_output = error_output
        @warnings = []
      end

      # @return [Array<String>] sentences about what the latest {#call} could not
      #   do (iTerm2 not answering in time, so its window was left open)
      attr_reader :warnings

      # Stops the specified projects (or all active projects if none specified).
      #
      # The state entries are removed and saved before any tmux session is
      # killed: the caller may be running inside one of those sessions, and
      # killing it ends this process before later statements run.
      #
      # @param projects [Array<String>] project names to stop (empty = all)
      # @param quiet [Boolean] print nothing to the output stream
      # @param warn_inactive [Boolean] warn on the error stream about each named
      #   project that is not active
      # @param save_position [Boolean] save each target's window bounds first (`kill` passes false: its
      #   workspace is going away)
      # @param session_names [Hash{String => String}] tmux session name per project, read by the caller
      #   while the config still existed; a project not listed is looked up from its config
      # @return [Array<String>] names of stopped projects. If iTerm2 does not
      #   answer in time, the launcher windows are left open and {#warnings}
      #   says so; the entries are still removed and saved.
      def call(projects = [], quiet: false, warn_inactive: true, save_position: true, session_names: {})
        out = quiet ? StringIO.new : @output
        @warnings = []
        @state.load

        if @state.empty?
          out.puts "No active workspace projects."
          return []
        end

        targets = resolve_targets(projects, warn_inactive)

        if targets.empty?
          out.puts "No matching workspace projects to stop."
          return []
        end

        killed_projects = targets.dup

        launcher_window_ids_to_close = find_launcher_windows_to_close(targets)
        save_window_positions(targets) if save_position
        remove_from_state(targets)
        @state.save

        out.puts "Stopped #{killed_projects.size} project(s): #{killed_projects.join(", ")}"
        kill_tmux_sessions(targets, out, session_names)
        close_launcher_windows(launcher_window_ids_to_close, out)
        killed_projects
      end

      private

      def resolve_targets(projects, warn_inactive)
        if projects.empty?
          @state.keys
        else
          projects.select { |p| @state[p] }.tap do |found|
            not_found = projects - found
            next unless warn_inactive
            not_found.each { |p| @error_output.puts "Warning: '#{p}' is not an active workspace project" }
          end
        end
      end

      # Headless projects have no launcher pane, so iTerm2 is only asked about
      # targets that have one: a headless-only stop never runs AppleScript.
      def find_launcher_windows_to_close(targets)
        return [] unless targets.any? { |p| @state[p].is_a?(Hash) && @state[p]["unique_id"] }

        existing = @iterm.find_existing_sessions(@state)
        timed_out = @iterm.last_call_timed_out?
        launcher_uids = targets.filter_map { |p| existing[p] }
        windows_to_close = []

        if launcher_uids.any?
          live_sessions = @iterm.session_map
          timed_out ||= @iterm.last_call_timed_out?
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

        warn_iterm_silent(targets) if timed_out
        windows_to_close
      end

      def warn_iterm_silent(targets)
        seconds = format("%g", @iterm.applescript_timeout)
        targets.each do |p|
          next unless @state[p].is_a?(Hash) && @state[p]["unique_id"]
          message = "iTerm did not answer in #{seconds}s; the window for #{p} was left open."
          @warnings << message
          @error_output.puts "Warning: #{message}"
        end
      end

      def kill_tmux_sessions(targets, out, session_names = {})
        active_sessions = @tmux.sessions
        targets.each do |project|
          session_name = session_names[project] || @tmux.session_name_for(project)
          # A session on a custom socket never shows in the default socket's list.
          if active_sessions.include?(session_name) || @tmux.custom_socket_option(project)
            out.puts "Killing tmux session: #{session_name}"
            @tmux.kill_session(session_name, project: project)
          end
        end
      end

      def close_launcher_windows(window_ids, out)
        window_ids.each do |wid|
          out.puts "Closing launcher window #{wid}"
          next if @window_manager.close_window(wid)
          message = "iTerm did not close launcher window #{wid}; it was left open."
          @warnings << message
          @error_output.puts "Warning: #{message}"
        end
      end

      # One read of the windows and one of the screens, before the state entries (and so the
      # window ids) go. A read that fails, or a window already gone, leaves the old file alone.
      def save_window_positions(targets)
        return unless @window_positions
        window_ids = targets.filter_map { |p| @state[p]["iterm_window_id"] if @state[p].is_a?(Hash) }
        return if window_ids.empty?

        bounds = @window_manager.all_window_bounds(window_ids)
        return if bounds.empty?

        screens = @window_manager.screens
        targets.each do |p|
          next unless @state[p].is_a?(Hash) && (rect = bounds[@state[p]["iterm_window_id"].to_i])
          @window_positions.write(p, rect, screen_holding(rect, screens))
        end
      rescue
        # A position that cannot be saved must never keep the workspace from stopping.
        nil
      end

      def screen_holding(rect, screens)
        screens.find do |s|
          rect[:x] >= s[:x] && rect[:x] < s[:x] + s[:width] && rect[:y] >= s[:y] && rect[:y] < s[:y] + s[:height]
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
