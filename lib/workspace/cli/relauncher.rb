module Workspace
  class CLI
    # Stops active workspaces and brings them back the way they were launched: the `relaunch` verb's
    # work, kept apart from its option parsing so another verb can reuse it. {#call} stops every
    # workspace, pauses, launches the windowed batch, then the headless one, and answers one entry
    # per workspace.
    class Relauncher
      # @param stop_command [Workspace::Commands::Stop] stops the workspaces' sessions
      # @param hook_runner [Workspace::HookRunner] runs each stopped project's `post_stop` hook
      # @param launcher [CLI::Launcher] launches each batch and builds the rows
      # @param state [Workspace::State] says which workspaces were launched headless
      # @param sleeper [#call] sleeps the given seconds, injected for fast tests
      # @param tmux [Workspace::Tmux] says whether a workspace's session is up ({#running?}, and after the stop under +only_stopped+)
      def initialize(stop_command:, hook_runner:, launcher:, state:, sleeper:, tmux:)
        @stop_command = stop_command
        @tmux = tmux
        @hook_runner = hook_runner
        @launcher = launcher
        @state = state
        @sleeper = sleeper
      end

      # Stops the workspaces, waits, and launches them again. Headless ones stay headless. Both
      # batches are attempted even if the windowed batch fails, so a windowed failure never
      # silently drops the headless relaunch; the exit code reflects either failure.
      #
      # With +only_stopped+ (a verb that rewrote the workspaces' configs, where launching a session
      # left running would only re-attach it), each session is checked after the stop, since the stop
      # command answers its names whether or not tmux killed the session: a workspace whose session
      # is still up is not launched and answers a `failed` row, reason `relaunch_stop_failed`.
      #
      # @param invocation [Invocation] its output takes the progress line and the launches' text
      # @param names [Array<String>] the active workspaces to relaunch
      # @param only_stopped [Boolean] launch only the workspaces whose session is gone after the stop
      # @return [Hash] `{exit_code:, results:, warnings:}`: `results` one `relaunched` row per workspace, `warnings` what the stop command collected
      def call(invocation, names, only_stopped: false)
        headless, windowed = names.partition { |name| @state.dig(name, "headless") }
        invocation.output.puts "Will relaunch: #{names.join(", ")}"

        stopped = @stop_command.call(names.dup)
        stopped.each { |name| @hook_runner.run(name, "post_stop") }
        not_stopped = only_stopped ? names.select { |name| running?(name) } : []
        headless -= not_stopped
        windowed -= not_stopped

        @sleeper.call(2)

        launches = []
        launches << @launcher.launch(invocation, windowed.dup) if windowed.any?
        launches << @launcher.launch(invocation, headless.dup, headless: true) if headless.any?
        failed = launches.any? { |l| l[:exit_code] && !l[:exit_code].zero? }
        rows = launches.flat_map { |l| @launcher.rows(l[:projects], l[:result], ok_outcome: "relaunched") }
        rows += not_stopped.map do |name|
          {"workspace" => name, "outcome" => "failed", "reason" => "relaunch_stop_failed", "message" => "its tmux session did not stop, so it was not launched again"}
        end
        {exit_code: (failed || not_stopped.any?) ? 1 : 0, results: rows, warnings: @stop_command.warnings}
      end

      # The state file's key for +name+ (matched with {WorkspaceName.same?}), the test `relaunch`
      # refuses an inactive workspace by.
      #
      # @param name [String]
      # @return [String, nil] the key as the state file spells it, nil when the workspace isn't active
      def active_name(name)
        @state.load
        @state.keys.find { |key| WorkspaceName.same?(key, name) }
      end

      # Whether +pane_id+ is a pane of the workspace's tmux session, asked of the tmux server the
      # workspace runs on (its custom socket, if its config names one). Both session names are
      # compared as tmux stores them (the pane's from tmux, the workspace's through {Tmux#session_name_for}).
      #
      # @param pane_id [String] a pane id such as `$TMUX_PANE`
      # @param name [String] the workspace
      # @return [Boolean, nil] nil when tmux can't say which session the pane is in on that server
      def pane_in_session?(pane_id, name)
        session = @tmux.session_name_for_pane(pane_id, project: name)
        return nil if session.nil?
        Tmux.stored_session_name(session) == @tmux.session_name_for(name)
      rescue Error, SystemCallError
        nil
      end

      # The session of the tmux client this command runs in, for a command with `$TMUX` set but no `$TMUX_PANE`.
      #
      # @param tmux_env [String] the value of `$TMUX`
      # @return [String, nil] nil when tmux can't say
      def client_session(tmux_env)
        @tmux.client_session_name(tmux_env)
      rescue Error, SystemCallError
        nil
      end

      # Whether +session+ is the workspace's tmux session, both names compared as tmux stores them.
      #
      # @param session [String] a session name tmux gave
      # @param name [String] the workspace
      # @return [Boolean, nil] nil when the workspace's session name can't be read
      def session_of?(session, name)
        Tmux.stored_session_name(session) == @tmux.session_name_for(name)
      rescue Error, SystemCallError
        nil
      end

      # Whether the workspace's tmux session is up, asked under the name tmux stores it by. A session
      # whose name can't be worked out counts as up, so a relaunch never launches over it.
      #
      # @param name [String]
      # @return [Boolean]
      def running?(name)
        @tmux.session_exists?(@tmux.session_name_for(name), project: name)
      rescue Error, SystemCallError
        true
      end
    end
  end
end
