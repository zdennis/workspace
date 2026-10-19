module Workspace
  module Commands
    # `workspace plan start`: gets an agent working on a plan, or on one task of it, and presses the
    # interrupt key for `plan pause --interrupt`. `start` launches the workspace, or types into its
    # main agent pane, and records that pane as `owner_pane`. `start --task` sends that one task to a
    # pane (named, new, or the main one) and writes the pane onto the task line as its owner
    # ({PlanFile.set_task}). {#interrupt_owners} presses the agent's own interrupt key
    # ({AgentProvider#interrupt_keys}) in each owner pane that works. Reading and the other writes are
    # {Commands::Plan}'s.
    class PlanDispatch
      # The built-in play `start` points the agent at.
      PLAY = "implementation-plan"

      # The line `start` gives the agent after the play.
      CONTINUE_PROMPT = "Continue the plan."

      # The line `start` gives the agent after the play when the plan has no tasks yet, and `start --plan`
      # for a new plan: the agent writes the task list, then stops for the person to read it.
      DRAFT_PROMPT = "The plan has no tasks yet. Draft them as the play's \"Draft the tasks\" section says, then end your turn. " \
        "Do not start any task."

      # The agent kinds a task may be sent to, and `--spawn` may start: every {AgentProvider}.
      AGENT_KINDS = PaneDispatch::AGENT_KINDS

      # @param task_id [String]
      # @return [String] the line `start --task` gives the agent after the play
      def self.task_prompt(task_id)
        "Work on plan task #{task_id} only. Do not take other tasks; end your turn when it is done or blocked."
      end

      # @param access [Workspace::PlanAccess] finds the plan and writes its status
      # @param panes [Workspace::PaneDispatch] reads, picks, spawns, types into and binds the panes
      # @param library [Workspace::Library] finds the built-in play and words its prompt
      # @param output [IO] output stream
      def initialize(access:, panes:, library:, output: $stdout)
        @access = access
        @panes = panes
        @library = library
        @output = output
      end

      # Sets `status: active` and gets an agent working on the plan: a workspace with no session is
      # launched with the play and {CONTINUE_PROMPT}; one with a session gets the same text typed into
      # its main agent pane, which is bound to the play. A pane that is working is left alone.
      # The pane the agent is in is recorded as `owner_pane` (the plan never reads `working` without one).
      # A plan with no tasks gets {DRAFT_PROMPT} in place of {CONTINUE_PROMPT}, so the agent drafts the
      # tasks; the outcome is then `drafting` in place of `launched` or `sent`.
      #
      # @param name [String] the workspace
      # @param launch [#call] given the workspace name, launches it with the play and prompt and returns
      #   `{ok:, reason:, message:, pane:}` (the CLI supplies it, since launching is its job)
      # @return [Hash] the row: `outcome` `launched`, `sent`, `drafting` (the plan has no tasks), `already_working`, or `failed` when the launch could not
      #   send its prompt (`reason` and `message` say why); `pane` is the pane the agent is in, when known
      # @raise [Workspace::Error] `no_plan`, `plan_done`, `notes_dir_unwritable`, `plan_write_conflict`; with a session,
      #   `no_daemon`, `no_agent_pane`, `pane_busy` (the pane waits on a person), and the codes of {Workspace::Commands::Send#deliver}
      def start(name:, launch:)
        file, plan = @access.require_plan(name)
        raise @access.plan_done(name, file) if @access.finished?(plan)
        live = @access.session_live?(name, {})
        @access.write_status(name, file, "active")
        (live == false) ? start_by_launch(name, file, plan, launch) : start_in_pane(name, file, plan)
      end

      # Sends one task to one pane and sets `status: active` once it is not refused: the pane named, a new agent pane, the
      # task's owner when the agent daemon lists it as a coding-agent pane, else the main agent pane (as
      # {#start}). A workspace with no session is launched, unless a pane or a spawn was asked for.
      # Once the task is typed, the pane is bound to the play with the task as its focus, and is
      # written onto the task line as its owner; a `[ ]` task becomes `[~]`.
      #
      # @param name [String] the workspace
      # @param task_id [String] the task's id
      # @param launch [#call] as for {#start}, called with the workspace and the task's prompt
      # @param pane [String, nil] a pane id or `window.pane` of the workspace's session
      # @param spawn [String, nil] one of {AGENT_KINDS}: split a new pane and start that agent in it
      # @return [Hash] the row: `outcome` `sent`, `spawned`, `launched`, `already_working` (the task's own
      #   owner pane works), or `failed` (`reason` `prompt_not_sent` when a new agent was not ready, with its `pane`);
      #   `task` is the id; `pane` the pane the task went to
      # @raise [Workspace::Error] `no_plan`, `plan_done`, `unknown_task`, `task_done` (done or skipped), `task_owned` (its
      #   owner pane works and another pane was named), `no_session` (with a pane or a spawn), `pane_busy` (the pane works
      #   on something else or waits on a person), `no_agent_pane`, `no_daemon`, the {Workspace::PaneLocator} codes,
      #   and the codes of {Workspace::Commands::Send#deliver}
      def start_task(name:, task_id:, launch:, pane: nil, spawn: nil)
        raise ArgumentError, "give pane: or spawn:, not both" if pane && spawn
        raise ArgumentError, "unknown agent kind #{spawn.inspect}" if spawn && !AGENT_KINDS.include?(spawn)
        file, plan = @access.require_plan(name)
        raise @access.plan_done(name, file) if @access.finished?(plan)
        task = plan.tasks.find { |candidate| candidate.id == task_id } || raise(PlanFile.unknown_task(file, task_id))
        raise task_done(name, file, task) if %w[done skipped].include?(task.state)
        live = @access.session_live?(name, {})
        raise no_session(name) if live == false && (pane || spawn)
        return task_by_launch(name, file, task, launch) if live == false
        spawn ? task_by_spawn(name, file, task, spawn) : task_in_pane(name, file, plan, task, pane)
      end

      # Presses the agent's interrupt keys ({AgentProvider#interrupt_keys}) in each owner pane that works: the
      # plan's `owner_pane` and the owners of the tasks still left. A pane that is idle or waiting gets nothing.
      #
      # @param name [String] the workspace
      # @param plan [PlanFile] the plan
      # @return [Array(Array<Hash>, Array<Hash>)] the interrupt rows (`{pane, kind, outcome, message}`) and the warnings (`no_daemon`)
      def interrupt_owners(name, plan)
        left = plan.tasks.select { |task| PlanState::LEFT_STATES.include?(task.state) }
        owners = [plan.owner_pane, *left.map(&:owner)].compact.uniq
        return [[], []] if owners.empty?
        panes = begin
          @panes.panes(name)
        rescue Workspace::Error => e
          @output.puts "Could not read the panes to interrupt them: #{e.message}"
          return [[], [{"code" => "no_daemon", "message" => e.message}]]
        end
        [owners.map { |id| interrupt_pane(name, id, panes.find { |candidate| candidate["pane_id"] == id }) }, []]
      end

      private

      def task_done(name, file, task)
        Workspace::Error.new("Task #{task.id} of the plan for '#{name}' is #{task.state}, so there is nothing to start. Edit #{file} to reopen it.",
          code: "task_done", details: {"name" => name, "path" => file, "task" => task.id, "state" => task.state})
      end

      def no_session(name)
        Workspace::Error.new("No active tmux session for '#{name}'.\nRun 'workspace launch #{name}' to start it, or leave out --pane and --spawn.",
          code: "no_session", details: {"workspace" => name})
      end

      # The status is written only once nothing is left to refuse, and before the agent is told, so
      # it never reads `paused` and stops; a refused task leaves the plan as it was.
      def task_by_launch(name, file, task, launch)
        @access.write_status(name, file, "active")
        result = launch.call(name, self.class.task_prompt(task.id))
        return task_row("failed", file, task, reason: result[:reason], message: result[:message]) unless result[:ok]
        note = record_task_owner(name, file, task, result[:pane])
        @output.puts "Started task #{task.id} of the plan for #{name}: launched it with the #{PLAY} play."
        @output.puts note if note
        task_row("launched", file, task, pane: result[:pane], message: note)
      end

      def task_in_pane(name, file, plan, task, named)
        panes = @panes.panes(name)
        owner = task.owner && panes.find { |candidate| candidate["pane_id"] == task.owner }
        target = if named
          @panes.named(name, named, panes)
        else
          (owner if owner && AGENT_KINDS.include?(owner["kind"])) || main_pane(name, plan, panes)
        end
        id = target["pane_id"]
        if owner && owner["state"] == "working" && owner["pane_id"] != id
          raise Workspace::Error.new("Task #{task.id} of '#{name}' is being worked on in pane #{owner["pane_id"]}, so it was not sent to #{id}. " \
            "Pause that pane first, or send the task there.", code: "task_owned", details: {"workspace" => name, "task" => task.id, "owner" => owner["pane_id"]})
        end
        @panes.require_agent(name, target, "task")
        if target["state"] == "working" && task.owner == id
          @access.write_status(name, file, "active")
          @output.puts "Task #{task.id} of the plan for #{name} is already being worked on in pane #{id}."
          return task_row("already_working", file, task, pane: id)
        end
        @panes.refuse_busy(name, target, "task")
        deliver_task(name, file, task, id, "sent")
      end

      def task_by_spawn(name, file, task, kind)
        if task.owner
          owner = @panes.panes(name).find { |candidate| candidate["pane_id"] == task.owner }
          if owner && owner["state"] == "working"
            raise Workspace::Error.new("Task #{task.id} of '#{name}' is being worked on in pane #{task.owner}, so no new agent was started. Pause that pane first.",
              code: "task_owned", details: {"workspace" => name, "task" => task.id, "owner" => task.owner})
          end
        end
        spawned = @panes.spawn(name, kind)
        unless spawned.ready?
          message = "Started #{spawned.label} in new pane #{spawned.pane}, but it was not ready for the task in #{@panes.prompt_timeout}s " \
            "(#{spawned.ready.reason}); nothing was typed."
          return task_row("failed", file, task, reason: "prompt_not_sent", message: message, pane: spawned.pane)
        end
        deliver_task(name, file, task, spawned.pane, "spawned")
      end

      def deliver_task(name, file, task, id, outcome)
        @access.write_status(name, file, "active")
        play = @library.pack(PLAY, cwd: nil).first
        @panes.deliver(name, id, body: @library.play_prompt(play, self.class.task_prompt(task.id)))
        notes = [@panes.bind_play(name, id, play, focus: "plan task #{task.id}"), record_task_owner(name, file, task, id)].compact
        @output.puts "Started task #{task.id} of the plan for #{name}: sent it to #{(outcome == "spawned") ? "new pane" : "pane"} #{id}."
        notes.each { |note| @output.puts note }
        task_row(outcome, file, task, pane: id, message: notes.empty? ? nil : notes.join(" "))
      end

      def task_row(outcome, file, task, **fields)
        @access.row(outcome, file, **fields).merge("task" => task.id)
      end

      # Writes the pane onto the task line as its owner, and takes a task to do to in progress.
      # @return [String, nil] a note when the line could not be written
      def record_task_owner(name, file, task, pane)
        return if pane.nil?
        # Read again: the agent may have taken the task to another state since the plan was read.
        current = PlanFile.read(file)&.tasks&.find { |candidate| candidate.id == task.id }
        changed = PlanFile.set_task(file, task.id, owner: pane, state: (current&.state == "todo") ? "in_progress" : nil)
        @access.record_change(name, "active") if changed
        nil
      rescue Workspace::Error, SystemCallError => e
        "Could not record the owner on task #{task.id} (#{e.message}); add <!-- owner: #{pane} --> to its line."
      end

      def interrupt_pane(name, id, pane)
        entry = {"pane" => id, "kind" => pane && pane["kind"], "outcome" => nil, "message" => nil}
        return entry.merge("outcome" => "gone") unless pane
        return entry.merge("outcome" => "not_working") unless pane["state"] == "working"
        keys = AgentProvider.find(pane["kind"].to_s)&.interrupt_keys.to_a
        if keys.empty?
          @output.puts "Pane #{id} works, but workspace knows no interrupt key for #{pane["kind"] || "its agent"}; it stops before its next task."
          return entry.merge("outcome" => "unsupported")
        end
        @panes.deliver(name, id, keys: keys)
        @output.puts "Interrupted pane #{id} (#{keys.join(" ")})."
        entry.merge("outcome" => "sent")
      rescue Workspace::Error => e
        @output.puts "Could not interrupt pane #{id}: #{e.message}"
        entry.merge("outcome" => "failed", "message" => e.message)
      end

      def start_by_launch(name, file, plan, launch)
        drafting = plan.tasks.empty?
        result = drafting ? launch.call(name, DRAFT_PROMPT) : launch.call(name)
        return @access.row("failed", file, reason: result[:reason], message: result[:message]) unless result[:ok]
        note = record_owner(name, file, plan, result[:pane])
        @output.puts "Started the plan for #{name}: launched it with the #{PLAY} play#{" to draft the tasks" if drafting}."
        @output.puts note if note
        @access.row(drafting ? "drafting" : "launched", file, pane: result[:pane], message: note)
      end

      def start_in_pane(name, file, plan)
        pane = main_pane(name, plan, @panes.panes(name))
        id = pane["pane_id"]
        if pane["state"] == "working"
          @output.puts "The plan for #{name} is already being worked on in pane #{id}."
          return @access.row("already_working", file, pane: id)
        end
        if pane["state"] == "waiting"
          raise Workspace::Error.new("Pane #{id} of '#{name}' is waiting for an answer, so nothing was typed. Answer it, then start the plan again.",
            code: "pane_busy", details: {"workspace" => name, "pane" => id})
        end
        drafting = plan.tasks.empty?
        play = @library.pack(PLAY, cwd: nil).first
        @panes.deliver(name, id, body: @library.play_prompt(play, drafting ? DRAFT_PROMPT : CONTINUE_PROMPT))
        notes = [@panes.bind_play(name, id, play), record_owner(name, file, plan, id)].compact
        @output.puts "Started the plan for #{name}: sent #{drafting ? "the draft request" : "it"} to pane #{id}."
        notes.each { |note| @output.puts note }
        @access.row(drafting ? "drafting" : "sent", file, pane: id, message: notes.empty? ? nil : notes.join(" "))
      end

      # The plan's owner when it is a live Claude Code or Codex pane, else the first one.
      def main_pane(name, plan, panes)
        @panes.main_pane(name, panes, preferred: plan.owner_pane, what: "the plan")
      end

      # @return [String, nil] a note when the owner could not be written
      def record_owner(name, file, plan, pane)
        return if pane.nil? || plan.owner_pane == pane
        changed = PlanFile.set_owner_pane(file, pane)
        @access.record_change(name, "active") if changed
        nil
      rescue Workspace::Error, SystemCallError => e
        "Could not record the owner pane in the plan (#{e.message}); set owner_pane: \"#{pane}\" there."
      end
    end
  end
end
