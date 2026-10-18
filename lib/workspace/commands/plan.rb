require "json"
require "fileutils"

module Workspace
  module Commands
    # `workspace plan`: reads, starts, pauses and deletes a workspace's plan, the counted task
    # list in `IMPLEMENTATION_PLAN.md` in its notes directory (see {PlanFile}
    # for the syntax and {PlanState} for how the state is worked out).
    #
    # Reading never fails for want of a plan: a workspace without one is a row
    # with `exists: false`. The notes directory comes from
    # {Workspace::Commands::Notes#info}, the one answer to where notes are.
    #
    # The state of a plan is worked out from the file and from what can be read
    # about the workspace: its tmux session, the owner pane's state from the
    # agent daemon, and its open questions. A source that can't answer leaves
    # that fact unknown and the plan's state does not use it.
    #
    # The verbs each change one thing and are safe to repeat. `start` and `pause` rewrite only the
    # `status:` line ({PlanFile.set_status}); `start` also launches the workspace, or types into its
    # main agent pane, and records that pane as `owner_pane`. `start` with a task sends that one
    # task to a pane (named, new, or the main one) and writes the pane onto the task line as its
    # owner ({PlanFile.set_task}). `pause` interrupts nothing unless asked to, and then presses the
    # agent's own interrupt key ({AgentProvider#interrupt_keys}) in each owner pane that works.
    # `delete` renames the file and touches neither the session nor the worktree. A verb that
    # changes the file records `plan_changed` in the event log.
    class Plan
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # Seconds the agent daemon may take to answer.
      DAEMON_TIMEOUT = 1.0

      # The built-in play `start` points the agent at.
      PLAY = "implementation-plan"

      # The line `start` gives the agent after the play.
      CONTINUE_PROMPT = "Continue the plan."

      # The agent kinds a task may be sent to, and `--spawn` may start: every {AgentProvider}.
      AGENT_KINDS = AgentProvider.all.map(&:key).freeze

      # @param task_id [String]
      # @return [String] the line `start --task` gives the agent after the play
      def self.task_prompt(task_id)
        "Work on plan task #{task_id} only. Do not take other tasks; end your turn when it is done or blocked."
      end

      # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are
      # @param catalog [Workspace::ProjectCatalog] lists the workspaces for `--all`
      # @param plan_state [Workspace::PlanState] works out each row
      # @param plan_config [Workspace::PlanConfig] reads `plan.stall_seconds`
      # @param tmux [Workspace::Tmux] says which sessions run
      # @param snapshot_client [Workspace::AgentSnapshotClient] reads the owner pane's state from the daemon
      # @param ask_store_for [#call] given a workspace name, returns its {Workspace::AskStore}
      # @param task_store [Workspace::TaskStore] gives `init` a default title
      # @param sender [Workspace::Commands::Send] types the continue line into the main agent pane for `start`
      # @param binder [Workspace::Commands::Binding] binds that pane to the plan play
      # @param library [Workspace::Library] finds the built-in play
      # @param event_log [Workspace::EventLog] gets `plan_changed`
      # @param runner [Workspace::Commands::Run] splits a new pane and starts an agent in it for `start --spawn`
      # @param readiness [Workspace::AgentReadiness] waits for that agent before its task is typed
      # @param prompt_timeout [Numeric] seconds the new agent may take to be ready
      # @param clock [#call] returns the current Time, for the name of a deleted plan
      # @param output [IO] output stream
      def initialize(notes:, catalog:, plan_state:, plan_config:, tmux:, snapshot_client:, ask_store_for:, task_store:, sender:, binder:, library:,
        event_log:, runner:, readiness:, prompt_timeout: AgentReadiness::DEFAULT_TIMEOUT, clock: -> { Time.now }, output: $stdout)
        @runner = runner
        @readiness = readiness
        @prompt_timeout = prompt_timeout
        @notes = notes
        @catalog = catalog
        @plan_state = plan_state
        @plan_config = plan_config
        @tmux = tmux
        @snapshot_client = snapshot_client
        @ask_store_for = ask_store_for
        @task_store = task_store
        @sender = sender
        @binder = binder
        @library = library
        @event_log = event_log
        @clock = clock
        @output = output
      end

      # Prints the plan of each workspace, or of one file.
      #
      # @param names [Array<String>] workspaces to read; ignored with +all+ or +file+
      # @param all [Boolean] every configured workspace whose checkout exists
      # @param file [String, nil] a file to read on its own, with no workspace and a state from the file alone
      # @param json [Boolean] print one JSON document instead of lines
      # @return [Array<Hash>] the rows
      # @raise [Workspace::Error] as {Workspace::Commands::Notes#info} for a named workspace
      def status(names: [], all: false, file: nil, json: false)
        rows = file ? [file_row(file)] : rows(names: names, all: all)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "plans" => rows})
        else
          rows.each { |row| print_row(row) }
        end
        rows
      end

      # The rows {#status} prints, for a caller that wants them without the printing.
      #
      # @param names [Array<String>] workspaces to read; ignored with +all+
      # @param all [Boolean] every configured workspace whose checkout exists
      # @return [Array<Hash>] one row per workspace (see {PlanState#row}); with +all+, a workspace whose
      #   notes directory can't be worked out is a row with a null `path` and a warning carrying the error's code
      def rows(names: [], all: false)
        memo = {}
        return names.map { |name| row_for(name, memo) } unless all
        all_workspaces.map do |name|
          row_for(name, memo)
        rescue Workspace::Error => e
          broken_row(name, e)
        end
      end

      # Prints where a workspace's plan is, whether or not the file exists.
      #
      # @param name [String] the workspace
      # @param json [Boolean] print the document instead of the path
      # @return [void]
      # @raise [Workspace::Error] as {Workspace::Commands::Notes#info}
      def path(name:, json: false)
        info = @notes.info(name: name)
        file = PlanFile.path_in(info["dir"])
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "path" => file, "exists" => File.file?(file),
                                      "notes_dir" => info["dir"]})
        else
          @output.puts file
        end
      end

      # Where a workspace's plan is, whether or not the file exists.
      #
      # @param name [String] the workspace
      # @return [String] the absolute path
      # @raise [Workspace::Error] as {Workspace::Commands::Notes#info}
      def path_for(name)
        PlanFile.path_in(@notes.info(name: name)["dir"])
      end

      # Prints the plan file as it is.
      #
      # @param name [String] the workspace
      # @return [void]
      # @raise [Workspace::Error] `no_plan` when there is no plan file
      def show(name:)
        file = path_for(name)
        @output.print File.read(file, encoding: Encoding::UTF_8)
      rescue SystemCallError => e
        raise Workspace::Error, "Can't read the plan #{file}: #{e.message}" unless e.is_a?(Errno::ENOENT)
        raise no_plan(name, file)
      end

      # Writes a new plan into the notes directory, making the directory first.
      #
      # @param name [String] the workspace
      # @param title [String, nil] the plan's title; the workspace's task title when nil, else none
      # @param from [String, nil] a document to import: it becomes the plan, under new frontmatter unless it has its own
      # @param force [Boolean] replace a plan that is already there
      # @return [Hash] `path` and `message` (set when an imported document has no tasks to count)
      # @raise [Workspace::Error] `plan_exists` when a plan is there and +force+ is not set,
      #   `notes_dir_unwritable` when the directory or file can't be written
      def init(name:, title: nil, from: nil, force: false)
        file = path_for(name)
        raise plan_exists(file) if File.exist?(file) && !force
        imported = from && read_import(from)
        info = @notes.info(name: name, create: true)
        file = PlanFile.path_in(info["dir"])
        title = clean_title(title || task_title(name))
        write(file, imported ? imported_text(imported, title) : new_text(title), force: force)
        message = "The imported document has no tasks under '## Tasks' yet: add one line per task." if imported && PlanFile.read(file).tasks.empty?
        @output.puts "Created #{file}"
        @output.puts message if message
        record_change(name, PlanFile.read(file).status)
        {"path" => file, "message" => message}
      end

      # Sets `status: paused`, printing what it did. Without +interrupt+ it interrupts nothing: the
      # agent stops before its next task. With it, each owner pane (the plan's `owner_pane` and the
      # owners of the tasks still left) that the agent daemon lists as working gets its agent's
      # interrupt keys ({AgentProvider#interrupt_keys}).
      #
      # @param name [String] the workspace
      # @param interrupt [Boolean] also interrupt the owner panes that are working
      # @return [Hash] the row of the action document: `outcome` (`paused`, or `unchanged` when it already was), `reason`, `message`, `path`, `pane`;
      #   with +interrupt+ also `interrupts` (`{pane, kind, outcome, message}`, outcome `sent`, `not_working`, `unsupported`, `gone` or `failed`)
      #   and `warnings` (`no_daemon` when the panes could not be read)
      # @raise [Workspace::Error] `no_plan`, `plan_done` when the plan is done, `notes_dir_unwritable`, `plan_write_conflict`
      def pause(name:, interrupt: false)
        file, plan = require_plan(name)
        raise plan_done(name, file) if finished?(plan)
        changed = write_status(name, file, "paused")
        @output.puts changed ? "Paused the plan for #{name}." : "The plan for #{name} is already paused."
        result = row(changed ? "paused" : "unchanged", file)
        return result unless interrupt
        interrupts, warnings = interrupt_owners(name, plan)
        result.merge("interrupts" => interrupts, "warnings" => warnings)
      end

      # Renames the plan to `IMPLEMENTATION_PLAN.md.deleted-<time>`. The session, the worktree and
      # the rest of the notes directory are left alone.
      #
      # @param name [String] the workspace
      # @param yes [Boolean] confirms the delete
      # @return [Hash] the row: `outcome` `deleted`, with `message` naming the new file
      # @raise [Workspace::Error] `no_plan`, `confirmation_required` without +yes+, `notes_dir_unwritable`
      def delete(name:, yes: false)
        file, = require_plan(name)
        unless yes
          raise Workspace::Error.new("Deleting the plan for '#{name}' needs confirmation: pass --yes.",
            code: "confirmation_required", details: {"name" => name, "path" => file},
            retry_with: {"flags" => ["--yes"], "destructive" => true})
        end
        target = deleted_name(file)
        begin
          File.rename(file, target)
        rescue Errno::ENOENT
          raise no_plan(name, file)
        rescue SystemCallError => e
          raise unwritable(file, e)
        end
        record_change(name, "deleted")
        @output.puts "Deleted the plan for #{name}: renamed to #{target}."
        row("deleted", file, message: "Renamed to #{target}.")
      end

      # Sets `status: active` and gets an agent working on the plan: a workspace with no session is
      # launched with the play and {CONTINUE_PROMPT}; one with a session gets the same text typed into
      # its main agent pane, which is bound to the play. A pane that is working is left alone.
      # The pane the agent is in is recorded as `owner_pane` (the plan never reads `working` without one).
      #
      # @param name [String] the workspace
      # @param launch [#call] given the workspace name, launches it with the play and prompt and returns
      #   `{ok:, reason:, message:, pane:}` (the CLI supplies it, since launching is its job)
      # @return [Hash] the row: `outcome` `launched`, `sent`, `already_working`, or `failed` when the launch could not
      #   send its prompt (`reason` and `message` say why); `pane` is the pane the agent is in, when known
      # @raise [Workspace::Error] `no_plan`, `plan_done`, `notes_dir_unwritable`, `plan_write_conflict`; with a session,
      #   `no_daemon`, `no_agent_pane`, `pane_busy` (the pane waits on a person), and the codes of {Workspace::Commands::Send#deliver}
      def start(name:, launch:)
        file, plan = require_plan(name)
        raise plan_done(name, file) if finished?(plan)
        live = session_live?(name, {})
        write_status(name, file, "active")
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
        file, plan = require_plan(name)
        raise plan_done(name, file) if finished?(plan)
        task = plan.tasks.find { |candidate| candidate.id == task_id } || raise(PlanFile.unknown_task(file, task_id))
        raise task_done(name, file, task) if %w[done skipped].include?(task.state)
        live = session_live?(name, {})
        raise no_session(name) if live == false && (pane || spawn)
        return task_by_launch(name, file, task, launch) if live == false
        spawn ? task_by_spawn(name, file, task, spawn) : task_in_pane(name, file, plan, task, pane)
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
        write_status(name, file, "active")
        result = launch.call(name, self.class.task_prompt(task.id))
        return task_row("failed", file, task, reason: result[:reason], message: result[:message]) unless result[:ok]
        note = record_task_owner(name, file, task, result[:pane])
        @output.puts "Started task #{task.id} of the plan for #{name}: launched it with the #{PLAY} play."
        @output.puts note if note
        task_row("launched", file, task, pane: result[:pane], message: note)
      end

      def task_in_pane(name, file, plan, task, named)
        panes = Array(fetch_panes(name)["panes"])
        owner = task.owner && panes.find { |candidate| candidate["pane_id"] == task.owner }
        target = if named
          id = @sender.locate(name, named)[:id]
          panes.find { |candidate| candidate["pane_id"] == id } || {"pane_id" => id}
        else
          (owner if owner && AGENT_KINDS.include?(owner["kind"])) || main_pane(name, plan, panes)
        end
        id = target["pane_id"]
        if owner && owner["state"] == "working" && owner["pane_id"] != id
          raise Workspace::Error.new("Task #{task.id} of '#{name}' is being worked on in pane #{owner["pane_id"]}, so it was not sent to #{id}. " \
            "Pause that pane first, or send the task there.", code: "task_owned", details: {"workspace" => name, "task" => task.id, "owner" => owner["pane_id"]})
        end
        unless AGENT_KINDS.include?(target["kind"])
          raise Workspace::Error.new("Pane #{id} of '#{name}' runs no coding agent the agent daemon knows, so the task was not typed into it.",
            code: "no_agent_pane", details: {"workspace" => name, "pane" => id})
        end
        if target["state"] == "working" && task.owner == id
          write_status(name, file, "active")
          @output.puts "Task #{task.id} of the plan for #{name} is already being worked on in pane #{id}."
          return task_row("already_working", file, task, pane: id)
        end
        refuse_busy(name, target)
        deliver_task(name, file, task, id, "sent")
      end

      def refuse_busy(name, pane)
        id = pane["pane_id"]
        if pane["state"] == "waiting"
          raise Workspace::Error.new("Pane #{id} of '#{name}' is waiting for an answer, so nothing was typed. Answer it, then start the task again.",
            code: "pane_busy", details: {"workspace" => name, "pane" => id, "state" => "waiting"})
        end
        return unless pane["state"] == "working"
        raise Workspace::Error.new("Pane #{id} of '#{name}' is working on something else, so nothing was typed. Send the task to another pane, " \
          "or use --spawn.", code: "pane_busy", details: {"workspace" => name, "pane" => id, "state" => "working"})
      end

      def task_by_spawn(name, file, task, kind)
        if task.owner
          owner = Array(fetch_panes(name)["panes"]).find { |candidate| candidate["pane_id"] == task.owner }
          if owner && owner["state"] == "working"
            raise Workspace::Error.new("Task #{task.id} of '#{name}' is being worked on in pane #{task.owner}, so no new agent was started. Pause that pane first.",
              code: "task_owned", details: {"workspace" => name, "task" => task.id, "owner" => task.owner})
          end
        end
        provider = AgentProvider.find(kind)
        id = @runner.call(name, provider.executable, split: true)
        ready = @readiness.wait(@tmux.session_name_for(name), deadline: @readiness.deadline_in(@prompt_timeout), only_pane: id)
        unless ready.ready?
          message = "Started #{provider.label} in new pane #{id}, but it was not ready for the task in #{@prompt_timeout}s (#{ready.reason}); nothing was typed."
          return task_row("failed", file, task, reason: "prompt_not_sent", message: message, pane: id)
        end
        deliver_task(name, file, task, id, "spawned")
      end

      def deliver_task(name, file, task, id, outcome)
        write_status(name, file, "active")
        play = @library.pack(PLAY, cwd: nil).first
        @sender.deliver(name: name, pane: id, body: @library.play_prompt(play, self.class.task_prompt(task.id)))
        notes = [bind_play(name, id, play, focus: "plan task #{task.id}"), record_task_owner(name, file, task, id)].compact
        @output.puts "Started task #{task.id} of the plan for #{name}: sent it to #{(outcome == "spawned") ? "new pane" : "pane"} #{id}."
        notes.each { |note| @output.puts note }
        task_row(outcome, file, task, pane: id, message: notes.empty? ? nil : notes.join(" "))
      end

      def task_row(outcome, file, task, **fields)
        row(outcome, file, **fields).merge("task" => task.id)
      end

      # Writes the pane onto the task line as its owner, and takes a task to do to in progress.
      # @return [String, nil] a note when the line could not be written
      def record_task_owner(name, file, task, pane)
        return if pane.nil?
        # Read again: the agent may have taken the task to another state since the plan was read.
        current = PlanFile.read(file)&.tasks&.find { |candidate| candidate.id == task.id }
        changed = PlanFile.set_task(file, task.id, owner: pane, state: (current&.state == "todo") ? "in_progress" : nil)
        record_change(name, "active") if changed
        nil
      rescue Workspace::Error, SystemCallError => e
        "Could not record the owner on task #{task.id} (#{e.message}); add <!-- owner: #{pane} --> to its line."
      end

      # @return [Array(Array<Hash>, Array<Hash>)] the interrupt rows and the warnings
      def interrupt_owners(name, plan)
        left = plan.tasks.select { |task| PlanState::LEFT_STATES.include?(task.state) }
        owners = [plan.owner_pane, *left.map(&:owner)].compact.uniq
        return [[], []] if owners.empty?
        panes = begin
          Array(@snapshot_client.fetch(name, timeout: DAEMON_TIMEOUT)["panes"])
        rescue Workspace::Error => e
          @output.puts "Could not read the panes to interrupt them: #{e.message}"
          return [[], [{"code" => "no_daemon", "message" => e.message}]]
        end
        [owners.map { |id| interrupt_pane(name, id, panes.find { |candidate| candidate["pane_id"] == id }) }, []]
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
        @sender.deliver(name: name, pane: id, keys: keys)
        @output.puts "Interrupted pane #{id} (#{keys.join(" ")})."
        entry.merge("outcome" => "sent")
      rescue Workspace::Error => e
        @output.puts "Could not interrupt pane #{id}: #{e.message}"
        entry.merge("outcome" => "failed", "message" => e.message)
      end

      def require_plan(name)
        file = path_for(name)
        plan = PlanFile.read(file)
        raise no_plan(name, file) unless plan
        [file, plan]
      end

      def no_plan(name, file)
        Workspace::Error.new("No plan for '#{name}' at #{file}. Make one with 'workspace plan init --name #{name}'.",
          code: "no_plan", details: {"name" => name, "path" => file})
      end

      def plan_done(name, file)
        Workspace::Error.new("The plan for '#{name}' is done: nothing is left to do. Edit #{file} to reopen it.",
          code: "plan_done", details: {"name" => name, "path" => file})
      end

      def finished?(plan)
        plan.status == "done" || (!plan.tasks.empty? && plan.counts["left"].zero?)
      end

      def row(outcome, file, message: nil, pane: nil, reason: nil)
        {"outcome" => outcome, "reason" => reason, "message" => message, "path" => file, "pane" => pane}
      end

      # The `status:` write, with the event when the file changed.
      def write_status(name, file, status)
        changed = guarded_write(name, file) { PlanFile.set_status(file, status) }
        record_change(name, status) if changed
        changed
      end

      def guarded_write(name, file)
        yield
      rescue Errno::ENOENT
        raise no_plan(name, file)
      rescue SystemCallError => e
        raise unwritable(file, e)
      end

      def unwritable(file, error)
        Workspace::Error.new("Can't write the plan #{file}: #{error.message}", code: "notes_dir_unwritable", details: {"path" => File.dirname(file)})
      end

      def record_change(name, status)
        @event_log.record(type: "plan_changed", project: name, data: {"workspace" => name, "status" => status})
      end

      def deleted_name(file)
        stamp = @clock.call.utc.strftime("%Y%m%dT%H%M%SZ")
        target = "#{file}.deleted-#{stamp}"
        suffix = 0
        target = "#{file}.deleted-#{stamp}-#{suffix += 1}" while File.exist?(target)
        target
      end

      def start_by_launch(name, file, plan, launch)
        result = launch.call(name)
        return row("failed", file, reason: result[:reason], message: result[:message]) unless result[:ok]
        note = record_owner(name, file, plan, result[:pane])
        @output.puts "Started the plan for #{name}: launched it with the #{PLAY} play."
        @output.puts note if note
        row("launched", file, pane: result[:pane], message: note)
      end

      def start_in_pane(name, file, plan)
        panes = Array(fetch_panes(name)["panes"])
        pane = main_pane(name, plan, panes)
        id = pane["pane_id"]
        if pane["state"] == "working"
          @output.puts "The plan for #{name} is already being worked on in pane #{id}."
          return row("already_working", file, pane: id)
        end
        if pane["state"] == "waiting"
          raise Workspace::Error.new("Pane #{id} of '#{name}' is waiting for an answer, so nothing was typed. Answer it, then start the plan again.",
            code: "pane_busy", details: {"workspace" => name, "pane" => id})
        end
        play = @library.pack(PLAY, cwd: nil).first
        @sender.deliver(name: name, pane: id, body: @library.play_prompt(play, CONTINUE_PROMPT))
        notes = [bind_play(name, id, play), record_owner(name, file, plan, id)].compact
        @output.puts "Started the plan for #{name}: sent it to pane #{id}."
        notes.each { |note| @output.puts note }
        row("sent", file, pane: id, message: notes.empty? ? nil : notes.join(" "))
      end

      def fetch_panes(name)
        @snapshot_client.fetch(name, timeout: DAEMON_TIMEOUT)
      rescue AgentSnapshotClient::Unavailable => e
        raise Workspace::Error.new(e.message, code: "no_daemon", details: {"workspace" => name})
      end

      # The plan's owner when it is a live Claude Code or Codex pane, else the first one.
      def main_pane(name, plan, panes)
        agents = panes.select { |pane| %w[claude codex].include?(pane["kind"]) && pane["pane_id"] }
        agents.find { |pane| pane["pane_id"] == plan.owner_pane } || agents.first ||
          raise(Workspace::Error.new("No pane of '#{name}' runs Claude Code or Codex, so there is nowhere to send the plan.",
            code: "no_agent_pane", details: {"workspace" => name}))
      end

      # A pane bound to a run or review keeps that binding; a play binding keeps its packs. A +focus+
      # (the task sent) is repeated by the SessionStart hook after a `/clear`.
      # @return [String, nil] a note when the pane could not be bound
      def bind_play(name, pane, play, focus: nil)
        existing = @binder.live(pane: pane)
        return if existing && existing["kind"] != "play"
        fields = @library.play_binding(play, packs: Array(existing && existing["packs"]))
        fields = fields.merge("focus" => focus) if focus
        @binder.bind(workspace: name, pane: pane, **fields)
        nil
      rescue Workspace::Error, SystemCallError => e
        "Sent, but could not bind pane #{pane} to the play (#{e.message})."
      end

      # @return [String, nil] a note when the owner could not be written
      def record_owner(name, file, plan, pane)
        return if pane.nil? || plan.owner_pane == pane
        changed = PlanFile.set_owner_pane(file, pane)
        record_change(name, "active") if changed
        nil
      rescue Workspace::Error, SystemCallError => e
        "Could not record the owner pane in the plan (#{e.message}); set owner_pane: \"#{pane}\" there."
      end

      def row_for(name, memo)
        info = @notes.info(name: name)
        file = PlanFile.path_in(info["dir"])
        project = WorkspaceLineage.split_worktree_name(name)&.first || name
        plan = PlanFile.read(file)
        return @plan_state.row(workspace: name, project: project, path: file, plan: plan) if plan.nil? || plan.tasks.empty?

        live = session_live?(name, memo)
        panes = (owned?(plan) && live != false) ? read_panes(name) : nil
        @plan_state.row(workspace: name, project: project, path: file, plan: plan, session_live: live, panes: panes,
          open_asks: open_asks(name), stall_seconds: @plan_config.stall_seconds_for(name))
      end

      # Whether the plan or any of its tasks names an owner pane, so the daemon is worth asking.
      def owned?(plan)
        !plan.owner_pane.nil? || plan.tasks.any?(&:owner)
      end

      def broken_row(name, error)
        project = WorkspaceLineage.split_worktree_name(name)&.first || name
        row = @plan_state.row(workspace: name, project: project, path: nil, plan: nil)
        row.merge("warnings" => [PlanFile.warning(error.code, nil, error.message.lines.first.to_s.strip)])
      end

      def file_row(file)
        path = File.expand_path(file)
        @plan_state.row(workspace: nil, project: nil, path: path, plan: PlanFile.read(path))
      end

      def all_workspaces
        @catalog.all.flat_map(&:members).select { |member| member.configured && member.exists }.map(&:workspace).uniq
      end

      # nil when tmux can't be asked or the workspace runs on a socket of its own.
      def session_live?(name, memo)
        return nil if @tmux.custom_socket_option(name)
        memo[:sessions] = read_sessions unless memo.key?(:sessions)
        memo[:sessions]&.include?(@tmux.session_name_for(name))
      end

      def read_sessions
        @tmux.sessions(strict: true)
      rescue Workspace::Error, SystemCallError
        nil
      end

      def read_panes(name)
        Array(@snapshot_client.fetch(name, timeout: DAEMON_TIMEOUT)["panes"])
      rescue Workspace::Error
        nil
      end

      def open_asks(name)
        @ask_store_for.call(name).list(open_only: true).size
      rescue Workspace::Error
        0
      end

      def print_row(row)
        label = row["workspace"] || row["path"]
        if row["exists"]
          counts = row["counts"]
          current = row["current"]
          line = "#{label}  #{row["state"]}  #{counts["done"] + counts["skipped"]}/#{counts["total"]} (#{row["percent"]}%)"
          line += "  #{[current["id"], current["title"]].compact.join(" ")}" if current
          @output.puts line
        else
          @output.puts "#{label}  no plan"
        end
        row["warnings"].each do |warning|
          where = warning["line"] ? "line #{warning["line"]}: " : ""
          @output.puts "  #{where}#{warning["code"]}: #{warning["message"]}"
        end
      end

      def task_title(name)
        @task_store.active_for(name)&.fetch("title", nil)
      rescue Workspace::Error
        nil
      end

      def clean_title(title)
        cleaned = title.to_s.gsub(/\s+/, " ").strip
        cleaned.empty? ? nil : cleaned
      end

      def read_import(from)
        File.read(from, encoding: Encoding::UTF_8)
      rescue SystemCallError => e
        raise Workspace::Error, "Can't read #{from}: #{e.message}"
      end

      def frontmatter(title)
        ["---", "plan: 1", (title ? "title: #{title.to_json}" : nil), "status: active", "---"].compact.join("\n")
      end

      def new_text(title)
        <<~MD
          #{frontmatter(title)}

          # #{title || "Implementation plan"}

          ## Tasks

          <!-- One line per task, starting at column 0:  - [ ] T1 Title
               States: [ ] to do, [~] in progress, [x] done, [-] skipped, [!] blocked.
               A skipped or blocked task ends with " -- reason". Put a ### heading above a
               group of tasks to name its phase. -->

          ## Task details
        MD
      end

      def imported_text(text, title)
        return text unless PlanFile.parse(text).frontmatter.empty?
        "#{frontmatter(title)}\n\n#{text}"
      end

      # Whole or not at all: a plan appears complete, or the old one stays.
      def write(file, text, force:)
        temp = "#{file}.#{Process.pid}.tmp"
        File.write(temp, text)
        if force
          File.rename(temp, file)
        else
          begin
            File.link(temp, file)
          rescue Errno::EEXIST
            raise plan_exists(file)
          ensure
            File.delete(temp) if File.exist?(temp)
          end
        end
      rescue SystemCallError => e
        FileUtils.rm_f(temp)
        raise Workspace::Error.new("Can't write the plan #{file}: #{e.message}", code: "notes_dir_unwritable", details: {"path" => File.dirname(file)})
      end

      def plan_exists(file)
        Workspace::Error.new("There is already a plan at #{file}. Pass --force to replace it.", code: "plan_exists", details: {"path" => file})
      end
    end
  end
end
