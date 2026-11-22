require "digest"
require "shellwords"
require "time"

module Workspace
  # Delivers a review round into its review window, with the run's lock given up: the `ctx.review` follow-up a
  # round start registers ({WorkflowProgress}), run by {WorkflowEvaluation#finish_follow_ups} as the engine's
  # `review_round:`. In order: the workspace must be on the default tmux server (a custom socket is refused as
  # `review_custom_socket`), the agent daemon must run (its hook log proves the verdicts), the round's revision
  # is computed ({WorkflowReviewRevision}), its directory checked ({WorkflowReviewTally#ensure_round}) and its
  # prompt written ({WorkflowPrompt#review_text}); then a window marked for the round is reused, or one opened
  # (`review-STEP`, `WORKSPACE_REVIEW_RUN` in its environment, the `@workspace-review RUN:STEP:ROUND` mark) running
  # Claude Code in the checkout, whatever agent the main pane runs. A window an earlier round of the step left (a
  # rejection or a stopped round keeps it) is carried over instead: marked for this round, its reviewer bound to this
  # round, and its conversation cleared (`/clear`) as the line is typed. Once Claude Code is ready the pane is bound as
  # the reviewer, one change records the pane, window, revision, prompt and packs (so a review Stop that comes
  # before the last change still finds its pane), and the prompt's line is typed. A last change then ends the
  # round's delivery mark. Each change applies only while the run is still on that step, attempt and round and
  # this process (pid and start time) still holds the mark; a run that moved on (cancelled, `--from`, another
  # round) gets the window closed instead, unless the round went on in that window by its own turn's end or
  # another process took the delivery over. A delivery that fails, or whose process is interrupted, is recorded
  # as `delivery: failed` with its `failure`, its window closed (unless its agent waits at a sign-in, trust or
  # approval screen, kept for the person). {#close} is the engine's `review_closer:`.
  class WorkflowReviewRound
    # The agent kind a review pane runs: Claude Code, for its Stop hook, sub-agents and `/clear`.
    AGENT_KIND = "claude"

    # The environment variable the review window's agent is started with; `session-event` marks its ledger entries by it.
    RUN_ENV = "WORKSPACE_REVIEW_RUN"

    # The failure of a round whose workspace runs on its own tmux socket: its windows can't be reached by id.
    CUSTOM_SOCKET = "review_custom_socket"

    # The failure of a delivery whose process was stopped by a signal before it finished.
    INTERRUPTED = "delivery_interrupted"

    # @param store [Workspace::WorkflowRunStore] reads the run before the delivery, and stamps the window it opens ({WorkflowRunStore#stamp})
    # @param change [Workspace::WorkflowRunChange] records the delivery under the run's lock
    # @param tmux [Workspace::Tmux] lists, opens and closes review windows
    # @param panes [Workspace::WorkflowPanes] the daemon check, the reviewer binding, the typed line and the window close
    # @param readiness [Workspace::PaneDispatch] waits for the window's agent ({PaneDispatch#await_ready})
    # @param main_agent [Workspace::MainAgent] the command that starts a fresh Claude Code for the workspace
    # @param revision [#call] the round's revision, given `run:`, `step:` and `stop_when:` ({WorkflowReviewRevision})
    # @param prompt [Workspace::WorkflowPrompt] writes the round's prompt
    # @param round_dirs [#ensure_round] the round's directory ({WorkflowReviewTally#ensure_round})
    # @param holder [#call] answers this process as a round's `holder` ("pid" and "started"), the same answer the
    #   round start stored (`build_cli` keeps it once its start time is read)
    # @param shell [String] the shell the agent's command runs under, as a login shell (`SHELL -lc COMMAND`)
    # @param which [#call] given a program name, its path on PATH or nil; only words a not-ready agent's failure
    # @param error_output [IO] where a failure that could not be recorded is said
    # @param clock [#call] returns the current Time
    # @param home [String] the user's home directory, where {#prewarm}'s memory digest reads `.claude/CLAUDE.md` and `.claude/settings.json`
    def initialize(store:, change:, tmux:, panes:, readiness:, main_agent:, revision:, prompt:, round_dirs:, holder:, shell: "/bin/sh",
      which: Which.method(:path), error_output: $stderr, clock: -> { Time.now }, home: Dir.home)
      @store = store
      @change = change
      @tmux = tmux
      @panes = panes
      @readiness = readiness
      @main_agent = main_agent
      @revision = revision
      @prompt = prompt
      @round_dirs = round_dirs
      @holder = holder
      @shell = shell
      @which = which
      @error_output = error_output
      @clock = clock
      @home = home
    end

    # Delivers the round, or does nothing when the run is no longer waiting for this delivery (another step, attempt
    # or round, a stop, a park, an end, or another live process holding the mark). Never raises for a failed
    # delivery: the failure is recorded on the round. A signal that stops the process is recorded as a failure
    # (`delivery_interrupted`) and raised again.
    #
    # @param run_id [String]
    # @param pending [Hash{String=>Object}] what the round start registered: "step", "attempt" and "round"
    # @return [WorkflowRun] the run afterwards
    def call(run_id, pending)
      run = @store.run(run_id)
      return run unless wanted?(run, pending)
      deliver(run, pending)
    rescue Workspace::Error => e
      raise unless e.code == "run_not_active"
      @store.run(run_id)
    end

    # Closes an ended round's review window (by its mark), or every review window of the run. A close of round K
    # leaves the window of a later round of the step, which a resume may have opened before this close ran. Never raises.
    #
    # @param run_id [String]
    # @param found [Hash{String=>Object}] what was registered: "workspace", "step" (nil for every step), "round", "pane"
    # @return [Array<String>] the window ids closed
    def close(run_id, found)
      workspace = found["workspace"] || @store.run(run_id).workspace
      @panes.close_review(workspace, run_id, step: found["step"], round: found["step"] && found["round"])
    rescue Workspace::Error, SystemCallError
      []
    end

    # Opens the review window of the step's next round ahead of the round, with the arguments a cold round opens one
    # with, and records it as the step's `review_window` (`round`, `window`, `pane`, `warm: true`, `memory`, `opened_at`)
    # and `review_model`. Types nothing, binds nothing and waits for nothing. Opens nothing for a step with no `review:`,
    # one in a `fan_out` group, a workspace on its own tmux socket, a step whose rounds are spent, or one whose
    # `review_window` is a window tmux still has, unless that is a window a rejected round kept whose reviewer is between
    # turns: that one is replaced ({#replace_kept}). A run that left the step or attempt by the time the slot is written
    # (or has its step reviewing, or a round started) records nothing and has the window it opened closed, by its id.
    #
    # @param run [WorkflowRun, Hash] the run as read
    # @param step_id [String]
    # @param attempt [Integer] the attempt just dispatched
    # @return [Hash, nil] the recorded slot; nil when nothing was opened or recorded
    def prewarm(run, step_id, attempt)
      run = WorkflowRun.from_h(run)
      step = run.definition["steps"].find { |each| each["id"] == step_id }
      return nil unless WorkflowDefinition.review(step)
      return nil if WorkflowDefinition.siblings_of(run.definition, step_id)
      return nil if @tmux.custom_socket_option(run.workspace)
      return nil if WorkflowTransitions.review_rounds_spent?(run.to_h, step_id)
      session = @tmux.session_name_for(run.workspace)
      kept = run.steps[step_id]&.to_h&.dig("review_window")
      if kept
        # A window tmux can't be read about is not known to be gone: nothing is opened.
        listed = @tmux.review_windows(session, timeout: WorkflowPanes::TMUX_READ_TIMEOUT, strict: true)
        return nil if listed.nil?
        open = listed.any? { |each| each[:window] == (kept.is_a?(Hash) ? kept["window"] : nil) }
        return nil if open && !replace_kept(run, step_id, kept)
      end
      round = run.steps[step_id]&.to_h&.dig("review_rounds").to_i + 1
      memory = memory_digest(run.worktree)
      opened = open_review_window(session, run, step_id, round, review_agent(run, step))
      return nil unless opened
      slot = {"round" => round, "window" => opened[:window], "pane" => opened[:pane], "warm" => true,
              "memory" => memory, "opened_at" => @clock.call.utc.iso8601(3)}
      model = round_model(run, step)
      recorded = false
      begin
        @change.call(run.id, actor: "engine", cause: "review_prewarm") do |read|
          hash = read.thawed
          state = hash.dig("steps", step_id)
          next unless prewarm_wanted?(hash, state, step_id, attempt, round) && state["review_window"] == kept
          recorded = true
          state["review_window"] = slot
          model ? state["review_model"] = model : state.delete("review_model")
          WorkflowRun.from_h(hash)
        end
      rescue Workspace::Error, SystemCallError => e
        @tmux.kill_window(opened[:window], timeout: WorkflowPanes::TMUX_READ_TIMEOUT) unless recorded
        raise unless e.is_a?(Workspace::Error) && e.code == "run_not_active"
        return recorded ? slot : nil
      end
      @tmux.kill_window(opened[:window], timeout: WorkflowPanes::TMUX_READ_TIMEOUT) unless recorded
      recorded ? slot : nil
    rescue Timeout::Error
      nil
    end

    # Closes the warm review window (`review_window` with `warm: true`) of every step but the current one: kills the
    # window by the id the slot holds, then drops the slot in a run change, only while that step is still not current
    # and its slot is unchanged. A change that fails leaves the slot, which a later read finds pointing at no window.
    #
    # @param run [WorkflowRun, Hash] the run as read
    # @return [WorkflowRun] the run afterwards
    def close_warm(run)
      run = WorkflowRun.from_h(run)
      warm = run.steps.filter_map do |id, step|
        slot = step&.to_h&.dig("review_window")
        [id, slot] if id != run.current && slot.is_a?(Hash) && slot["warm"] == true
      end
      return run if warm.empty?
      warm.each { |_, slot| @tmux.kill_window(slot["window"], timeout: WorkflowPanes::TMUX_READ_TIMEOUT) if slot["window"].is_a?(String) }
      @change.call(run.id, actor: "engine", cause: "review_prewarm") do |read|
        hash = read.thawed
        warm.each do |id, slot|
          state = hash.dig("steps", id)
          state.delete("review_window") if hash["current"] != id && state.is_a?(Hash) && state["review_window"] == slot
        end
        WorkflowRun.from_h(hash)
      end
    rescue Workspace::Error, SystemCallError, Timeout::Error
      run
    end

    # The run is still on the step and attempt the window was opened for, not reviewing, and no round started since.
    def prewarm_wanted?(hash, state, step_id, attempt, round)
      return false unless state.is_a?(Hash) && hash["current"] == step_id && state["state"] != "reviewing"
      Array(state["attempts"]).last&.dig("n") == attempt && state["review_rounds"].to_i + 1 == round
    end

    # A window a rejected or stopped round kept (`review_window` with no `warm`) whose reviewer the daemon shows between
    # turns ({WorkflowPanes#quiet?}) is killed and its pane's reviewer unbound, so a warm window takes its place; true
    # then. A warm slot, a step reviewing or a slot changed when the run is read again just before the kill, a kept window with no pane, a reviewer at work or waiting, a daemon that can't say, or a kill
    # tmux refuses leaves the window to the next round's carried path: false.
    def replace_kept(run, step_id, kept)
      return false unless kept.is_a?(Hash) && kept["warm"] != true && kept["window"].is_a?(String) && kept["pane"].is_a?(String)
      return false unless @panes.quiet?(run.workspace, kept["pane"])
      # Read again just before the kill: a round may have started in the window, or the slot moved, since dispatch.
      now = @store.run(run.id).steps[step_id]&.to_h || {}
      return false if now["state"] == "reviewing" || now["review_window"] != kept
      return false unless @tmux.kill_window(kept["window"], timeout: WorkflowPanes::TMUX_READ_TIMEOUT)
      @panes.unbind(run.id, role: "reviewer", pane: kept["pane"])
      true
    end

    # SHA-256 over the Claude Code start-up files a review process reads when it starts: `CLAUDE.md` and `CLAUDE.local.md`
    # of the checkout and every directory above it, the checkout's `.claude/CLAUDE.md`, `.mcp.json`, `.claude/settings*.json`
    # and everything under `.claude/agents`, `commands`, `skills` and `rules` (dotfiles and symlinks followed, each
    # directory walked once), and the user's `CLAUDE.md` and `settings.json`. Each entry is a path and the hash of what it
    # resolves to: a missing file counts as absent, a dangling link as its target and absent, an unreadable one as
    # unreadable, so creating or editing any changes the digest. `@`-imports are not followed.
    def memory_digest(worktree)
      root = File.expand_path(worktree)
      claude = File.join(root, ".claude")
      files = [".mcp.json", ".claude/CLAUDE.md"].map { |name| File.join(root, name) }
      files += Dir.glob(File.join(claude, "settings*.json"))
      files += %w[agents commands skills rules].flat_map { |dir| tree_files(File.join(claude, dir)) }
      files += %w[CLAUDE.md CLAUDE.local.md].flat_map { |name| ancestors_of(root).map { |dir| File.join(dir, name) } }
      files += %w[CLAUDE.md settings.json].map { |name| File.join(@home, ".claude", name) }
      digest = Digest::SHA256.new
      files.uniq.sort.each { |path| digest << path << "\0" << file_state(path) << "\n" }
      digest.hexdigest
    end

    # The directory and every one above it, up to the root.
    def ancestors_of(dir)
      found = [dir]
      found << File.dirname(found.last) until found.last == File.dirname(found.last)
      found
    end

    def file_state(path)
      return "#{File.readlink(path)} absent" if File.symlink?(path) && !File.exist?(path)
      File.file?(path) ? Digest::SHA256.file(path).hexdigest : "absent"
    rescue SystemCallError
      "unreadable"
    end

    # Every path under +dir+ (dotfiles and links followed), a directory entered once by its real path.
    def tree_files(dir, seen = [], depth = 0)
      return [] unless File.directory?(dir) && depth < 16
      real = File.realpath(dir)
      return [] if seen.include?(real)
      seen << real
      Dir.children(dir).sort.flat_map do |name|
        path = File.join(dir, name)
        File.directory?(path) ? tree_files(path, seen, depth + 1) : [path]
      end
    rescue SystemCallError
      [dir]
    end

    # The agent command a review window starts: Claude Code for the workspace, on the round's model.
    def review_agent(run, step)
      with_model(@main_agent.spawn_command(run.workspace, AGENT_KIND), round_model(run, step))
    end

    def open_review_window(session, run, step_id, round, agent)
      @tmux.open_window(session, name: "review-#{step_id}", cwd: run.worktree, command: [@shell, "-lc", agent],
        env: {RUN_ENV => run.id}, option: WorkflowPanes.review_mark(run.id, step_id, round), store: @store.stamp)
    end

    def deliver(run, pending)
      workspace = run.workspace
      step = run.definition["steps"].find { |each| each["id"] == pending["step"] }
      window = nil
      kicked = false
      begin
        if @tmux.custom_socket_option(workspace)
          return failed(run, pending, nil, CUSTOM_SOCKET, "review rounds are not supported for a workspace on its own tmux socket " \
            "(its tmuxinator config sets socket_name); remove socket_name from #{workspace}'s config, or the review: from step #{pending["step"]}")
        end
        @panes.require_daemon(workspace)
        # A rerun of missing reviewers judges the revision its round already holds (the verdicts kept were written
        # against it), and a round after a rejection had its revision computed when the engine compared the two.
        answer = pending["revision"].is_a?(String) ? {revision: pending["revision"]} : @revision.call(run: run, step: step, stop_when: -> { !still_wanted?(run.id, pending) })
        return failed(run, pending, nil, "revision_failed", "the round's revision could not be computed: #{answer[:problem]}") if answer[:problem]
        dir = @round_dirs.ensure_round(run: run, round: pending["round"])
        return failed(run, pending, nil, dir[:code], dir[:problem]) if dir
        round = run.steps[pending["step"]]&.review || {}
        rerun = round["rerun"].is_a?(Array) ? {only: round["rerun"], rerun: round["reruns"]} : {}
        model = round_model(run, step)
        direct = WorkflowDefinition.direct_review?(run.definition, step)
        agent = review_agent(run, step)
        window = review_window(run, pending, agent, model)
        window = warm_or_cold(run, pending, window, agent) if window.is_a?(Hash) && window[:warm]
        return current(run) if window == :left
        return failed(run, pending, nil, "window_not_opened", "tmux could not open the review window") unless window
        # A window an earlier round left is cleared (`/clear`, as a `context: fresh` step is) as the line is typed.
        window[:fresh] = window[:carried]
        # Written once the window is known: one that started before the round is told its start-up git state is stale.
        written = @prompt.review_text(run, step, pending["attempt"], pending["round"], answer[:revision], **rerun,
          early_start: early_start(run, pending, window))
        unready = present_window(run, pending, window, agent)
        return unready if unready
        # The pane's binding is replaced, whichever round of the run it held.
        @panes.bind(workspace: workspace, pane: window[:pane], run_id: run.id, step: pending["step"], attempt: pending["attempt"],
          instructions: written["path"], artifacts: run.artifacts_dir, role: "reviewer", round: pending["round"], relative_to: run.worktree, direct: direct)
        recorded = record_pane(run, pending, window, answer[:revision], written, model: model, direct: direct)
        return recorded[:run] unless recorded[:wanted]
        # The reviewers start fresh, each told of its own earlier write-up by `review.previous`.
        kicked = true
        # A window opened ahead of the round (warm) has been in the daemon's rows for minutes: no wait for its row.
        kick = @panes.kick(workspace: workspace, pane: window[:pane], text: format(WorkflowDispatch::KICK, written["path"]), fresh: window[:fresh], run_id: run.id,
          opened: !(window[:reused] || window[:carried] || window[:warm]))
        # A window being cleared that refused the line (a person's turn running, no quiet in time) holds no reviewer of
        # this round: kept, still to be cleared, for the round's next delivery. A failure that does not prove the line
        # never went out (the daemon gave no answer) may have reviewers at work: typed.
        unless kick[:ok]
          typed = WorkflowTransitions::ROUND_MAY_HAVE_TYPED.include?(kick[:code].to_s)
          return failed(run, pending, window, kick[:code].to_s, TerminalText.escape(kick[:message]), close: !window[:fresh], typed: typed, refusal: WorkflowDispatch.refusal(kick))
        end
        delivered(run, pending, window, kick)
      rescue Workspace::Error, SystemCallError, EncodingError, IOError, Timeout::Error => e
        if e.is_a?(Workspace::Error) && e.code == "run_not_active"
          abandon(run, window) if window
          raise
        end
        failed(run, pending, window, e.respond_to?(:code) ? e.code : "error", e.message.lines.first.to_s.scrub.strip)
      rescue SignalException => e
        interrupted(run, pending, window, e, typed: kicked)
      end
    end

    # The one model the round's reviewers name: every reviewer of the step's `review:` names the same `model:`; nil when
    # any names none or they differ, which keeps the review window on its own model.
    def round_model(run, step)
      reviewers = WorkflowDefinition.reviewers(run.definition)
      models = Array(WorkflowDefinition.review(step)&.dig("from")).map { |name| reviewers.dig(name, "model") }.uniq
      (models.size == 1) ? models.first : nil
    end

    # The agent command with `--model MODEL` in place of any `--model` it already has; unchanged for no model.
    def with_model(agent, model)
      return agent unless model
      "#{agent.gsub(/\s--model(?:=|\s+)\S+/, "")} --model #{Shellwords.escape(model)}"
    end

    # A signal (an interrupt, a TERM) stops the delivery: the round is marked failed, so a resume or the sweep can
    # deliver it again rather than wait on a holder that is gone, and the signal goes on.
    def interrupted(run, pending, window, signal, typed: false)
      begin
        failed(run, pending, window, INTERRUPTED, "the delivering process was stopped by a signal (#{signal.message})", typed: typed)
      rescue => e
        @error_output.puts "Warning: could not record the interrupted review delivery of run #{run.id}: #{e.message}"
      end
      raise signal
    end

    # Waits for Claude Code in the window; nil once it is ready, else the run afterwards, its failure recorded.
    #
    # A window used again (a lapsed round's redelivery) may hold a reviewer still at work: the earlier delivery may
    # have typed its line, which nothing recorded tells apart from one that never went out (the binding and the pane
    # are recorded before the kick). So such a window is never closed by this delivery's own failure: the wait closes
    # nothing (`keep`), and a not-ready agent, a refused line or a failed write-back records the failure with the
    # window kept for the person ({#failed} +close+ false). A busy agent there is not typed into twice; whether such
    # a round is delivered again at all is T32's.
    def present_window(run, pending, window, agent)
      return nil if window[:ready]
      spawned = @readiness.await_ready(run.workspace, window[:pane], AGENT_KIND, window: window[:window], keep: window[:reused])
      spawned.ready? ? nil : not_ready(run, pending, window, spawned, agent)
    end

    # A warm window whose Claude Code is not ready (an update or sign-in screen, an agent that exited) is closed, and the
    # round goes on in one new window as a cold round does, so only that window's own readiness can fail the round. A wait
    # that raises counts as not ready. The wait closes nothing (`keep`): a round another process took over meanwhile
    # answers :left, its window left alone, and only a round still this delivery's has the window closed here.
    #
    # @return [Hash, Symbol, nil] the warm window, marked :ready (not waited on again); else the new window; :left; nil when tmux opened none
    def warm_or_cold(run, pending, window, agent)
      spawned = begin
        @readiness.await_ready(run.workspace, window[:pane], AGENT_KIND, window: window[:window], keep: true)
      rescue Workspace::Error, Timeout::Error
        nil
      end
      return window.merge(ready: true) if spawned&.ready?
      return :left unless still_wanted?(run.id, pending)
      # A window already gone is no failure: tmux's kill answers false.
      @tmux.kill_window(window[:window], timeout: WorkflowPanes::TMUX_READ_TIMEOUT)
      opened = open_review_window(@tmux.session_name_for(run.workspace), run, pending["step"], pending["round"], agent)
      opened && {pane: opened[:pane], window: opened[:window], reused: false, carried: false}
    end

    def not_ready(run, pending, window, spawned, agent)
      kept = (spawned.waiting || window[:reused]) ? window : nil
      message = "Claude Code in review window #{window[:window]} was not ready (#{spawned.ready.reason})"
      if spawned.waiting
        message += "; the window was kept at its #{spawned.waiting} screen"
      elsif kept
        message += "; the window, used again, was kept, since its agent may still be at work"
      elsif window[:carried]
        message += "; the window an earlier round left was closed, and the round's next delivery opens a new one"
      end
      message += "; a review window always runs Claude Code (#{agent}), whatever agent the main pane runs"
      program = program_of(agent)
      message += ", and #{program} is not on this process's PATH" if program && !installed?(program)
      failed(run, pending, kept, "agent_not_ready", message, close: false)
    end

    def program_of(command)
      Shellwords.split(command.to_s).first
    rescue ArgumentError
      nil
    end

    def installed?(program)
      program.include?("/") ? File.executable?(program) : !@which.call(program).nil?
    end

    # The step's warm window, opened ahead of this round ({#prewarm}) and still what it was opened as; else the window
    # marked for this round (left by a delivery of it that died), else the window an earlier round of the
    # same step left (a rejected or stopped round keeps its window for the next one): marked for this round and
    # carried over, its conversation cleared when the line is typed; else a new one. Windows marked for another round
    # of the run hold a reviewer of that round, and are closed (their reviewer unbound) only while this delivery still
    # owns the round: one taken over meanwhile answers :left and touches nothing.
    #
    # The warm case decides before the windows marked for this round are taken as `reused`: while the step holds a warm
    # slot for this round, or no delivery of the round has been made, a window with this round's mark is a warm one (its
    # slot maybe not yet written). One not adopted is closed, never reused: no line was ever typed into it.
    #
    # @return [Hash, Symbol, nil] :pane, :window, :reused, :carried and :warm (with :opened_at); :left; nil when tmux opened nothing
    def review_window(run, pending, agent, model = nil)
      session = @tmux.session_name_for(run.workspace)
      mark = WorkflowPanes.review_mark(run.id, pending["step"], pending["round"])
      listed = @tmux.review_windows(session, timeout: WorkflowPanes::TMUX_READ_TIMEOUT).select do |window|
        WorkflowPanes.parse_review_mark(window[:review])&.first == run.id
      end
      marked = listed.select { |window| window[:review] == mark }
      state = run.steps[pending["step"]]&.to_h || {}
      warm = stale = nil
      if warm_decides?(state, pending)
        warm = warm_window(run, state, pending, marked, model)
        stale = marked - [warm]
      end
      kept = nil
      others = []
      (listed - Array(stale) - [warm]).each do |window|
        (window[:review] == mark && kept.nil?) ? kept = window : others << window
      end
      return :left if (others.any? || stale&.any?) && !still_wanted?(run.id, pending)
      # Never bound, so nothing to unbind.
      Array(stale).each { |window| @tmux.kill_window(window[:window], timeout: WorkflowPanes::TMUX_READ_TIMEOUT) }
      carried = (kept || warm) ? nil : earlier_window(others, pending)
      # A window started on another model is not carried over: the round's reviewers must run the model it names.
      carried = nil if carried && state["review_model"] != model
      # One that can't be marked for this round is closed with the rest.
      carried = nil if carried && !@tmux.mark_review_window(carried[:window], mark)
      others.delete(carried) if carried
      others.each do |window|
        @tmux.kill_window(window[:window], timeout: WorkflowPanes::TMUX_READ_TIMEOUT)
        @panes.unbind(run.id, role: "reviewer", pane: window[:pane]) if window[:pane]
      end
      if warm
        opened_at = parse_time(state.dig("review_window", "opened_at"))
        return {pane: warm[:pane], window: warm[:window], reused: false, carried: false, warm: true, opened_at: opened_at || true}
      end
      # This round's own window that an earlier delivery carried over and never cleared holds no reviewer of the round:
      # it is carried again, not reused.
      if kept
        again = uncleared?(run, pending)
        return {pane: kept[:pane], window: kept[:window], reused: !again, carried: again}
      end
      # Not `reused`: no reviewer of this round can be at work in it, so a failure closes it as a new window's would
      # (an agent that exited there is never waited on again).
      return {pane: carried[:pane], window: carried[:window], reused: false, carried: true} if carried
      opened = open_review_window(session, run, pending["step"], pending["round"], agent)
      opened && {pane: opened[:pane], window: opened[:window], reused: false, carried: false}
    end

    # What the prompt is told of a window whose process started before it: a Time it started no later than, or true when
    # the run file gives none; nil for a window opened for this delivery. A warm window takes its slot's `opened_at`, the
    # time it opened; a window an earlier round left (carried) takes {#carried_start}; one this round's earlier delivery
    # left (reused) takes {#reused_start}.
    def early_start(run, pending, window)
      return window[:opened_at] if window[:warm]
      return carried_start(run, pending["step"], window[:window]) if window[:carried]
      reused_start(run, pending, window[:window]) if window[:reused]
    end

    # The run file records no open time for a window, only when its rounds' lines were typed (`kick_at`), and a kick
    # follows the open, so the earliest `kick_at` of the rounds delivered in that window is a bound the process started
    # no later than. `started_at` is not: a window is opened during a delivery, after the round's `started_at`. True when
    # no round of the window has a `kick_at`. Those of the step's earlier rounds are in `attempts[].rounds`.
    def carried_start(run, step_id, window_id)
      state = run.step(step_id)
      rows = state ? state.attempts.flat_map { |attempt| Array(attempt.rounds) } : []
      row_kicks(rows.select { |row| row.is_a?(Hash) && row["window"] == window_id }).min || true
    end

    # The same bound for a window this round's earlier delivery left: the earliest `kick_at` of this round's own records
    # in it (the deliveries it lapsed or failed, kept in the attempts) or of the round standing, if it is in that window.
    def reused_start(run, pending, window_id)
      state = run.step(pending["step"])
      rows = state ? state.attempts.flat_map { |attempt| Array(attempt.rounds) } : []
      rows << state.review if state&.review.is_a?(Hash)
      rows = rows.select { |row| row.is_a?(Hash) && row["round"] == pending["round"] && row["window"] == window_id }
      row_kicks(rows).min || true
    end

    def row_kicks(rows)
      rows.filter_map { |row| parse_time(row["kick_at"]) }
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # Whether the warm case decides this round's marked windows: the step's `review_window` is a warm slot for this round,
    # or no delivery of the round was made (none recorded a window, pane or record of it, nor delivered it again), so a
    # window with its mark can only be one {#prewarm} opened, its slot not yet written.
    def warm_decides?(state, pending)
      return true if warm_slot(state, pending)
      round = state["review"]
      return false unless round.is_a?(Hash) && round["redeliveries"].to_i.zero?
      return false if round.key?("window") || round.key?("pane") || Array(round["panes"]).any?
      Array(state["attempts"]).flat_map { |attempt| Array(attempt.is_a?(Hash) ? attempt["rounds"] : nil) }
        .none? { |row| row.is_a?(Hash) && row["round"] == pending["round"] }
    end

    def warm_slot(state, pending)
      slot = state["review_window"]
      slot if slot.is_a?(Hash) && slot["warm"] == true && slot["round"] == pending["round"]
    end

    # The marked window the step's warm slot names, if it is still what it was opened as: the same pane, the round's model
    # and the same start-up files ({#memory_digest}). Never bound or cleared, since only a delivery binds.
    def warm_window(run, state, pending, marked, model)
      slot = warm_slot(state, pending)
      return nil unless slot
      window = marked.find { |each| each[:window] == slot["window"] && each[:pane] && each[:pane] == slot["pane"] }
      return nil unless window && state["review_model"] == model
      window if slot["memory"] == memory_digest(run.worktree)
    end

    # The window of the newest earlier round of the same step, with a pane to type into.
    def earlier_window(windows, pending)
      windows.filter_map do |window|
        _, step, round = WorkflowPanes.parse_review_mark(window[:review])
        [round, window] if step == pending["step"] && round < pending["round"] && window[:pane]
      end.max_by(&:first)&.last
    end

    # Records the pane, window, revision, prompt and packs before the line is typed, so the review pane's Stop finds
    # the round's pane whenever it comes. A run that left the round meanwhile gets what was made taken back.
    #
    # @return [Hash] :wanted and :run (the run afterwards)
    def record_pane(run, pending, window, revision, written, model: nil, direct: false)
      moved = false
      wanted = false
      # Read before the lock is taken: no tmux call is made under the run's lock.
      server = server_pid(window[:pane])
      after = @change.call(run.id, actor: "engine", cause: "review_round") do |read|
        unless wanted?(read, pending)
          moved = !left_to_round?(read, pending, window)
          next
        end
        wanted = true
        hash = read.thawed
        state = hash["steps"][pending["step"]]
        round = state["review"]
        # The clear an earlier delivery made counts only in the window it cleared.
        round.delete("clear_from") unless round["window"] == window[:window]
        round.merge!("pane" => window[:pane], "window" => window[:window], "server_pid" => server,
          "revision" => revision, "prompt" => written["path"], "packs" => written["packs"], "kick_at" => @clock.call.utc.iso8601(3))
        # Every pane the round was delivered into: a verdict written in an earlier one still counts.
        round["panes"] = (Array(round["panes"]) + [window[:pane]]).uniq
        # A window being cleared ends the turn a person may have had in it; only a turn begun from the clear is the
        # round's (and, once the daemon says, from the confirmed clear, `cleared_at`). The earliest clear of the round
        # in that window stands: a line an earlier delivery typed after clearing may be the reviewers' turn. Until the
        # line is delivered the clear is owed (`uncleared`), so a kick and a write-back that both fail clear next time.
        round.delete("cleared_at")
        if window[:fresh]
          round["clear_from"] ||= @clock.call.utc.iso8601(3)
          round["uncleared"] = true
        end
        model ? round["model"] = model : round.delete("model")
        model ? state["review_model"] = model : state.delete("review_model")
        # A direct round ({WorkflowDefinition.direct_review?}) has its verdict written by the pane's main thread.
        direct ? round["direct"] = true : round.delete("direct")
        # The round records its window now; a window an earlier round kept is this one or gone.
        state.delete("review_window")
        WorkflowRun.from_h(hash)
      end
      abandon(run, window) if moved
      {wanted: wanted, run: after}
    end

    # Ends the round's delivery mark once its line was typed. A round that went on in this window by its own turn's
    # end (a Stop that came first), or that another process took over, is left as it is; a run that left the round
    # gets the window closed.
    def delivered(run, pending, window, kick = {})
      moved = false
      after = @change.call(run.id, actor: "engine", cause: "review_round") do |read|
        unless wanted?(read, pending)
          moved = !taken_over?(read, pending) && !ours_recorded?(read, pending, window)
          next
        end
        hash = read.thawed
        round = hash["steps"][pending["step"]]["review"]
        round["delivery"] = nil
        round["delivered_at"] = @clock.call.utc.iso8601(3)
        round.delete("failure")
        round.delete("uncleared")
        round["cleared_at"] = kick[:cleared_at] if window[:fresh] && kick[:cleared_at].is_a?(String)
        @change.event(hash, "review_delivered", pending.slice("step", "attempt", "round").merge("pane" => window[:pane], "window" => window[:window], "reused" => window[:reused])
          .merge(window[:fresh] ? {"cleared" => true} : {})
          .merge(window[:carried] ? {"carried" => true} : {})
          .merge(window[:warm] ? {"warm" => true} : {}))
        WorkflowRun.from_h(hash)
      end
      abandon(run, window) if moved
      after
    rescue Workspace::Error, SystemCallError => e
      if e.is_a?(Workspace::Error) && e.code == "run_not_active"
        abandon(run, window)
        return current(run)
      end
      # The line was typed: the reviewers may be at work, so the round is judged before it is delivered again.
      failed(run, pending, window, e.respond_to?(:code) ? e.code : "error", e.message.lines.first.to_s.scrub.strip, typed: true)
    end

    # A window the failure leaves: closed when the round is still this delivery's (unless +close+ is false, or the
    # window was used again, see {#present_window}: then kept, its id on the round) or the run left the round; kept when another process took the round's delivery over, since that one may have reused it, or
    # when the round went on in it. Its reviewer binding goes only with the window: a binding that stays routes the
    # round's Stop. A failure that can't be recorded closes the window it made, unless the round is another's or went on.
    #
    # A failure after the line may have gone out (+typed+) never closes the window and keeps the round's pane, with a
    # `delivered_at` of now: reviewers may be at work there, so their own Stop still decides the round.
    def failed(run, pending, window, code, message, close: true, typed: false, refusal: nil)
      close = false if (window && window[:reused]) || typed
      shut = close
      after = @change.call(run.id, actor: "engine", cause: "review_round") do |read|
        unless wanted?(read, pending)
          shut = !left_to_round?(read, pending, window)
          next
        end
        hash = read.thawed
        round = hash["steps"][pending["step"]]["review"]
        round["delivery"] = "failed"
        round["failure"] = {"code" => code, "message" => message, "at" => @clock.call.utc.iso8601}
        round["failure"]["typed"] = true if typed
        round["failure"].merge!(refusal.slice("reason", "seen")) if refusal
        # No turn of this delivery's is the round's: a Stop in its pane decides nothing. Unless the line may have been typed.
        if typed && window
          round["delivered_at"] ||= @clock.call.utc.iso8601(3)
        else
          round.delete("pane")
        end
        # A failure before any window was found leaves the window id an earlier delivery kept, so the sweep never takes it for an orphan.
        if window
          close ? round.delete("window") : round["window"] = window[:window]
          # A kept window that was to be cleared and was not: the next delivery into it clears it.
          round["uncleared"] = true if !close && window[:fresh]
        end
        @change.event(hash, "review_delivery_failed", pending.slice("step", "attempt", "round").merge("code" => code).merge(WorkflowDispatch.refusal_event_keys(refusal, except: %w[error message])))
        WorkflowRun.from_h(hash)
      end
      abandon(run, window) if window && shut
      after
    rescue Workspace::Error, SystemCallError
      abandon(run, window) if window && close && !left_to_round?(current(run), pending, window)
      current(run)
    end

    # Another process took the round over, or the round went on in this window (no longer waiting for the delivery,
    # with this window's pane on it): what the delivery made is the round's.
    def left_to_round?(run, pending, window)
      taken_over?(run, pending) || (!window.nil? && !wanted?(run, pending) && ours_recorded?(run, pending, window))
    end

    # The run left the round while it was delivered: nothing it made is anyone's.
    def abandon(run, window)
      unbind(run, window)
      @tmux.kill_window(window[:window], timeout: WorkflowPanes::TMUX_READ_TIMEOUT)
    end

    def unbind(run, window)
      @panes.unbind(run.id, role: "reviewer", pane: window[:pane]) if window && window[:pane]
    end

    # The tmux server the review pane is on, so the sweep can tell a restarted server (which may reuse the pane id)
    # from the same pane; nil when tmux can't say, which the sweep reads as not knowing what became of the pane.
    def server_pid(pane)
      @tmux.server_pid_for_pane(pane, timeout: WorkflowPanes::TMUX_READ_TIMEOUT)
    rescue SystemCallError, Timeout::Error
      nil
    end

    def current(run)
      @store.run(run.id)
    rescue Workspace::Error, SystemCallError
      run
    end

    # Whether a delivery of this round carried an earlier round's window over and left it uncleared ({#failed}).
    def uncleared?(run, pending)
      WorkflowRun.from_h(run).steps[pending["step"]]&.review&.dig("uncleared") == true
    end

    # The holder is this process: the same pid and the same start time, so a reused pid is not taken for it. A start
    # time that could not be read on either side (a `ps` that failed) leaves the pid alone to decide.
    def mine?(holder)
      me = @holder.call
      return false unless holder["pid"] == me["pid"]
      holder["started"].nil? || me["started"].nil? || holder["started"] == me["started"]
    end

    # Whether the run still waits for this delivery ({WorkflowTransitions.round_delivery_wanted?}), with the round's mark held
    # by this process or by none.
    def wanted?(run, pending)
      run = WorkflowRun.from_h(run)
      return false unless WorkflowTransitions.round_delivery_wanted?(run, pending)
      holder = run.steps[pending["step"]].review["holder"]
      !holder.is_a?(Hash) || mine?(holder)
    end

    # The same round, still delivering, but another process holds its mark now: that delivery owns the window.
    def taken_over?(run, pending)
      run = WorkflowRun.from_h(run)
      round = run.steps[pending["step"]]&.review
      !run.reason && run.current == pending["step"] && round.is_a?(Hash) && round["round"] == pending["round"] &&
        round["delivery"] == "delivering" && round["holder"].is_a?(Hash) && !mine?(round["holder"])
    end

    # The same step, attempt and round, with this delivery's pane on it: the round went on in this window (its Stop
    # came before the last change, and it was judged or stopped), so the window is the round's, not this delivery's.
    def ours_recorded?(run, pending, window)
      run = WorkflowRun.from_h(run)
      step = run.steps[pending["step"]]
      round = step&.review
      round.is_a?(Hash) && step.last_attempt&.n == pending["attempt"] && round["round"] == pending["round"] && round["pane"] == window[:pane]
    end

    # {#wanted?} read from the store, for the revision command; a run that can't be read is still wanted.
    def still_wanted?(run_id, pending)
      wanted?(@store.run(run_id), pending)
    rescue Workspace::Error, SystemCallError
      true
    end
  end
end
