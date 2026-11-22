require "stringio"

module Workspace
  module Commands
    # Stops workspace projects and their tmux sessions.
    # Closes each stopped workspace's iTerm window after the kill, through the gateway closer, which
    # only closes a window when every session in it belongs to a stopped project.
    # Projects can be restarted with Commands::Launch.
    class Stop
      # @param state [Workspace::State] state persistence
      # @param iterm [Workspace::ITerm] iTerm session/pane automation
      # @param window_manager [Workspace::WindowManager] iTerm window operations
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param window_positions [Workspace::WindowPositions, nil] saves each stopped window's bounds for
      #   the next launch; nil saves nothing
      # @param gateway_closer [Workspace::GatewayWindowCloser, nil] closes each stopped workspace's iTerm
      #   window after its session is killed; nil closes no window
      # @param launch_mode [Workspace::LaunchMode, nil] tells whether an entry with no recorded session uid
      #   is headless; nil treats such an entry as having no window
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(state:, iterm:, window_manager:, tmux:, window_positions: nil, gateway_closer: nil, launch_mode: nil, output: $stdout, error_output: $stderr)
        @state = state
        @iterm = iterm
        @window_manager = window_manager
        @tmux = tmux
        @window_positions = window_positions
        @gateway_closer = gateway_closer
        @launch_mode = launch_mode
        @output = output
        @error_output = error_output
        @warnings = []
      end

      # @return [Array<String>] the gateway closer's sentences about what the latest {#call} could not
      #   do (iTerm2 not answering in time, a window left open)
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
      # @param socket_arguments [Hash{String => Array<String>}] custom tmux socket flag and value (`["-L", "name"]`)
      #   per project, read the same way; a project not listed is looked up from its config
      # @return [Array<String>] names of stopped projects. If a window cannot be closed, it is left open
      #   and {#warnings} says so; the entries are still removed and saved.
      def call(projects = [], quiet: false, warn_inactive: true, save_position: true, session_names: {}, socket_arguments: {})
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

        snapshot = @state.to_h.to_h { |k, v| [k, v.is_a?(Hash) ? v.dup : v] }
        windowed = @gateway_closer ? windowed_targets(targets, snapshot) : {}
        window_session_names = windowed.keys.to_h { |p| [p, session_name_for(p, session_names)] }
        save_window_positions(targets) if save_position
        remove_from_state(targets)
        @state.save

        out.puts "Stopped #{killed_projects.size} project(s): #{killed_projects.join(", ")}"
        kill_tmux_sessions(targets, out, session_names, socket_arguments)
        close_windows(windowed, snapshot, window_session_names, out) unless windowed.empty?
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

      # Windowed targets, project => session uid (nil when none is recorded). Headless entries are
      # left out, so a headless-only stop never runs AppleScript.
      def windowed_targets(targets, snapshot)
        headless_default = nil
        targets.each_with_object({}) do |p, found|
          info = snapshot[p]
          next unless info.is_a?(Hash) && info["headless"] != true
          if info["unique_id"]
            found[p] = info["unique_id"]
          elsif @launch_mode
            headless_default = @launch_mode.resolve.headless? if headless_default.nil?
            found[p] = nil unless headless_default
          end
        end
      end

      def session_name_for(project, session_names)
        session_names[project] || @tmux.session_name_for(project)
      end

      def kill_tmux_sessions(targets, out, session_names = {}, socket_arguments = {})
        active_sessions = @tmux.sessions
        targets.each do |project|
          session_name = session_name_for(project, session_names)
          # A session on a custom socket never shows in the default socket's list.
          socket = socket_arguments[project]
          if active_sessions.include?(session_name) || socket || @tmux.custom_socket_option(project)
            out.puts "Killing tmux session: #{session_name}"
            @tmux.kill_session(session_name, project: project, socket: socket)
          end
        end
      end

      def close_windows(windowed, snapshot, session_names, out)
        @gateway_closer.close(targets: windowed, state_snapshot: snapshot, session_names: session_names, output: out).each do |message|
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
