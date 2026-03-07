module Workspace
  # Command objects for complex workspace operations.
  module Commands
    # Orchestrates launching tmuxinator projects in iTerm2.
    # Validates configs, manages sessions, creates panes, polls for windows,
    # and arranges them on screen.
    class Launch
      # @param state [Workspace::State] state persistence
      # @param iterm [Workspace::ITerm] iTerm automation
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param project_config [Workspace::ProjectConfig] project config management
      # @param window_layout [Workspace::WindowLayout] window positioning
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(state:, iterm:, tmux:, project_config:, window_layout:, output: $stdout, error_output: $stderr)
        @state = state
        @iterm = iterm
        @tmux = tmux
        @project_config = project_config
        @window_layout = window_layout
        @output = output
        @error_output = error_output
      end

      # Launches the given projects, reusing existing panes when possible.
      #
      # @param projects [Array<String>] list of project/config names to launch
      # @param reattach [Boolean] whether to reattach to existing tmux sessions
      # @return [void]
      # @raise [Workspace::Error] if any project configs are missing
      def call(projects, reattach: false)
        validate_configs(projects)

        @tmux.start_server

        @state.load
        existing = @iterm.find_existing_sessions(@state)

        reuse_projects = projects.select { |p| existing.key?(p) }
        new_projects = projects.reject { |p| existing.key?(p) }

        relaunch_existing(reuse_projects, existing, new_projects, reattach: reattach)
        create_new_panes(new_projects, reattach: reattach)

        @state.save

        session_names = wait_for_tmux_sessions(projects)

        sleep 1

        find_iterm_windows(projects, session_names)

        @state.save

        arrange_windows(projects)

        @output.puts "Done! Launched #{projects.size} project(s)."
      end

      private

      def validate_configs(projects)
        missing = projects.reject { |p| @project_config.exists?(p) }
        return if missing.empty?
        messages = missing.map { |name| "  - #{name} (expected #{@project_config.config_path_for(name)})" }
        raise Workspace::Error, "No tmuxinator config found for:\n#{messages.join("\n")}"
      end

      def relaunch_existing(reuse_projects, existing, new_projects, reattach:)
        reuse_projects.each do |project|
          uid = existing[project]
          @output.puts "Reusing existing pane for #{project}..."
          cmd = @tmux.command_for(project, reattach: reattach)
          result = @iterm.relaunch_in_session(uid, cmd)
          if result != "ok"
            @error_output.puts "  Warning: Session for #{project} disappeared, will create new pane"
            new_projects << project
            @state.delete(project)
          end
        end
      end

      def create_new_panes(new_projects, reattach:)
        return if new_projects.empty?

        @output.puts "Creating #{new_projects.size} new launcher pane(s)..."
        commands = new_projects.map { |p| [p, @tmux.command_for(p, reattach: reattach)] }.to_h
        launcher_wid = @iterm.find_launcher_window_id(@state)
        new_session_ids = @iterm.create_launcher_panes(new_projects, commands, launcher_wid: launcher_wid)

        new_session_ids.each do |project, uid|
          @state[project] = {"unique_id" => uid}
          @output.puts "  Created pane for #{project} (#{uid})"
        end
      end

      def wait_for_tmux_sessions(projects)
        @output.puts "Waiting for tmux sessions..."
        window_prefix = "workspace"
        max_wait = 30
        elapsed = 0
        sessions_ready = []
        session_names = projects.map { |p| [p, @tmux.session_name_for(p)] }.to_h

        while sessions_ready.size < projects.size && elapsed < max_wait
          sleep 1
          elapsed += 1
          existing_tmux = @tmux.sessions
          projects.each do |project|
            next if sessions_ready.include?(project)
            tmux_name = session_names[project]
            if existing_tmux.include?(tmux_name)
              @tmux.rename_window(tmux_name, 0, "#{window_prefix}-#{tmux_name}")
              sessions_ready << project
              @output.puts "  Session ready: #{project} (tmux: #{tmux_name})"
            end
          end
        end

        not_found = projects - sessions_ready
        if not_found.any?
          @error_output.puts "Warning: Timed out waiting for sessions: #{not_found.join(", ")}"
        end

        session_names
      end

      def find_iterm_windows(projects, session_names)
        @output.puts "Waiting for project windows to appear..."
        window_prefix = "workspace"
        @found_windows = {}

        projects.each do |project|
          saved_id = @state.dig(project, "iterm_window_id")
          next unless saved_id
          if @iterm.window_exists?(saved_id)
            @found_windows[project] = saved_id.to_s
            @output.puts "  Found window for #{project} (saved ID)"
          end
        end

        max_window_wait = 30
        window_elapsed = 0
        while @found_windows.size < projects.size && window_elapsed < max_window_wait
          sleep 1
          window_elapsed += 1
          projects.each do |project|
            next if @found_windows.key?(project)
            tmux_name = session_names[project]
            title_to_find = "#{window_prefix}-#{tmux_name}"
            result = @iterm.find_window_by_title(title_to_find)
            if result
              @found_windows[project] = result
              @state[project] = (@state[project] || {}).merge("iterm_window_id" => result.to_i)
              @output.puts "  Found window for #{project}"
            end
          end
        end

        missing_windows = projects.reject { |p| @found_windows.key?(p) }
        if missing_windows.any?
          @error_output.puts "Warning: Could not find windows for: #{missing_windows.join(", ")}"
        end
      end

      def arrange_windows(projects)
        @output.puts "Arranging windows..."
        project_window_ids = projects.filter_map do |project|
          window_id = @found_windows[project]
          {project: project, window_id: window_id} if window_id
        end
        @window_layout.arrange(project_window_ids)
      end
    end
  end
end
