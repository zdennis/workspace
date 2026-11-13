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
      def initialize(stop_command:, hook_runner:, launcher:, state:, sleeper:)
        @stop_command = stop_command
        @hook_runner = hook_runner
        @launcher = launcher
        @state = state
        @sleeper = sleeper
      end

      # Stops the workspaces, waits, and launches them again. Headless ones stay headless. Both
      # batches are attempted even if the windowed batch fails, so a windowed failure never
      # silently drops the headless relaunch; the exit code reflects either failure.
      #
      # @param invocation [Invocation] its output takes the progress line and the launches' text
      # @param names [Array<String>] the active workspaces to relaunch
      # @return [Hash] `{exit_code:, results:, warnings:}`: `results` one `relaunched` row per workspace, `warnings` what the stop command collected
      def call(invocation, names)
        headless, windowed = names.partition { |name| @state.dig(name, "headless") }
        invocation.output.puts "Will relaunch: #{names.join(", ")}"

        stopped = @stop_command.call(names.dup)
        stopped.each { |name| @hook_runner.run(name, "post_stop") }

        @sleeper.call(2)

        launches = []
        launches << @launcher.launch(invocation, windowed.dup) if windowed.any?
        launches << @launcher.launch(invocation, headless.dup, headless: true) if headless.any?
        failed = launches.any? { |l| l[:exit_code] && !l[:exit_code].zero? }
        rows = launches.flat_map { |l| @launcher.rows(l[:projects], l[:result], ok_outcome: "relaunched") }
        {exit_code: failed ? 1 : 0, results: rows, warnings: @stop_command.warnings}
      end
    end
  end
end
