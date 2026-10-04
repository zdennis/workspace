require "shellwords"

module Workspace
  module Commands
    # Brings back the coding-agent panes a reboot or a tmux restart took: reads
    # the session ledger, recreates each recorded agent pane that is gone
    # (however it was made, including one split by hand), and types
    # `claude --resume <session_id>` into it from the session's directory.
    #
    # A workspace whose tmux session is not running is launched first, through
    # the block given to {#call}. The panes its config gives a command are left
    # to the config; a pane that already runs an agent or another program is
    # never typed into. Pane bindings follow their slot to the pane that now
    # sits there.
    class Restore
      # A Claude Code session id. Anything else is never put on a command line:
      # `claude --resume` reads a value that is not an id as a search term.
      SESSION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

      # A pane showing one of these is at a prompt, so a command can be typed into it.
      SHELLS = %w[zsh bash fish sh dash ksh tcsh csh].freeze

      # SessionEnd reasons that still leave a session to restore. `other` is
      # what a closed terminal, a killed tmux server and a shutdown record;
      # every named reason (`prompt_input_exit`, `logout`, `clear`, ...) is the
      # user ending the session.
      RESUMABLE_END_REASONS = [nil, "other"].freeze

      # Flags of the workspace config's own `claude` pane that a resumed
      # session is started with too. Claude Code does not restore the
      # permission mode of a session that ran with it.
      CARRIED_FLAGS = %w[--dangerously-skip-permissions].freeze

      # Seconds to wait for a launched session to have the panes its config defines.
      PANE_WAIT = 10
      # Seconds between looks at a launched session's panes.
      PANE_POLL = 0.25

      # One pane of a tmux layout string: `WxH,X,Y,ID`.
      LAYOUT_CELL = /\d+x\d+,\d+,\d+,\d+/
      private_constant :LAYOUT_CELL

      SLOT = /\A(.+):(\d+)\.(\d+)\z/
      private_constant :SLOT

      # @param ledger [Workspace::SessionLedger] the recorded sessions
      # @param tmux [Workspace::Tmux] tmux session and pane operations
      # @param pane_bindings [Workspace::PaneBindings] bindings to move to recreated panes
      # @param tmuxinator_report [Workspace::TmuxinatorReport] reads the panes a workspace's config defines
      # @param process_tree [Workspace::ProcessTree] tells a pane running an agent from one at a prompt
      # @param agent_ensurer [Workspace::Commands::EnsureAgent, nil] starts the agent daemon of a session
      #   that is running without one, so the resumed sessions are monitored; nil starts none
      # @param sleeper [#call] sleeps the given seconds, injected for fast tests
      # @param clock [#call] monotonic seconds, bounding the wait for a launched session's panes
      # @param output [IO] output stream for the plan and the results
      # @param error_output [IO] error output stream for warnings
      def initialize(ledger:, tmux:, pane_bindings:, tmuxinator_report:, process_tree:, agent_ensurer: nil,
        sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        output: $stdout, error_output: $stderr)
        @ledger = ledger
        @tmux = tmux
        @pane_bindings = pane_bindings
        @tmuxinator_report = tmuxinator_report
        @process_tree = process_tree
        @agent_ensurer = agent_ensurer
        @sleeper = sleeper
        @clock = clock
        @output = output
        @error_output = error_output
      end

      # Restores the given workspaces' agent panes, or with +dry_run+ reports
      # what it would do and changes nothing.
      #
      # @param workspaces [Array<String>] workspace names
      # @param dry_run [Boolean] only report; never launch, split, type or rebind
      # @yieldparam missing [Array<String>] workspaces whose tmux session is not
      #   running and must be launched before their panes can be restored
      # @yieldreturn [Hash{String=>String}] workspace => why it could not be launched
      # @return [Hash] +:exit_code+ (1 when any row failed), +:results+ (one row
      #   per workspace launched and per recorded pane slot), +:warnings+,
      #   +:status+ ("dry_run" for a dry run) and +:extra+ (`dry_run`, `unmatched`)
      # @raise [Workspace::Error] if tmux or the ledger can't be read; nothing has been changed by then
      def call(workspaces, dry_run: false)
        @warnings = []
        running = @tmux.sessions(strict: true)
        plans = workspaces.map { |name| plan_for(name, running) }

        if dry_run
          rows = plans.flat_map { |plan| preview(plan) }
        else
          missing = plans.select { |plan| plan[:launch] && plan[:config] }.map { |plan| plan[:workspace] }
          failures = missing.empty? ? {} : launch(missing) { |names| yield(names) if block_given? }
          plans.each { |plan| prepare(plan, failures[plan[:workspace]]) }
          rebound = rebind(plans)
          rows = plans.flat_map { |plan| finish(plan, rebound) }
        end

        print_rows(rows, dry_run)
        failed = rows.any? { |row| row["outcome"] == "failed" }
        result = {exit_code: failed ? 1 : 0, results: rows, warnings: @warnings,
                  extra: {"dry_run" => dry_run, "unmatched" => unmatched_slots(rows)}}
        result[:status] = "dry_run" if dry_run
        result
      end

      private

      def launch(missing)
        failures = yield(missing)
        failures.is_a?(Hash) ? failures : missing.to_h { |name| [name, "Its tmux session is not running and nothing was given to launch it."] }
      end

      def plan_for(name, running)
        session = @tmux.session_name_for(name)
        {workspace: name, session: session, launch: !running.include?(session), config: config_for(name), slots: slots_for(name, session)}
      end

      # The hook records a pane under its tmux session's name, which for a
      # worktree workspace differs from the workspace's. Only slots of the
      # workspace's own session are kept.
      def slots_for(name, session)
        @ledger.slots_for(name, session).filter_map do |record|
          match = SLOT.match(record["pane_slot"].to_s)
          record.merge(window: match[2].to_i, index: match[3].to_i) if match && match[1] == session
        end.sort_by { |slot| [slot[:window], slot[:index]] }
      rescue SystemCallError => e
        raise Workspace::Error, "Can't read the session ledger: #{e.message}"
      end

      # What each pane of each window in the workspace's config is (`shell`
      # for one with no command), and the flags a resumed session is started
      # with. Nil when there is no config.
      def config_for(name)
        windows = @tmuxinator_report.show(name)["windows"]
        claude = windows.flat_map { |window| window["panes"] }.find { |pane| pane["kind"] == "claude" }
        {kinds: windows.map { |window| window["panes"].map { |pane| pane["kind"] } }, flags: Array(claude && claude["flags"]) & CARRIED_FLAGS}
      rescue Workspace::Error
        nil
      end

      NO_CONFIG = "It has no tmuxinator config, so its session can't be launched."
      private_constant :NO_CONFIG

      # -- dry run --

      def preview(plan)
        if plan[:launch] && plan[:config].nil?
          return [workspace_row(plan, "unmatched", "no_config", NO_CONFIG)] + not_launched(plan).map { |decision| slot_row(plan, decision) }
        end

        windows = plan[:launch] ? config_windows(plan) : live_windows(plan[:session])
        rows = plan[:launch] ? [workspace_row(plan, "would_launch", nil, "The tmux session is not running; restore launches it first.")] : []
        rows + decide(plan, windows).map do |decision|
          next slot_row(plan, decision) unless decision[:action] == :resume

          slot_row(plan, decision.merge(outcome: "would_restore", message: resume_message(decision, "Would resume")))
        end
      end

      # -- restore --

      # Launch outcome, daemon, panes: everything up to the point where
      # bindings move and commands are typed. Leaves +:head+ rows and
      # +:decisions+ on the plan.
      def prepare(plan, launch_failure)
        plan[:head] = []
        if plan[:launch]
          problem = plan[:config].nil? ? ["no_config", NO_CONFIG] : (launch_failure && ["launch_failed", launch_failure.to_s])
          if problem
            plan[:head] << workspace_row(plan, "failed", *problem)
            return plan[:decisions] = not_launched(plan)
          end
          plan[:head] << workspace_row(plan, "launched", nil, nil)
          wait_for_config_panes(plan)
        else
          ensure_agent(plan)
        end

        windows = live_windows(plan[:session])
        plan[:decisions] = decide(plan, windows)
        create_panes(plan, plan[:decisions], windows)
        locate_panes(plan, plan[:decisions])
      end

      def finish(plan, rebound)
        plan[:head] + plan[:decisions].map do |decision|
          decision = resume(plan, decision) if decision[:action] == :resume
          slot_row(plan, decision.merge(rebound: rebound.key?(decision[:pane_id])))
        end
      end

      # A launch starts the workspace's agent daemon; a session that was
      # already running may have lost its own.
      def ensure_agent(plan)
        return unless @agent_ensurer

        result = @agent_ensurer.call(name: plan[:workspace])
        return if result.ok? || result.status == :invalid_config

        warn_once("#{plan[:workspace]}: could not start its agent daemon: #{result.detail}")
      end

      # A session tmuxinator has just started still gets its panes one at a
      # time; splitting before they all exist would put a restored pane among them.
      def wait_for_config_panes(plan)
        expected = plan[:config][:kinds].sum(&:size)
        deadline = @clock.call + PANE_WAIT
        until @tmux.pane_details(plan[:session], window: nil).size >= expected
          if @clock.call >= deadline
            warn_once("#{plan[:workspace]}: its session still has fewer panes than its config defines after #{PANE_WAIT}s.")
            break
          end
          @sleeper.call(PANE_POLL)
        end
      end

      # -- what happens to each slot --

      def live_windows(session)
        @tmux.pane_details(session, window: nil).group_by { |pane| pane[:window] }
      end

      # A session that isn't running has the panes its config defines, once launched.
      def config_windows(plan)
        plan[:config][:kinds].each_with_index.to_h { |kinds, window| [window, kinds.each_index.map { |index| {window: window, index: index} }] }
      end

      def decide(plan, windows)
        live = windows.values.flatten.select { |pane| pane[:id] }
        tree = live.empty? ? nil : process_snapshot
        server = (@tmux.server_pid_for_pane(live.first[:id]) unless plan[:launch] || live.empty?)
        decisions = plan[:slots].map do |slot|
          base = {slot: slot, window: slot[:window], index: slot[:index]}
          base.merge(precheck(slot) || (plan[:launch] ? decide_launched(plan, slot, windows, tree) : decide_running(slot, windows, tree, server)))
        end
        decisions.select { |d| d[:action] == :resume && d[:pane].nil? }.group_by { |d| d[:window] }.each do |window, creates|
          place(creates, windows.fetch(window))
        end
        decisions
      end

      # What rules a slot out whatever the session looks like.
      def precheck(slot)
        return skip("ended", "The session ended (#{slot["end_reason"]}).") unless RESUMABLE_END_REASONS.include?(slot["end_reason"])
        return unmatched("no_session_id", "The ledger has no usable session id for this pane.") unless slot["session_id"].to_s.match?(SESSION_ID)
        return unmatched("cwd_missing", "The session's directory is gone: #{slot["cwd"].inspect}.") unless slot["cwd"].is_a?(String) && File.directory?(slot["cwd"])
        return unmatched("transcript_missing", "Claude Code no longer has the conversation: #{slot["transcript_path"]} is gone.") if slot["transcript_path"].is_a?(String) && !File.exist?(slot["transcript_path"])

        nil
      end

      def not_launched(plan)
        plan[:slots].map do |slot|
          {slot: slot, window: slot[:window], index: slot[:index]}
            .merge(precheck(slot) || unmatched("not_launched", "The workspace's session was not launched."))
        end
      end

      # In a session restore launched, only a pane the config gives a command
      # is the config's business (see {#config_kind} for which pane is which). A plain shell pane is resumed in place, like
      # one in a running session.
      def decide_launched(plan, slot, windows, tree)
        panes = windows[slot[:window]]
        return unmatched("no_window", "Window #{slot[:window]} is not in the session.") unless panes

        pane = panes.find { |candidate| candidate[:index] == slot[:index] }
        return {action: :resume, pane: nil, rebind: true} unless pane

        kind = config_kind(plan, slot, windows, panes)
        return skip("config_pane", "The workspace's config starts this pane.").merge(pane: pane, rebind: true) unless kind == "shell"
        return {action: :resume, placement: "existing", pane: pane, rebind: true} unless pane[:id]

        decision = occupancy(pane, tree)
        decision.merge(pane: pane, rebind: decision[:action] == :resume)
      end

      # The config's panes are paired with the live ones by order, not by
      # number: with tmux's `base-index` or `pane-base-index` set, the first
      # window or pane is not 0.
      def config_kind(plan, slot, windows, panes)
        window = windows.keys.sort.index(slot[:window])
        pane = panes.map { |candidate| candidate[:index] }.sort.index(slot[:index])
        plan[:config][:kinds].dig(window, pane)
      end

      # In a session that was already running, a pane id recorded under the
      # tmux server that is still running names the pane itself, wherever its
      # index is now: closing a sibling renumbers panes and no hook fires. An
      # entry from another server is matched by its index, since pane ids start
      # over. An entry with no server recorded can't be told apart, so an agent
      # found where it points is never taken for the slot's own.
      def decide_running(slot, windows, tree, server)
        own = windows.values.flatten.find { |pane| pane[:id] == slot["pane_id"] }
        recorded = slot["tmux_server"]
        if server && recorded == server && own
          decision = occupancy(own, tree)
          return decision.merge(pane: own, window: own[:window], index: own[:index], rebind: decision[:action] == :resume)
        end

        panes = windows[slot[:window]]
        return unmatched("no_window", "Window #{slot[:window]} is not in the session.") unless panes
        return {action: :resume, pane: nil, rebind: true} if server && recorded == server

        unknown_server = recorded.nil? || server.nil?
        return ambiguous(own) if unknown_server && own && occupancy(own, tree)[:reason] == "agent_running"

        pane = panes.find { |candidate| candidate[:index] == slot[:index] }
        return {action: :resume, pane: nil, rebind: true} unless pane

        decision = occupancy(pane, tree)
        return ambiguous(pane) if unknown_server && decision[:reason] == "agent_running"

        decision.merge(pane: pane, rebind: %i[resume skip].include?(decision[:action]))
      end

      def ambiguous(pane)
        unmatched("pane_ambiguous", "A coding agent runs in pane #{pane[:id]}, and the ledger entry is too old to tell whether it is this session.")
      end

      def occupancy(pane, tree)
        return unmatched("pane_unknown", "Could not tell what the pane is running.") unless tree
        return skip("agent_running", "A coding agent is already running in the pane.") if AgentProvider.detect(command: pane[:command], pid: pane[:pid], tree: tree)
        return {action: :resume, placement: "existing"} if SHELLS.include?(File.basename(pane[:command].to_s).delete_prefix("-"))

        unmatched("pane_busy", "The pane is running #{pane[:command]}.")
      end

      def skip(reason, message) = {action: :skip, outcome: "skipped", reason: reason, message: message}

      def unmatched(reason, message) = {action: :unmatched, outcome: "unmatched", reason: reason, message: message}

      def process_snapshot
        @process_tree.snapshot
      rescue Workspace::Error => e
        warn_once("Could not read the process table (#{e.message}); panes that exist are left alone.")
        nil
      end

      # Gives each pane to create the index it will get. With a recorded
      # layout that has more panes than the window, the window is grown to
      # the layout's pane count and a slot inside it keeps its index
      # ("exact"); any other pane is added after the last one ("appended").
      def place(creates, panes)
        layout = creates.select { |d| d[:slot]["layout"] }.max_by { |d| d[:slot]["at"].to_s }&.dig(:slot, "layout")
        grow = [cells(layout) - panes.size, 0].max
        first_new = (panes.map { |pane| pane[:index] }.max || -1) + 1
        grown = (first_new...(first_new + grow)).to_a
        next_index = first_new + grow
        creates.each do |decision|
          if grown.include?(decision[:slot][:index])
            decision.merge!(placement: "exact", index: decision[:slot][:index], layout: layout, grow: grow)
          else
            decision.merge!(placement: "appended", index: next_index, layout: (layout if grow > 0), grow: grow)
            next_index += 1
          end
        end
      end

      def cells(layout)
        layout.to_s.scan(LAYOUT_CELL).size
      end

      # -- changing tmux --

      def create_panes(plan, decisions, windows)
        decisions.select { |d| d[:action] == :resume && d[:pane].nil? }.group_by { |d| d[:window] }.each do |window, creates|
          last = windows.fetch(window).map { |pane| pane[:index] }.max
          made = []
          creates.first[:grow].times do
            index = split(plan, window, last)
            break unless index

            made << (last = index)
          end
          apply_layout(plan, window, creates.first, made)
          creates.each do |decision|
            next if decision[:placement] == "exact" && made.include?(decision[:index])

            index = (split(plan, window, last) if decision[:placement] == "appended")
            if index
              decision[:index] = last = index
            else
              decision.merge!(action: :failed, outcome: "failed", reason: "split_failed", index: nil, placement: nil,
                message: "tmux could not split window #{window} to make the pane.")
            end
          end
        end
      end

      # Splits the window's last pane. Each split halves that pane, so a small
      # window runs out of room ("no space for a new pane") while the window as
      # a whole still has it: the window is tiled once and the split tried again.
      def split(plan, window, last)
        index = @tmux.split_window(plan[:session], window: window.to_s, pane: last)
        return index if index
        return nil unless @tmux.apply_layout(plan[:session], "tiled", window: window.to_s)

        warn_once("#{plan[:workspace]}: window #{window} was tiled to make room for a restored pane.")
        @tmux.split_window(plan[:session], window: window.to_s, pane: last)
      end

      def apply_layout(plan, window, decision, made)
        return if decision[:grow].zero?
        return if made.size == decision[:grow] && @tmux.apply_layout(plan[:session], decision[:layout], window: window.to_s)

        warn_once("#{plan[:workspace]}: the recorded layout of window #{window} could not be applied; the new panes keep the size tmux gave them.")
      end

      # Reads the pane id now sitting at each slot that has a pane.
      def locate_panes(plan, decisions)
        live = @tmux.pane_details(plan[:session], window: nil)
        decisions.each do |decision|
          next decision[:pane_id] = decision[:pane][:id] if decision[:pane]
          next unless decision[:action] == :resume

          pane = live.find { |candidate| candidate[:window] == decision[:window] && candidate[:index] == decision[:index] }
          next decision[:pane_id] = pane[:id] if pane

          decision.merge!(action: :failed, outcome: "failed", reason: "pane_not_found", placement: nil,
            message: "The pane could not be found after it was made.")
        end
      end

      # A binding follows its slot to the pane that sits there now. Every
      # workspace's moves go in one write, so a new pane that got the old id of
      # another workspace's bound pane can't replace that binding, and they go
      # before anything is typed, so a resumed session's SessionStart hook finds its own.
      def rebind(plans)
        moves = plans.flat_map do |plan|
          plan[:decisions].filter_map do |decision|
            from = decision[:slot]["pane_id"]
            to = decision[:pane_id]
            next unless decision[:rebind] && decision[:action] != :failed && from.is_a?(String) && to

            to_slot = "#{plan[:session]}:#{decision[:window]}.#{decision[:index]}"
            next if from == to && to_slot == decision[:slot]["pane_slot"]

            {from: from, to: to, session: plan[:session], from_slot: decision[:slot]["pane_slot"], to_slot: to_slot}
          end
        end
        @pane_bindings.move(moves)
      rescue => e
        warn_once("Pane bindings were not moved (#{e.class}: #{e.message}).")
        {}
      end

      def resume(plan, decision)
        delivery = @tmux.deliver(plan[:session], decision[:pane_id], resume_command(plan, decision[:slot]))
        unless delivery.landed?
          return decision.merge(outcome: "failed", reason: "not_delivered", message: delivery.message)
        end

        warn_once("#{decision[:slot]["pane_slot"]}: #{delivery.message}") unless delivery.ok?
        decision.merge(outcome: "restored", message: resume_message(decision, "Resumed"))
      end

      def resume_command(plan, slot)
        words = ["claude", *plan[:config]&.fetch(:flags), "--resume", slot["session_id"]]
        "cd -- #{Shellwords.escape(slot["cwd"])} && #{words.join(" ")}"
      end

      def resume_message(decision, verb)
        where = {"existing" => "in its pane", "exact" => "in a new pane at this slot",
                 "appended" => "in a new pane at index #{decision[:index]}"}.fetch(decision[:placement])
        "#{verb} session #{decision[:slot]["session_id"]} #{where}."
      end

      # -- rows and text --

      def workspace_row(plan, outcome, reason, message)
        blank_row(plan).merge("kind" => "workspace", "outcome" => outcome, "reason" => reason, "message" => message)
      end

      def slot_row(plan, decision)
        slot = decision[:slot]
        restored_slot = ("#{plan[:session]}:#{decision[:window]}.#{decision[:index]}" if decision[:placement])
        blank_row(plan).merge("kind" => "pane", "outcome" => decision[:outcome], "reason" => decision[:reason],
          "message" => decision[:message], "slot" => slot["pane_slot"], "session_id" => slot["session_id"], "cwd" => slot["cwd"],
          "pane" => decision[:pane_id], "restored_slot" => restored_slot, "placement" => decision[:placement],
          "rebound" => decision[:rebound] == true)
      end

      def blank_row(plan)
        {"workspace" => plan[:workspace], "kind" => nil, "outcome" => nil, "reason" => nil, "message" => nil, "slot" => nil,
         "session_id" => nil, "cwd" => nil, "pane" => nil, "restored_slot" => nil, "placement" => nil, "rebound" => false}
      end

      def unmatched_slots(rows)
        rows.select { |row| row["outcome"] == "unmatched" }.map { |row| row.slice("workspace", "slot", "reason") }
      end

      def print_rows(rows, dry_run)
        if rows.empty?
          @output.puts "Nothing to restore: the ledger has no agent panes for #{dry_run ? "these workspaces" : "them"}."
          return
        end
        rows.each do |row|
          label = (row["kind"] == "workspace") ? row["workspace"] : "  #{row["slot"]}"
          line = "#{label}: #{row["outcome"].tr("_", " ")}"
          line += " (#{row["reason"].tr("_", " ")})" if row["reason"]
          line += " - #{row["message"]}" if row["message"]
          line += " Its binding moved with it." if row["rebound"]
          @output.puts line
        end
        missed = rows.count { |row| row["outcome"] == "unmatched" }
        @output.puts "#{missed} recorded pane#{"s" unless missed == 1} could not be matched." if missed > 0
      end

      def warn_once(message)
        return if @warnings.include?(message)

        @warnings << message
        @error_output.puts "Warning: #{message}"
      end
    end
  end
end
