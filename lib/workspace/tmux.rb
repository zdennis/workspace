require "open3"
require "securerandom"

module Workspace
  # Manages tmux session operations for the workspace CLI.
  class Tmux
    # @param config [Workspace::Config] configuration for path lookups
    # @param logger [Workspace::Logger] debug logger
    # @param clock [#call] monotonic seconds, injected so specs don't wait
    # @param sleeper [#call] sleeps the given seconds, injected likewise
    def initialize(config:, logger: Workspace::Logger.new,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) })
      @config = config
      @logger = logger
      @clock = clock
      @sleeper = sleeper
    end

    # @return [Array<String>] list of active tmux session names
    def sessions
      @logger.debug { "tmux: listing sessions" }
      stdout, _, status = Open3.capture3("tmux", "list-sessions", "-F", "\#{session_name}")
      result = status.success? ? stdout.strip.lines.map(&:strip) : []
      @logger.debug { "tmux: found #{result.size} session(s): #{result.join(", ")}" }
      result
    end

    # @return [void]
    def start_server
      @logger.debug { "tmux: starting server" }
      system("tmux", "start-server")
    end

    # @param name [String] tmux session name
    # @return [void]
    def kill_session(name)
      @logger.debug { "tmux: killing session #{name}" }
      system("tmux", "kill-session", "-t", name)
    end

    # @param session_name [String] tmux session name
    # @param window_index [String, Integer] window index
    # @param new_name [String] new window name
    # @return [void]
    def rename_window(session_name, window_index, new_name)
      @logger.debug { "tmux: renaming window #{session_name}:#{window_index} to #{new_name}" }
      system("tmux", "rename-window", "-t", "#{session_name}:#{window_index}", new_name)
    end

    # The outcome of {#deliver}.
    #
    # * +:submitted+ — the text appeared in the pane and Enter changed the screen
    # * +:pasted+ — the text appeared in the pane (no Enter was asked for)
    # * +:unverified+ — tmux accepted every command, but the text was never
    #   seen on screen: the pane couldn't be read back, or it kept changing
    #   without showing the text. It may or may not have arrived.
    # * +:unsubmitted+ — the text appeared, but Enter left the screen unchanged,
    #   even after a second try
    # * +:not_landed+ — tmux accepted the paste, but the pane never changed
    # * +:failed+ — a tmux command failed; nothing may have reached the pane
    Delivery = Struct.new(:status, :message, keyword_init: true) do
      # @return [Boolean] whether the text was seen in the pane and, when
      #   Enter was asked for, was submitted
      def ok?
        [:submitted, :pasted].include?(status)
      end

      # @return [Boolean] whether the text reached the pane, or may have.
      #   Sending it again could type it twice.
      def landed?
        ok? || [:unsubmitted, :unverified].include?(status)
      end
    end

    # Seconds between reads of the pane while a delivery is checked.
    DELIVERY_POLL = 0.05
    # Longest wait for pasted text to show up in the pane.
    LAND_TIMEOUT = 2.0
    # Longest wait for the pane to stop changing after a paste, before Enter.
    SETTLE_TIMEOUT = 1.0
    # Longest wait for one Enter to change the screen.
    SUBMIT_TIMEOUT = 2.0
    # How many of the text's last non-blank characters must show on screen
    # to count as the text having arrived.
    TAIL_LENGTH = 16
    # What Claude Code shows in place of a large paste.
    PASTE_PLACEHOLDER = /\[Pasted text #\d+/

    # Sends text to a pane and reports whether it landed.
    #
    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1" for window 0, pane 1)
    # @param text [String] text to send (sent in literal mode to avoid key-name interpretation)
    # @param enter [Boolean] whether to press Enter after sending
    # @return [Boolean] true if the text reached the pane and, with +enter+,
    #   was submitted; see {#deliver} for why a send failed
    def send_keys(session_name, pane, text, enter: true)
      deliver(session_name, pane, text, enter: enter).ok?
    end

    # Pastes text into a pane, presses Enter, and checks each step landed by
    # reading the pane back.
    #
    # The whole text goes in as one bracketed paste, so embedded newlines stay
    # line breaks in the input rather than submitting each line: an agent
    # like Claude Code treats a bare Enter as submit. It goes through
    # load-buffer + paste-buffer because tmux 3.x parses a send-keys argument
    # starting with '-' as flags, even in -l (literal) mode.
    #
    # Enter is pressed once the pane has stopped changing, so a large paste
    # has finished rendering first. If Enter leaves the screen unchanged it is
    # pressed once more; it is never pressed a second time after the screen
    # has changed, so a paste can't be submitted twice.
    #
    # The paste counts as arrived only once the screen shows the end of the
    # text (or a paste placeholder) more often than it did before. A pane
    # that changes without ever showing it, like an agent still streaming
    # output, gets Enter anyway but reports +:unverified+, since the text may
    # be there out of sight.
    #
    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1")
    # @param text [String] text to send
    # @param enter [Boolean] whether to press Enter after sending
    # @return [Workspace::Tmux::Delivery]
    def deliver(session_name, pane, text, enter: true)
      target = "#{session_name}:#{pane}"
      @logger.debug { "tmux: deliver to #{target} (#{text.bytesize} bytes, enter=#{enter})" }
      return submit(target, capture_screen(target)) if text.empty? && enter
      return Delivery.new(status: :pasted, message: "nothing to send") if text.empty?

      before = capture_screen(target)
      # tmux buffers are shared by every client of the server, so the name
      # must not repeat across processes or threads.
      buf = "ws_send_#{Process.pid}_#{SecureRandom.hex(8)}"
      begin
        return failed("tmux could not load the text into a paste buffer") unless tmux_load_buffer(buf, text)
        return failed("tmux could not paste into #{target}") unless system("tmux", "paste-buffer", "-p", "-b", buf, "-t", target)
      ensure
        begin
          system("tmux", "delete-buffer", "-b", buf)
        rescue
          nil
        end
      end

      if before.nil?
        return submit(target, nil) if enter
        return Delivery.new(status: :unverified, message: "pasted, but #{target} could not be read back to check")
      end

      pasted, seen = wait_for_text(target, before, text)
      unless pasted
        return Delivery.new(status: :not_landed,
          message: "pasted, but nothing changed in #{target} within #{LAND_TIMEOUT}s")
      end
      unless seen
        unseen = "#{target} kept changing but never showed the text"
        return Delivery.new(status: :unverified, message: "pasted, but #{unseen}; it may not have arrived") unless enter
        result = submit(target, settle(target, pasted))
        return result if result.status == :failed
        return Delivery.new(status: :unverified, message: "pasted and pressed Enter, but #{unseen}; it may not have arrived")
      end
      return Delivery.new(status: :pasted, message: "pasted into #{target}") unless enter

      submit(target, settle(target, pasted))
    end

    # Whether a pane's screen shows the end of +text+, or a paste placeholder.
    # Tells whether a paste reported as not landed turned up later.
    #
    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1")
    # @param text [String] text that was pasted
    # @return [Boolean]
    def shows_text?(session_name, pane, text)
      screen = capture_screen("#{session_name}:#{pane}")
      !screen.nil? && shows_new_text?("", screen, text)
    end

    # Sends a single key name to a tmux pane (non-literal mode).
    # Used for special keys like "C-c", "Enter", "Escape".
    #
    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1")
    # @param key_name [String] tmux key name (e.g. "C-c", "Enter")
    # @return [Boolean] true if send succeeded
    def send_key(session_name, pane, key_name)
      target = "#{session_name}:#{pane}"
      @logger.debug { "tmux: send-key #{key_name} to #{target}" }
      system("tmux", "send-keys", "-t", target, key_name)
    end

    # Reads what a pane shows right now (its visible screen, no scrollback).
    #
    # @param target [String] any tmux target: "session:0.1", a pane id ("%23")
    # @return [String, nil] the screen text, or nil if tmux reported failure
    def capture_screen(target)
      stdout, _, status = Open3.capture3("tmux", "capture-pane", "-p", "-t", target)
      status.success? ? stdout : nil
    end

    private

    # Presses Enter, and presses it once more only if the first left the
    # screen as it was.
    def submit(target, screen)
      2.times do
        return failed("tmux could not press Enter in #{target}") unless system("tmux", "send-keys", "-t", target, "Enter")
        return Delivery.new(status: :unverified, message: "Enter pressed, but #{target} could not be read back") if screen.nil?
        return Delivery.new(status: :submitted, message: "submitted in #{target}") if wait_for_change(target, screen, SUBMIT_TIMEOUT)
      end
      Delivery.new(status: :unsubmitted,
        message: "the text is in #{target}, but pressing Enter twice didn't change the screen; it may not have been submitted")
    end

    def failed(message)
      Delivery.new(status: :failed, message: message)
    end

    # Polls the pane until its screen differs from +screen+.
    #
    # @return [String, nil] the changed screen, or nil if it never changed
    def wait_for_change(target, screen, timeout)
      deadline = @clock.call + timeout
      loop do
        current = capture_screen(target)
        return current if current && current != screen
        return nil if @clock.call >= deadline
        @sleeper.call(DELIVERY_POLL)
      end
    end

    # Polls the pane after a paste until the screen shows the text.
    #
    # @return [Array(String, Boolean)] the latest changed screen (nil if it
    #   never changed) and whether the text was seen on it
    def wait_for_text(target, before, text)
      deadline = @clock.call + LAND_TIMEOUT
      changed = nil
      loop do
        current = capture_screen(target)
        if current && current != before
          return [current, true] if shows_new_text?(before, current, text)
          changed = current
        end
        return [changed, false] if @clock.call >= deadline
        @sleeper.call(DELIVERY_POLL)
      end
    end

    # Whether +after+ shows the text's last few characters, or a paste
    # placeholder, more often than +before+ did. Blanks are dropped from the
    # text and screens first, since the pane wraps and indents long input.
    def shows_new_text?(before, after, text)
      tail = text.gsub(/\s+/, "").chars.last(TAIL_LENGTH).join
      return false if tail.empty?
      squashed = ->(screen) { screen.gsub(/\s+/, "") }
      squashed.call(after).scan(tail).size > squashed.call(before).scan(tail).size ||
        after.scan(PASTE_PLACEHOLDER).size > before.scan(PASTE_PLACEHOLDER).size
    end

    # Polls until two reads in a row match, so a large paste has finished
    # rendering. Gives up after SETTLE_TIMEOUT and returns the latest screen.
    def settle(target, screen)
      deadline = @clock.call + SETTLE_TIMEOUT
      loop do
        return screen if @clock.call >= deadline
        @sleeper.call(DELIVERY_POLL)
        current = capture_screen(target)
        return screen if current.nil? || current == screen
        screen = current
      end
    end

    # Loads text into a named tmux buffer via stdin.
    # Extracted for testability.
    #
    # @param buf [String] buffer name
    # @param content [String] content to load
    # @return [Boolean] true if load-buffer succeeded
    def tmux_load_buffer(buf, content)
      IO.popen(["tmux", "load-buffer", "-b", buf, "-"], "w") { |io| io.write(content) }
      $?.success?
    end

    public

    # @param session_name [String] tmux session name
    # @param pane [String] pane target (e.g. "0.1")
    # @param size [String] size value (e.g. "10" for rows, "50%" for percentage)
    # @return [Boolean] true if resize succeeded
    def resize_pane(session_name, pane, size)
      target = "#{session_name}:#{pane}"
      system("tmux", "resize-pane", "-t", target, "-y", size)
    end

    # Lists pane indices for a given session window.
    #
    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @return [Array<Integer>] sorted pane indices, empty array on failure
    def panes(session_name, window: "0")
      target = "#{session_name}:#{window}"
      @logger.debug { "tmux: listing panes for #{target}" }
      stdout, _, status = Open3.capture3("tmux", "list-panes", "-t", target, "-F", "\#{pane_index}")
      return [] unless status.success?
      stdout.strip.lines.map { |l| l.strip.to_i }.sort
    end

    # Names the tmux session a pane belongs to.
    #
    # Hooks run inside a pane and inherit TMUX_PANE, so this is how a hook
    # discovers which workspace it is reporting for without being told.
    #
    # @param pane_id [String] a tmux pane id (e.g. "%23")
    # @return [String, nil] the session name, or nil if the pane is gone
    def session_name_for_pane(pane_id)
      stdout, _, status = Open3.capture3(
        "tmux", "display-message", "-p", "-t", pane_id, "\#{session_name}"
      )
      return nil unless status.success?
      name = stdout.strip
      name.empty? ? nil : name
    end

    # Opens a background window running +command+ directly (no shell), so the
    # command itself is the pane's process and leads its own process group.
    #
    # @param session_name [String] tmux session to add the window to
    # @param name [String] window name
    # @param cwd [String] the window's working directory
    # @param command [Array<String>] argv to run
    # @param env [Hash{String=>String}] extra environment for the command
    # @param remain_on_exit [Boolean] keep this window (only) open once the
    #   command exits, so its last output stays readable
    # @return [Integer, nil] the pane's process id, or nil if tmux failed
    def new_window(session_name, name:, cwd:, command:, env: {}, remain_on_exit: false)
      @logger.debug { "tmux: new-window #{name} in #{session_name}: #{command.join(" ")}" }
      args = ["tmux", "new-window", "-d", "-P", "-F", "\#{pane_pid} \#{pane_id}", "-t", "#{session_name}:", "-n", name, "-c", cwd]
      env.each { |key, value| args.push("-e", "#{key}=#{value}") }
      stdout, _, status = Open3.capture3(*args, "--", *command)
      return nil unless status.success?
      pid, pane_id = stdout.split
      return nil unless pid
      Open3.capture3("tmux", "set-option", "-w", "-t", pane_id, "remain-on-exit", "on") if remain_on_exit && pane_id
      pid.to_i
    end

    # Closes a pane kept open by remain-on-exit, once its process has exited.
    # Pane ids can outlive a tmux server restart, so the pane is closed only
    # if it is dead and its recorded process is +pid+.
    #
    # @param pane_id [String] tmux pane id (e.g. "%12")
    # @param pid [Integer] the process that ran in the pane
    # @return [Boolean, nil] true once closed, false while +pid+ is still
    #   running in it, nil if there is no such pane running +pid+
    def close_dead_pane(pane_id, pid:)
      stdout, _, status = Open3.capture3("tmux", "display-message", "-p", "-t", pane_id, "\#{pane_dead} \#{pane_pid}")
      return nil unless status.success?
      dead, pane_pid = stdout.split
      return nil unless pane_pid.to_i == pid
      return false unless dead == "1"
      @logger.debug { "tmux: closing dead pane #{pane_id}" }
      _, _, status = Open3.capture3("tmux", "kill-pane", "-t", pane_id)
      status.success?
    end

    # @return [Boolean] whether a tmux server is running for this user
    def server_running?
      _, _, status = Open3.capture3("tmux", "list-sessions")
      status.success?
    end

    # Lists panes with the attributes session monitoring needs.
    #
    # Unlike {#panes}, entries carry the tmux pane id (\%23), which stays with a
    # pane for its whole life. Indices shift whenever a pane is split or closed,
    # so anything that remembers a pane across time must key on the id.
    #
    # @param session_name [String] tmux session name
    # @param window [String, nil] window index (default "0"), or nil for
    #   every window in the session
    # @return [Array<Hash>] :id, :window, :index, :pid, :title, :command, :cwd per pane
    def pane_details(session_name, window: "0")
      scope = window.nil? ? ["-s", "-t", session_name] : ["-t", "#{session_name}:#{window}"]
      format = ["pane_id", "window_index", "pane_index", "pane_pid", "pane_current_command",
        "pane_current_path", "pane_title"].map { |f| "\#{#{f}}" }.join("\t")
      @logger.debug { "tmux: listing pane details for #{scope.last}" }
      stdout, _, status = Open3.capture3("tmux", "list-panes", *scope, "-F", format)
      return [] unless status.success?

      stdout.lines.filter_map do |line|
        id, window_index, index, pid, command, cwd, title = line.chomp.split("\t", 7)
        next if id.nil? || id.empty?
        {id: id, window: window_index.to_i, index: index.to_i, pid: pid.to_i, command: command.to_s,
         cwd: cwd.to_s, title: title.to_s}
      end
    end

    # Finds the first pane whose title contains the given string (case-insensitive).
    # Useful for locating panes by process name or displayed title.
    #
    # @param session_name [String] tmux session name
    # @param title_pattern [String] case-insensitive substring to match against pane titles
    # @param window [String] window index (default "0")
    # @return [Integer, nil] pane index of the first matching pane, or nil if not found
    def find_pane_by_title(session_name, title_pattern, window: "0")
      target = "#{session_name}:#{window}"
      pattern = title_pattern.downcase
      @logger.debug { "tmux: searching for pane matching #{title_pattern.inspect} in #{target}" }
      stdout, _, status = Open3.capture3("tmux", "list-panes", "-t", target, "-F", "\#{pane_index} \#{pane_title}")
      return nil unless status.success?
      stdout.strip.lines.each do |line|
        index_str, title = line.strip.split(" ", 2)
        next unless title&.downcase&.include?(pattern)
        index = index_str.to_i
        @logger.debug { "tmux: found #{title_pattern.inspect} at pane #{index} (title: #{title.strip})" }
        return index
      end
      @logger.debug { "tmux: no pane matching #{title_pattern.inspect} found in #{target}" }
      nil
    end

    # Finds the pane running Claude Code, identified by its title.
    # Claude Code sets its own pane title to "✳ Claude Code X.X.X".
    #
    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @return [Integer, nil] pane index of the Claude Code pane, or nil if not found
    def find_claude_pane(session_name, window: "0")
      find_pane_by_title(session_name, "Claude Code", window: window)
    end

    # Splits a pane in the given window.
    #
    # Uses `-P -F '#{pane_index}'` so the new pane's index is reported by tmux itself.
    # Callers must not re-query {#panes} and assume the last entry is the new pane —
    # that is racy and can be defeated by tmux pane index reuse.
    #
    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @param pane [Integer, nil] pane index to split; nil targets the window (tmux picks active pane)
    # @param vertical [Boolean] true = side-by-side (-h), false = top/bottom (-v, default)
    # @return [Integer, nil] index of the newly created pane, or nil if the split failed
    def split_window(session_name, window: "0", pane: nil, vertical: false)
      target = pane ? "#{session_name}:#{window}.#{pane}" : "#{session_name}:#{window}"
      @logger.debug { "tmux: split-window #{vertical ? "-h" : "-v"} -t #{target}" }
      stdout, _, status = Open3.capture3(
        "tmux", "split-window", (vertical ? "-h" : "-v"), "-t", target,
        "-P", "-F", "\#{pane_index}"
      )
      return nil unless status.success?
      new_index = stdout.strip
      return nil if new_index.empty?
      new_index.to_i
    end

    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @return [String, nil] the layout string, or nil if capture fails
    def capture_layout(session_name, window: "0")
      target = "#{session_name}:#{window}"
      stdout, _, status = Open3.capture3("tmux", "list-windows", "-t", target, "-F", "\#{window_layout}")
      status.success? ? stdout.strip : nil
    end

    # Captures the scrollback buffer of a tmux pane and returns it as a string.
    #
    # @param session_name [String] tmux session name
    # @param pane [Integer] zero-based pane index within window 0
    # @param lines [Integer] number of lines from the bottom to capture (default 100)
    # @param all [Boolean] capture the full history up to history-limit (overrides lines:)
    # @return [String, nil] the captured text, or nil if tmux reported failure
    def capture_pane(session_name, pane, lines: 100, all: false)
      target = "#{session_name}:0.#{pane}"
      @logger.debug { "tmux: capture-pane -t #{target} (all=#{all}, lines=#{lines})" }
      args = ["tmux", "capture-pane", "-t", target, "-p"]
      args += all ? ["-S", "-"] : ["-S", "-#{lines}"]
      stdout, _, status = Open3.capture3(*args)
      status.success? ? stdout : nil
    end

    # @param session_name [String] tmux session name
    # @param layout [String] tmux layout string
    # @param window [String] window index (default "0")
    # @return [Boolean] true if apply succeeded
    def apply_layout(session_name, layout, window: "0")
      target = "#{session_name}:#{window}"
      system("tmux", "select-layout", "-t", target, layout)
    end

    # @param project [String] project/config name
    # @param reattach [Boolean] whether to reattach to existing session
    # @return [String] the shell command to start/attach the project
    def command_for(project, reattach: false)
      if reattach
        tmux_session = session_name_for(project)
        if sessions.include?(tmux_session)
          return "tmux -CC attach -t #{tmux_session}"
        end
      end
      tmuxinator_name = File.basename(@config.config_path_for(project), ".yml")
      "tmuxinator start #{tmuxinator_name} --attach"
    end

    # @param config_name [String] tmuxinator config file name (without .yml)
    # @return [String] the tmux session name from the config file
    def session_name_for(config_name)
      config_path = @config.config_path_for(config_name)
      return config_name unless File.exist?(config_path)
      File.foreach(config_path) do |line|
        return line.split(/\s+/, 2).last.strip if line.match?(/^name:\s/)
      end
      config_name
    end
  end
end
