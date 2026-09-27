module Workspace
  # Command objects for complex workspace operations.
  module Commands
    # Orchestrates launching tmuxinator projects in iTerm2.
    # Validates configs, manages sessions, creates panes, polls for windows,
    # and arranges them on screen.
    class Launch
      # Times a prompt is pasted into an agent's pane when it never shows up
      # there. A prompt that did show up is never sent again.
      MAX_PROMPT_ATTEMPTS = 3

      # @param state [Workspace::State] state persistence
      # @param iterm [Workspace::ITerm] iTerm session/pane automation
      # @param window_manager [Workspace::WindowManager] iTerm window operations
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param project_config [Workspace::ProjectConfig] project config management
      # @param window_layout [Workspace::WindowLayout] window positioning
      # @param config [Workspace::Config] path configuration, used to find/start the session-monitor agent
      # @param pipeline_config [Workspace::PipelineConfig] validates a project's pipeline config before the daemon starts
      # @param agent_readiness [Workspace::AgentReadiness] waits for the coding
      #   agent in a pane to be ready before a prompt is sent
      # @param prompt_timeout [Numeric] seconds to wait for the agents to be
      #   ready, shared by every project in one launch
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(state:, iterm:, window_manager:, tmux:, project_config:, window_layout:, config:, pipeline_config: nil,
        agent_readiness: nil, prompt_timeout: AgentReadiness::DEFAULT_TIMEOUT, output: $stdout, error_output: $stderr)
        @state = state
        @iterm = iterm
        @window_manager = window_manager
        @tmux = tmux
        @project_config = project_config
        @window_layout = window_layout
        @config = config
        @pipeline_config = pipeline_config || PipelineConfig.new(config: config)
        @agent_readiness = agent_readiness || AgentReadiness.new(tmux: tmux, process_tree: ProcessTree.new)
        @prompt_timeout = prompt_timeout
        @output = output
        @error_output = error_output
      end

      # Launches the given projects, reusing existing panes when possible.
      #
      # @param projects [Array<String>] list of project/config names to launch
      # @param reattach [Boolean] whether to reattach to existing tmux sessions
      # @param prompts [Hash{String => String}] project name => prompt text to
      #   send to the coding agent (Claude Code first) in that project's session
      # @return [Hash] +{exit_code:, prompt_failures:}+; exit_code is 1 when any
      #   prompt was not sent, and prompt_failures maps each such project to why
      # @raise [Workspace::Error] if any project configs are missing
      def call(projects, reattach: false, prompts: {})
        validate_configs(projects)

        @tmux.start_server

        @state.load
        live_sessions = @iterm.session_map
        existing = @iterm.find_existing_sessions(@state, live_sessions: live_sessions)

        reuse_projects = projects.select { |p| existing.key?(p) }
        new_projects = projects.reject { |p| existing.key?(p) }

        relaunch_existing(reuse_projects, existing, new_projects, reattach: reattach)
        create_new_panes(new_projects, reattach: reattach, live_sessions: live_sessions)

        @state.save

        session_names = wait_for_tmux_sessions(projects)

        start_session_monitors(session_names.keys)

        # Brief pause after tmux sessions are found but before searching for
        # iTerm windows — iTerm needs a moment to create windows for new sessions.
        sleep 1

        find_iterm_windows(projects, session_names)

        @state.save

        arrange_windows(projects)

        failures = prompts.any? ? send_prompts(session_names, prompts) : {}

        @output.puts "Done! Launched #{projects.size} project(s)."
        unless failures.empty?
          @error_output.puts "Error: the prompt was not sent to: #{failures.keys.join(", ")}"
        end
        {exit_code: failures.empty? ? 0 : 1, prompt_failures: failures}
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

      def create_new_panes(new_projects, reattach:, live_sessions: nil)
        return if new_projects.empty?

        @output.puts "Creating #{new_projects.size} new launcher pane(s)..."
        commands = new_projects.map { |p| [p, @tmux.command_for(p, reattach: reattach)] }.to_h
        launcher_wid = @iterm.find_launcher_window_id(@state, live_sessions: live_sessions)
        new_session_ids = @iterm.create_launcher_panes(new_projects, commands, launcher_wid: launcher_wid)

        new_session_ids.each do |project, uid|
          @state[project] = {"unique_id" => uid}
          @output.puts "  Created pane for #{project} (#{uid})"
        end

        missing_panes = new_projects - new_session_ids.keys
        if missing_panes.any?
          @error_output.puts "Warning: Failed to create panes for: #{missing_panes.join(", ")}"
        end
      end

      # Polls for tmux sessions to appear after pane creation. Tmuxinator
      # starts sessions asynchronously via iTerm's "write text" command, so
      # we need to wait for them to register with the tmux server.
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

      # Starts the session-monitor agent daemon for each project that doesn't
      # already have one running, so `workspace sessions` has something to show
      # without requiring a separate `workspace agent` invocation.
      def start_session_monitors(projects)
        projects.each do |project|
          next if @config.agent_running?(project)

          log_path = @config.agent_log_path(project)

          begin
            @pipeline_config.stages_for(project)
          rescue Workspace::Error => e
            @error_output.puts "Warning: #{project}'s pipeline config is invalid (#{e.message}); " \
              "not starting its session monitor. See #{log_path} once fixed."
            next
          end

          @pipeline_config.literal_sentinel_warnings(project).each { |warning| @error_output.puts "Warning: #{warning}" }

          pid = Process.spawn($PROGRAM_NAME, "agent", "--name", project,
            out: log_path, err: log_path, in: File::NULL)
          Process.detach(pid)
        rescue SystemCallError => e
          @error_output.puts "Warning: Could not start session monitor for #{project}: #{e.message}"
        end
      end

      # Polls for iTerm windows matching each project's tmux session. Windows
      # appear after tmux-CC creates them, which takes a variable amount of time.
      # First checks saved window IDs, then falls back to title-based search.
      def find_iterm_windows(projects, session_names)
        @output.puts "Waiting for project windows to appear..."
        window_prefix = "workspace"
        @found_windows = {}

        # Single batch lookup of all iTerm windows per iteration
        max_window_wait = 30
        window_elapsed = 0
        while @found_windows.size < projects.size && window_elapsed < max_window_wait
          sleep 1 if window_elapsed > 0
          window_elapsed += 1
          all_windows = @window_manager.iterm_windows

          projects.each do |project|
            next if @found_windows.key?(project)

            # Try saved window ID first
            saved_id = @state.dig(project, "iterm_window_id")
            if saved_id && all_windows.key?(saved_id.to_i)
              @found_windows[project] = saved_id.to_s
              @output.puts "  Found window for #{project} (saved ID)"
              next
            end

            # Fall back to title matching (exact project name, shortest title wins)
            tmux_name = session_names[project]
            title_to_find = "#{window_prefix}-#{tmux_name}"
            pattern = /#{Regexp.escape(title_to_find)}(?=[\s\[\]]|$)/
            best_id = nil
            best_len = Float::INFINITY
            all_windows.each do |wid, wname|
              if wname.match?(pattern) && wname.length < best_len
                best_id = wid.to_s
                best_len = wname.length
              end
            end

            if best_id
              @found_windows[project] = best_id
              @state[project] = (@state[project] || {}).merge("iterm_window_id" => best_id.to_i)
              @output.puts "  Found window for #{project}"
            end
          end
        end

        missing_windows = projects.reject { |p| @found_windows.key?(p) }
        if missing_windows.any?
          @error_output.puts "Warning: Could not find windows for: #{missing_windows.join(", ")}"
          # Clear stale window IDs so focus/other commands don't use invalid IDs
          missing_windows.each do |project|
            info = @state[project]
            if info
              info = info.dup
              info.delete("iterm_window_id")
              @state[project] = info
            end
          end
        end
      end

      # Sends each project its prompt once its agent is ready. The agents all
      # started together, so they share one deadline rather than each getting
      # the full timeout in turn.
      #
      # @return [Hash{String => String}] project => why its prompt was not sent
      def send_prompts(session_names, prompts)
        deadline = @agent_readiness.deadline_in(@prompt_timeout)
        prompts.each_with_object({}) do |(project, prompt_text), failures|
          @output.puts "Waiting for the coding agent in #{project} to be ready (up to #{@prompt_timeout}s)..."
          failure = deliver_prompt(project, session_names.fetch(project, project), prompt_text, deadline)
          next unless failure
          @error_output.puts "Error: prompt not sent to #{project}: #{failure}"
          failures[project] = failure
        end
      end

      # Waits for the agent, then pastes the prompt. A paste that never shows
      # up in the pane is tried again, up to MAX_PROMPT_ATTEMPTS; one that did
      # show up is not, even if it may not have been submitted, since sending
      # it again would type it twice.
      #
      # @return [String, nil] why the prompt was not sent, or nil once it was
      def deliver_prompt(project, tmux_name, prompt_text, deadline)
        MAX_PROMPT_ATTEMPTS.times do |attempt|
          ready = @agent_readiness.wait(tmux_name, deadline: deadline)
          return "#{ready.reason} (waited up to #{@prompt_timeout}s)" unless ready.ready?

          @output.puts "Sending prompt to #{project} (#{ready.label}, pane #{ready.pane})..."
          delivery = @tmux.deliver(tmux_name, ready.pane, prompt_text)
          return nil if delivery.ok?
          return delivery.message if delivery.landed? || attempt == MAX_PROMPT_ATTEMPTS - 1
          @error_output.puts "Warning: prompt to #{project} did not arrive (#{delivery.message}); trying again"
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
