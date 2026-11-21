require "json"

module Workspace
  # Denies a Bash command that matches a pattern in the `deny:` list of the
  # workflow definition the calling pane's run keeps, from the PreToolUse
  # `session-event` hook beside {LockEnforcer}.
  #
  # A tripwire for an agent that was misled or made a mistake, not a sandbox:
  # `bash -c '...'`, a script, an alias or a variable holding the command
  # get past it (see docs/README.workflow.md for the list).
  #
  # How a command is matched:
  # - It is cut into pieces at `;`, `&&`, `||`, `|`, `&`, newlines, parentheses and backticks that are
  #   not inside quotes, so `cd x && git push` is checked as `git push`. A
  #   quoted `;` stays inside its piece, so `git commit -m "a; git push"`
  #   is one piece and is not denied. Parentheses and backticks also cut, so
  #   the inside of `$(...)` is checked.
  # - Runs of blanks outside quotes count as one space, and here-document bodies are skipped.
  # - Each piece loses leading whitespace, leading `NAME=value` assignments and
  #   the wrappers `sudo`, `command`, `env`, `exec`, `nohup`, `time` (and the
  #   `-option` words right after them, with the value of `sudo -u`),
  #   a path before the program (`/usr/bin/git`), and git's and gh's global
  #   options (`git -C dir`, `gh -R repo`).
  # - What is left must match a pattern whole, as a shell glob where `*` and
  #   `?` match any character (`File.fnmatch`, so no text is evaluated).
  #
  # Nearly free for the common case: a pane with no run binding costs one read
  # of the bindings file. It never raises; an unreadable binding or run file
  # allows the tool call, because blocking every tool on a read error would
  # stop the agent for a fault the person can't see.
  class WorkflowDeny
    TOOL = "Bash"

    # The longest command text kept in an event.
    MAX_RECORDED = 300

    FNMATCH_FLAGS = File::FNM_DOTMATCH

    FINISHED = %w[completed failed cancelled].freeze
    private_constant :FINISHED

    # @param bound_run [Workspace::BoundRun] names the run the calling pane is bound to
    # @param run_store [Workspace::WorkflowRunStore] reads the run and writes its history
    # @param event_log [Workspace::EventLog, nil] gets `command_denied`
    # @param logger [Workspace::Logger] debug logger
    # @param command_pieces [Workspace::BashCommandPieces] cuts a command into the pieces that are matched
    def initialize(bound_run:, run_store:, event_log: nil, logger: Workspace::Logger.new, command_pieces: BashCommandPieces.new)
      @bound_run = bound_run
      @run_store = run_store
      @event_log = event_log
      @logger = logger
      @command_pieces = command_pieces
    end

    # @param tool_name [String, nil] the PreToolUse payload's tool_name
    # @param tool_input [Object] the payload's tool_input
    # @return [String, nil] a deny message for stderr, or nil to allow the tool call
    def check(tool_name:, tool_input:)
      return nil unless tool_name == TOOL && tool_input.is_a?(Hash)
      command = tool_input["command"]
      return nil unless command.is_a?(String) && !command.empty?

      run_id = @bound_run.run_id
      return nil unless run_id
      run = @run_store.run(run_id)
      return nil if FINISHED.include?(run.state)
      patterns = WorkflowDefinition.deny(run.definition)
      return nil if patterns.empty?

      pattern = first_match(command, patterns)
      return nil unless pattern

      step = bound_step(run)
      record(run, command, pattern, step)
      message(run, pattern, step)
    rescue => e
      @logger.debug { "session-event: deny check failed (#{e.class}: #{e.message})" }
      nil
    end

    # @param command [String] a Bash command
    # @param patterns [Array<String>] shell globs
    # @return [String, nil] the first pattern a piece of the command matches
    def first_match(command, patterns)
      pieces(command).each do |piece|
        patterns.each { |pattern| return pattern if File.fnmatch(pattern, piece, FNMATCH_FLAGS) }
      end
      nil
    end

    # @param command [String]
    # @return [Array<String>] the pieces of the command, each without its leading assignments and wrappers
    #   (a program given with a path is listed with and without the path)
    def pieces(command)
      @command_pieces.pieces(command)
    end

    private

    # The step the calling pane was bound for when it is a step of the run's fan_out group (a sibling's pane names its
    # own step, not the cursor's); the cursor's otherwise.
    def bound_step(run)
      named = @bound_run.step if @bound_run.respond_to?(:step)
      WorkflowRun.step_scoped?(run.to_h, named) ? named : run.current
    end

    def record(run, command, pattern, step = run.current)
      shown = TerminalText.escape(command[0, MAX_RECORDED])
      data = {"step" => step, "pattern" => pattern, "command" => shown}
      @run_store.record_event(run.id, "command_denied", data)
      @event_log&.record(type: "command_denied", project: run.workspace,
        data: data.merge("run_id" => run.id, "workflow" => run.workflow, "workspace" => run.workspace))
    end

    def step_clause(step)
      step.is_a?(String) ? ", step #{TerminalText.escape(step)}" : ""
    end

    def message(run, pattern, step = run.current)
      "denied by workflow #{TerminalText.escape(run.workflow)}#{step_clause(step)}: " \
        "#{TerminalText.escape(pattern).inspect}. Report this and stop."
    end
  end
end
