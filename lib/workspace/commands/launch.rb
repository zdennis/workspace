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
      # Seconds a headless launch waits for a session tmuxinator reported
      # starting. `tmuxinator start --no-attach` returns once tmux has made
      # it, so one that is still missing after this is a failed start.
      HEADLESS_SESSION_WAIT = 5

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
      # @param agent_ensurer [Workspace::Commands::EnsureAgent, nil] starts each project's agent daemon
      #   when none is running (built from +config+ and +pipeline_config+ when nil)
      # @param sleeper [#call] sleeps the given seconds, injected for fast tests
      # @param clock [#call] monotonic seconds, bounding the wait for sessions
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(state:, iterm:, window_manager:, tmux:, project_config:, window_layout:, config:, pipeline_config: nil,
        agent_ensurer: nil, agent_readiness: nil, prompt_timeout: AgentReadiness::DEFAULT_TIMEOUT, sleeper: ->(seconds) { sleep(seconds) },
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, output: $stdout, error_output: $stderr)
        @state = state
        @iterm = iterm
        @window_manager = window_manager
        @tmux = tmux
        @project_config = project_config
        @window_layout = window_layout
        @config = config
        @pipeline_config = pipeline_config || PipelineConfig.new(config: config)
        @agent_ensurer = agent_ensurer || EnsureAgent.new(config: config, pipeline_config: @pipeline_config, sleeper: sleeper, clock: clock, error_output: error_output)
        @agent_readiness = agent_readiness || AgentReadiness.new(tmux: tmux, process_tree: ProcessTree.new)
        @prompt_timeout = prompt_timeout
        @sleeper = sleeper
        @clock = clock
        @output = output
        @error_output = error_output
        @held_start_locks = {}
      end

      # Launches the given projects, reusing existing panes when possible.
      #
      # @param projects [Array<String>] list of project/config names to launch
      # @param reattach [Boolean] whether to reattach to existing tmux sessions
      # @param prompts [Hash{String => String}] project name => prompt text to
      #   send to the coding agent (Claude Code first) in that project's session
      # @param headless [Boolean] start each session in the background with
      #   plain tmux (see #call_headless) instead of in iTerm2 windows
      # @param quiet [Boolean] suppress the progress messages normally written to
      #   +output+ (warnings still go to +error_output+); for callers building a
      #   machine-readable payload of their own, such as `start --json`
      # @return [Hash] +{exit_code:, prompt_failures:}+; exit_code is 1 when any
      #   prompt was not sent, and prompt_failures maps each such project to why.
      #   A headless launch adds +headless: true+, +reused:+ (projects whose
      #   session was already running) and +start_failures:+ (project => why
      #   its session could not be started, which also makes exit_code 1).
      #   The windowed path also adds +reused:+ (projects whose tmux session
      #   was already running and so was attached to instead of started).
      # @raise [Workspace::Error] if any project configs are missing
      def call(projects, reattach: false, prompts: {}, prompt_timeout: @prompt_timeout, headless: false, quiet: false)
        @quiet = quiet
        validate_configs(projects)
        return call_headless(projects, prompts: prompts, prompt_timeout: prompt_timeout) if headless

        @tmux.start_server

        # The start locks are held from the running-session check until each
        # session exists: tmuxinator started in a pane makes it
        # asynchronously, and another launch (windowed or headless) must see
        # it rather than start the project a second time.
        session_names, reused = with_start_locks(projects) do
          @state.load
          live_sessions = @iterm.session_map
          existing = @iterm.find_existing_sessions(@state, live_sessions: live_sessions)

          reuse_projects = projects.select { |p| existing.key?(p) }
          new_projects = projects.reject { |p| existing.key?(p) }

          relaunch_existing(reuse_projects, existing, new_projects, reattach: reattach)
          reused = create_new_panes(new_projects, reattach: reattach, live_sessions: live_sessions)

          @state.save

          [wait_for_tmux_sessions(projects).first, reused]
        end

        start_session_monitors(session_names.keys)

        # Brief pause after tmux sessions are found but before searching for
        # iTerm windows — iTerm needs a moment to create windows for new sessions.
        @sleeper.call(1)

        find_iterm_windows(projects, session_names)

        @state.save

        arrange_windows(projects)

        failures = prompts.any? ? send_prompts(session_names, prompts, prompt_timeout) : {}

        log("Done! Launched #{projects.size} project(s).")
        unless failures.empty?
          @error_output.puts "Error: the prompt was not sent to: #{failures.keys.join(", ")}"
        end
        {exit_code: failures.empty? ? 0 : 1, prompt_failures: failures, reused: reused}
      end

      private

      # Starts each project's tmux session in the background with tmuxinator,
      # never touching iTerm2, AppleScript or window-tool. A project whose
      # session is already running is reused as it is rather than started
      # again; the check and the start happen under a per-project lock, so two
      # launches at once never both run tmuxinator into one session. State
      # records each project whose session is up as headless, so stop, kill,
      # list and status find it, and focus/tile know it has no window.
      def call_headless(projects, prompts:, prompt_timeout:)
        validate_headless_sockets(projects)
        @tmux.start_server
        @state.load
        running = @tmux.sessions

        reused = []
        start_failures = {}
        projects.each do |project|
          failure = start_or_reuse(project, running, reused)
          next unless failure
          @error_output.puts "Error: could not start #{project}: #{failure}"
          start_failures[project] = failure
        end

        launched = projects - start_failures.keys
        session_names, not_found = launched.empty? ? [{}, []] : wait_for_tmux_sessions(launched, max_wait: HEADLESS_SESSION_WAIT)
        not_found.each do |project|
          failure = "its tmux session #{session_names[project]} did not appear within #{HEADLESS_SESSION_WAIT}s"
          @error_output.puts "Error: could not start #{project}: #{failure}"
          start_failures[project] = failure
        end
        session_names = session_names.except(*not_found)
        reused -= not_found

        # A windowed launch may have recorded a pane for one of these since
        # state was loaded; reload under the locks so its window is closed.
        with_start_locks(session_names.keys) do
          @state.load
          close_headless_launcher_windows(session_names.keys)
          session_names.each_key { |project| record_headless(project) }
        end
        @state.save
        start_session_monitors(session_names.keys)

        prompts = prompts.reject { |project, _| start_failures.key?(project) }
        prompt_failures = prompts.any? ? send_prompts(session_names, prompts, prompt_timeout) : {}

        log("Done! Launched #{session_names.size} project(s) headless.")
        session_names.each_value { |session| log("  Attach with: tmux attach -t #{session}") }
        unless prompt_failures.empty?
          @error_output.puts "Error: the prompt was not sent to: #{prompt_failures.keys.join(", ")}"
        end
        ok = prompt_failures.empty? && start_failures.empty?
        {exit_code: ok ? 0 : 1, prompt_failures: prompt_failures, headless: true, reused: reused, start_failures: start_failures}
      end

      # Reuses the project's running session, or starts it. A session missing
      # from +running+ is checked again under the project's start lock, since
      # another launch may have started it in the meantime.
      #
      # @return [String, nil] why the session could not be started
      def start_or_reuse(project, running, reused)
        session = @tmux.session_name_for(project)
        unless running.include?(session)
          failure = with_start_lock(project) do
            next :running if @tmux.sessions.include?(session)
            log("Starting #{project} headless (tmux session #{session})...")
            @tmux.start_headless(project)
          end
          return failure unless failure == :running
        end
        log("Session #{session} is already running for #{project}; reusing it.")
        reused << project
        nil
      end

      # Holds an exclusive flock on the project's start lock (under the XDG
      # state dir) while the block runs. Reentrant: a lock this launch
      # already holds is not taken again, since a second flock on the same
      # file from this process would wait on itself.
      def with_start_lock(project)
        return yield if @held_start_locks[project]
        dir = File.join(@config.state_dir, "launch")
        FileUtils.mkdir_p(dir)
        File.open(File.join(dir, "#{project.gsub(/[^\w.-]/, "_")}.lock"), File::RDWR | File::CREAT, 0o600) do |f|
          f.flock(File::LOCK_EX)
          @held_start_locks[project] = true
          yield
        ensure
          @held_start_locks.delete(project)
        end
      end

      # Holds every project's start lock while the block runs, taken in
      # sorted order so two launches of overlapping projects can't deadlock.
      def with_start_locks(projects, &block)
        projects.uniq.sort.reverse.reduce(block) { |inner, project| -> { with_start_lock(project, &inner) } }.call
      end

      # Refuses to launch any project headless whose tmuxinator config selects
      # a custom tmux socket (-L/-S in tmux_options): every Tmux call this
      # class makes uses the default socket, so it would never see a session
      # started on another one and would rerun tmuxinator into it.
      def validate_headless_sockets(projects)
        projects.each do |project|
          option = @tmux.custom_socket_option(project)
          next unless option
          raise Workspace::Error, "headless launch doesn't support custom tmux sockets (#{option} in tmux_options) for #{project}"
        end
      end

      # Closes the iTerm2 launcher window for any of +projects+ (about to be
      # marked headless) that still has one from an earlier windowed launch,
      # so it isn't left orphaned. Mirrors Stop#find_launcher_windows_to_close:
      # a window is only closed once every project tracked in it is going
      # headless in this same batch. A missing osascript or AppleScript error
      # is a warning, not a failure -- the tmux session already started, and
      # this never touches it.
      def close_headless_launcher_windows(projects)
        return unless projects.any? { |p| @state[p].is_a?(Hash) && @state[p]["unique_id"] }

        existing = @iterm.find_existing_sessions(@state)
        launcher_uids = projects.filter_map { |p| existing[p] }
        return if launcher_uids.empty?

        live_sessions = @iterm.session_map
        candidate_window_ids = launcher_uids.filter_map { |uid| live_sessions[uid] }.uniq
        candidate_window_ids.each do |wid|
          sessions_in_window = live_sessions.select { |_, w| w == wid }.keys
          tracked_project_names = []
          @state.each do |proj, info|
            tracked_project_names << proj if info.is_a?(Hash) && sessions_in_window.include?(info["unique_id"])
          end
          next unless (tracked_project_names - projects).empty?
          close_launcher_window(wid)
        end
      end

      def close_launcher_window(window_id)
        ok = @window_manager.close_window(window_id)
        @error_output.puts "Warning: could not close launcher window #{window_id}" unless ok
      rescue => e
        @error_output.puts "Warning: could not close launcher window #{window_id} (#{e.message})"
      end

      # Marks the project headless. An entry left by an earlier iTerm2 launch
      # keeps its other keys but loses its window and pane ids, which name a
      # window this session no longer has. Done under the start lock on
      # freshly loaded state, so a windowed launch recorded meanwhile is
      # replaced rather than merged into.
      def record_headless(project)
        with_start_lock(project) do
          @state.load
          current = @state[project]
          replace_state(project, (current || {}).except("unique_id", "iterm_window_id").merge("headless" => true))
        end
      end

      # Sets the project's state entry to exactly +entry+. A state_set event
      # merges into the entry, so dropping keys means removing it first.
      # Callers hold the project's start lock and have just loaded state, so
      # +current+ is what another launch may have written.
      def replace_state(project, entry)
        current = @state[project]
        return if current == entry
        @state.delete(project) if current && (current.keys - entry.keys).any?
        @state[project] = entry
      end

      def log(message)
        @output.puts message unless @quiet
      end

      def validate_configs(projects)
        missing = projects.reject { |p| @project_config.exists?(p) }
        return if missing.empty?
        messages = missing.map { |name| "  - #{name} (expected #{@project_config.config_path_for(name)})" }
        raise Workspace::Error, "No tmuxinator config found for:\n#{messages.join("\n")}"
      end

      def relaunch_existing(reuse_projects, existing, new_projects, reattach:)
        reuse_projects.each do |project|
          uid = existing[project]
          log("Reusing existing pane for #{project}...")
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
        return [] if new_projects.empty?

        log("Creating #{new_projects.size} new launcher pane(s)...")
        running = @tmux.sessions
        reused = []
        commands = new_projects.map { |p| [p, command_for_new_pane(p, reattach: reattach, running: running, reused: reused)] }.to_h
        launcher_wid = @iterm.find_launcher_window_id(@state, live_sessions: live_sessions)
        new_session_ids = @iterm.create_launcher_panes(new_projects, commands, launcher_wid: launcher_wid)

        @state.load
        new_session_ids.each do |project, uid|
          replace_state(project, {"unique_id" => uid})
          log("  Created pane for #{project} (#{uid})")
        end

        missing_panes = new_projects - new_session_ids.keys
        if missing_panes.any?
          @error_output.puts "Warning: Failed to create panes for: #{missing_panes.join(", ")}"
        end
        reused
      end

      # Command to run in a newly-created launcher pane for +project+. A
      # session already running for it (e.g. left over from a headless
      # launch, or from a window closed without killing the session) is
      # attached to as-is, the same way a headless launch reuses it, rather
      # than re-running tmuxinator into it. Should the session be killed
      # before the pane attaches, the attach fails and tmuxinator starts it.
      #
      # @return [String] the shell command for the new pane
      def command_for_new_pane(project, reattach:, running:, reused:)
        session = @tmux.session_name_for(project)
        if running.include?(session)
          log("Session #{session} is already running for #{project}; reusing it.")
          reused << project
          return @tmux.reattach_or_start(session, @tmux.command_for(project, reattach: false))
        end
        @tmux.command_for(project, reattach: reattach)
      end

      # Polls for tmux sessions to appear, checking before each wait: a
      # headless start has already made its session, and tmuxinator started
      # from an iTerm pane makes it asynchronously. Gives up after +max_wait+
      # polls or seconds, whichever comes first.
      #
      # @return [Array(Hash{String => String}, Array<String>)] project =>
      #   tmux session name for every project, and the projects never found
      def wait_for_tmux_sessions(projects, max_wait: 30)
        log("Waiting for tmux sessions...")
        window_prefix = "workspace"
        deadline = @clock.call + max_wait
        waited = 0
        sessions_ready = []
        session_names = projects.map { |p| [p, @tmux.session_name_for(p)] }.to_h

        loop do
          existing_tmux = @tmux.sessions
          projects.each do |project|
            next if sessions_ready.include?(project)
            tmux_name = session_names[project]
            if existing_tmux.include?(tmux_name)
              @tmux.rename_window(tmux_name, 0, "#{window_prefix}-#{tmux_name}")
              sessions_ready << project
              log("  Session ready: #{project} (tmux: #{tmux_name})")
            end
          end
          break if sessions_ready.size == projects.size || waited >= max_wait || @clock.call >= deadline
          @sleeper.call(1)
          waited += 1
        end

        not_found = projects - sessions_ready
        if not_found.any?
          @error_output.puts "Warning: Timed out waiting for sessions: #{not_found.join(", ")}"
        end

        [session_names, not_found]
      end

      # Ensures each project has a session-monitor agent daemon, so
      # `workspace sessions` has something to show without a separate
      # `workspace agentd` invocation. A daemon that can't be started is a
      # warning, never a failed launch.
      def start_session_monitors(projects)
        projects.each do |project|
          result = @agent_ensurer.call(name: project)
          next if result.ok? || result.status == :invalid_config

          @error_output.puts "Warning: Could not start session monitor for #{project}: #{result.detail}"
        end
      end

      # Polls for iTerm windows matching each project's tmux session. Windows
      # appear after tmux-CC creates them, which takes a variable amount of time.
      # First checks saved window IDs, then falls back to title-based search.
      def find_iterm_windows(projects, session_names)
        log("Waiting for project windows to appear...")
        window_prefix = "workspace"
        @found_windows = {}

        # Single batch lookup of all iTerm windows per iteration
        max_window_wait = 30
        window_elapsed = 0
        while @found_windows.size < projects.size && window_elapsed < max_window_wait
          @sleeper.call(1) if window_elapsed > 0
          window_elapsed += 1
          all_windows = @window_manager.iterm_windows

          projects.each do |project|
            next if @found_windows.key?(project)

            # Try saved window ID first
            saved_id = @state.dig(project, "iterm_window_id")
            if saved_id && all_windows.key?(saved_id.to_i)
              @found_windows[project] = saved_id.to_s
              log("  Found window for #{project} (saved ID)")
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
              record_window_id(project, best_id.to_i)
              log("  Found window for #{project}")
            end
          end
        end

        missing_windows = projects.reject { |p| @found_windows.key?(p) }
        if missing_windows.any?
          @error_output.puts "Warning: Could not find windows for: #{missing_windows.join(", ")}"
          # Clear stale window IDs so focus/other commands don't use invalid IDs
          missing_windows.each do |project|
            with_start_lock(project) do
              @state.load
              info = @state[project]
              replace_state(project, info.except("iterm_window_id")) if info && !info["headless"]
            end
          end
        end
      end

      # Records the project's iTerm window, unless a headless launch took the
      # project over after this one created its pane.
      def record_window_id(project, window_id)
        with_start_lock(project) do
          @state.load
          info = @state[project]
          @state[project] = {"iterm_window_id" => window_id} if info && !info["headless"]
        end
      end

      # Sends each project its prompt once its agent is ready. The agents all
      # started together, so they share one deadline rather than each getting
      # the full timeout in turn.
      #
      # @return [Hash{String => String}] project => why its prompt was not sent
      def send_prompts(session_names, prompts, prompt_timeout)
        deadline = @agent_readiness.deadline_in(prompt_timeout)
        prompts.each_with_object({}) do |(project, prompt_text), failures|
          log("Waiting for the coding agent in #{project} to be ready (up to #{prompt_timeout}s)...")
          failure = deliver_prompt(project, session_names.fetch(project, project), prompt_text, deadline, prompt_timeout)
          next unless failure
          @error_output.puts "Error: prompt not sent to #{project}: #{failure}"
          failures[project] = failure
        end
      end

      # Waits for the agent, then pastes the prompt. A paste that never shows
      # up in the pane is tried again, up to MAX_PROMPT_ATTEMPTS; one that did
      # show up is not, even if it may not have been submitted, since sending
      # it again would type it twice. A paste that turns up only after the
      # check gave up is submitted with Enter rather than pasted again.
      #
      # @return [String, nil] why the prompt was not sent, or nil once it was
      def deliver_prompt(project, tmux_name, prompt_text, deadline, prompt_timeout)
        last = nil
        MAX_PROMPT_ATTEMPTS.times do |attempt|
          ready = @agent_readiness.wait(tmux_name, deadline: deadline)
          # A retry that runs out of time reports why the paste failed, not
          # that the agent is still busy redrawing after it.
          return last&.message || "#{ready.reason} (waited up to #{prompt_timeout}s)" unless ready.ready?

          if last && @tmux.shows_text?(tmux_name, ready.pane, prompt_text)
            log("The prompt to #{project} arrived late; submitting it...")
            delivery = @tmux.deliver(tmux_name, ready.pane, "")
          else
            log("Sending prompt to #{project} (#{ready.label}, pane #{ready.pane})...")
            delivery = @tmux.deliver(tmux_name, ready.pane, prompt_text)
          end
          return nil if delivery.ok?
          return delivery.message if delivery.landed? || attempt == MAX_PROMPT_ATTEMPTS - 1
          last = delivery
          @error_output.puts "Warning: prompt to #{project} did not arrive (#{delivery.message}); trying again"
        end
      end

      def arrange_windows(projects)
        log("Arranging windows...")
        project_window_ids = projects.filter_map do |project|
          window_id = @found_windows[project]
          {project: project, window_id: window_id} if window_id
        end
        @window_layout.arrange(project_window_ids, quiet: @quiet)
      end
    end
  end
end
