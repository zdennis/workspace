require_relative "gateway_window_match"

module Workspace
  # Closes the iTerm2 windows left behind by a killed workspace session. While tmux -CC is attached,
  # iTerm's AppleScript does not list the buried gateway session, so this looks AFTER the kill: first
  # by the recorded session uid, then, for uids that never come back, by what a detached gateway
  # window shows ({GatewayWindowMatch}). Never raises; trouble comes back as warnings.
  class GatewayWindowCloser
    # @param iterm [#session_map, #single_session_windows, #last_call_timed_out?, #applescript_timeout]
    # @param window_manager [#close_window]
    # @param tmux [#reattach_or_start, #command_for]
    # @param tty_processes [#commands, nil]
    # @param sleeper [#call] sleeps for the given seconds
    # @param clock [#call] monotonic seconds
    # @param wait [Float] seconds to keep looking for a window to appear
    # @param step [Float] seconds between looks
    def initialize(iterm:, window_manager:, tmux:, tty_processes:, sleeper: Kernel.method(:sleep),
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, wait: 2.0, step: 0.25)
      @iterm = iterm
      @window_manager = window_manager
      @tmux = tmux
      @tty_processes = tty_processes
      @sleeper = sleeper
      @clock = clock
      @wait = wait
      @step = step
    end

    # @param targets [Hash{String => String, nil}] windowed projects being stopped => their session uid
    # @param state_snapshot [Hash{String => Hash}] every tracked project's state, from before the stop
    # @param session_names [Hash{String => String}] project => tmux session name
    # @param output [#puts]
    # @return [Array<String>] warnings
    def close(targets:, state_snapshot:, session_names:, output:)
      return [] if targets.empty?

      warnings = []
      @deadline = @clock.call + @wait
      closed = []
      pending = close_by_uid(targets, output, warnings, closed)
      close_by_match(pending, targets, state_snapshot, session_names, output, warnings, closed) unless pending.empty?
      warnings
    end

    private

    # @return [Array<String>] the projects still to look for by screen
    def close_by_uid(targets, output, warnings, closed)
      by_uid = targets.select { |_, uid| uid }
      pending = targets.keys - by_uid.keys
      return pending if by_uid.empty?

      map = nil
      loop do
        map = @iterm.session_map
        if @iterm.last_call_timed_out?
          warn_silent(targets.keys, warnings)
          return []
        end
        break if by_uid.values.all? { |uid| map.key?(uid) } || @clock.call >= @deadline
        @sleeper.call(@step)
      end

      pending += by_uid.keys.reject { |p| map.key?(by_uid[p]) }
      windows = by_uid.values.filter_map { |uid| map[uid]&.to_i }.uniq
      windows.each do |wid|
        uids = map.select { |_, w| w.to_i == wid }.keys
        # Every session in the window must be a target's: a tracked non-target's session, or one
        # nothing tracks, keeps the window open.
        next unless (uids - by_uid.values).empty?
        owner = by_uid.find { |_, uid| map[uid].to_i == wid }.first
        close_window(wid, owner, "launcher", output, warnings, closed)
      end
      pending
    rescue => e
      warnings << "Could not close the launcher window for #{targets.keys.join(", ")}: #{e.message}; it was left open."
      []
    end

    def close_by_match(pending, targets, snapshot, session_names, output, warnings, closed)
      others = snapshot.reject { |p, _| targets.key?(p) }.filter_map { |_, info| info["unique_id"] if info.is_a?(Hash) }
      candidates = nil
      loop do
        windows = @iterm.single_session_windows
        if @iterm.last_call_timed_out?
          warn_silent(pending, warnings)
          return
        end
        candidates = pending.to_h { |p| [p, matching(p, windows, session_names[p], others, closed)] }
        break if candidates.values.none?(&:empty?) || @clock.call >= @deadline
        @sleeper.call(@step)
      end

      candidates.each do |project, found|
        if found.size > 1
          warnings << "More than one detached gateway window matched #{project}; none was closed."
        elsif found.size == 1
          close_window(found.first[:window_id].to_i, project, "gateway", output, warnings, closed)
        end
      end
    rescue => e
      warnings << "Could not close the gateway window for #{pending.join(", ")}: #{e.message}; it was left open."
    end

    def matching(project, windows, session, others, closed)
      launches = [@tmux.reattach_or_start(session, "").split(" || ").first, @tmux.command_for(project)]
      windows.select do |w|
        !others.include?(w[:unique_id]) && !closed.include?(w[:window_id].to_i) &&
          GatewayWindowMatch.match?(contents: w[:contents], launch_commands: launches,
            tty_commands: @tty_processes&.commands(w[:tty]))
      end
    end

    def close_window(wid, project, kind, output, warnings, closed)
      return if closed.include?(wid)
      closed << wid
      output.puts "Closing #{kind} window #{wid}"
      return if @window_manager.close_window(wid)
      warnings << "iTerm did not close the window #{wid} for #{project}; it was left open."
    rescue => e
      warnings << "Could not close the #{kind} window for #{project}: #{e.message}; it was left open."
    end

    def warn_silent(projects, warnings)
      seconds = format("%g", @iterm.applescript_timeout)
      projects.each { |p| warnings << "iTerm did not answer in #{seconds}s; the window for #{p} was left open." }
    end
  end
end
