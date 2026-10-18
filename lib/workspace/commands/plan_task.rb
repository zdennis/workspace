module Workspace
  module Commands
    # `workspace plan task add|set-state|move`: changes one task line of a workspace's plan so
    # people, agents and the app need not edit the Markdown by hand. Each verb goes through a
    # {PlanFile} writer (temp file and rename, one re-read and retry), changes only the line it
    # must, keeps owner comments, never renumbers, and refuses an id that is already used.
    #
    # Every verb takes `if_revision`: the `revision` that `plan status --json` reports. When the
    # file has changed since, the verb refuses with `stale_revision` and writes nothing, so a caller
    # acting on an old view cannot overwrite a newer one. The result carries the new `revision`.
    #
    # A verb that changes the file records `plan_changed` in the event log, and the agent daemon's
    # plan watcher reports the new counts as `plan_progress`.
    class PlanTask
      # @param access [Workspace::PlanAccess] finds the plan and records `plan_changed`
      # @param output [IO] output stream
      def initialize(access:, output: $stdout)
        @access = access
        @output = output
      end

      # Adds a task.
      #
      # @param name [String] the workspace
      # @param title [String] the task's title, one line
      # @param id [String, nil] the new id; the next number after the plan's last id prefix when nil (`T9` after `T8`)
      # @param state [String] one of {PlanFile::TASK_STATES}
      # @param reason [String, nil] needed for `skipped` and `blocked`
      # @param phase [String, nil] the `###` heading it goes under
      # @param after [String, nil] the id of the task it goes after
      # @param if_revision [String, nil] refuse unless the plan's revision is this
      # @return [Hash] the row: `outcome` `added`, plus `task`, `state`, `line`, `phase`, `revision`, `counts`, `percent`
      # @raise [Workspace::Error] `no_plan`, `stale_revision`, `task_exists`, `invalid_task`, `reason_required`,
      #   `unknown_task`, `unknown_phase`, `no_task_section`, `notes_dir_unwritable`, `plan_write_conflict`
      def add(name:, title:, id: nil, state: "todo", reason: nil, phase: nil, after: nil, if_revision: nil)
        file, = @access.require_plan(name)
        result = write(name, file) { PlanFile.add_task(file, id: id, title: title, state: state, reason: reason, phase: phase, after: after, if_revision: if_revision) }
        @output.puts "Added task #{result.id} to the plan for #{name}."
        task_row("added", name, file, result, result.id)
      end

      # Sets a task's state. A skipped or blocked task ends with ` -- reason`, so +reason+ is needed for those;
      # leaving them takes the reason away. The owner comment stays.
      #
      # @param name [String] the workspace
      # @param id [String] the task's id
      # @param state [String] one of {PlanFile::TASK_STATES}
      # @param reason [String, nil] the reason for `skipped` or `blocked`; refused for the other states
      # @param if_revision [String, nil] refuse unless the plan's revision is this
      # @return [Hash] the row: `outcome` `changed` or `unchanged`, plus `task`, `state`, `previous_state`, `line`, `phase`, `revision`, `counts`, `percent`
      # @raise [Workspace::Error] `no_plan`, `stale_revision`, `unknown_task`, `invalid_task`, `reason_required`,
      #   `notes_dir_unwritable`, `plan_write_conflict`
      def set_state(name:, id:, state:, reason: nil, if_revision: nil)
        file, = @access.require_plan(name)
        result = write(name, file) do
          PlanFile.change_task(file, id, state: state, reason: reason.nil? ? PlanFile::KEEP : reason, if_revision: if_revision)
        end
        @output.puts result.changed ? "Set task #{id} of the plan for #{name} to #{state}." : "Task #{id} of the plan for #{name} is already #{state}."
        task_row(result.changed ? "changed" : "unchanged", name, file, result, id).merge("previous_state" => result.previous_state)
      end

      # Moves a task to a new place in the file; its phase is the heading it ends up under.
      #
      # @param name [String] the workspace
      # @param id [String] the task to move
      # @param after [String, nil] exactly one of +after+, +before+ (task ids) and +phase+ (move to the end of that phase)
      # @param before [String, nil]
      # @param phase [String, nil]
      # @param if_revision [String, nil] refuse unless the plan's revision is this
      # @return [Hash] the row: `outcome` `moved` or `unchanged`, plus `task`, `state`, `line`, `phase`, `revision`, `counts`, `percent`
      # @raise [Workspace::Error] `no_plan`, `stale_revision`, `unknown_task`, `unknown_phase`, `invalid_task`,
      #   `notes_dir_unwritable`, `plan_write_conflict`
      def move(name:, id:, after: nil, before: nil, phase: nil, if_revision: nil)
        file, = @access.require_plan(name)
        result = write(name, file) { PlanFile.move_task(file, id, after: after, before: before, phase: phase, if_revision: if_revision) }
        @output.puts result.changed ? "Moved task #{id} of the plan for #{name}." : "Task #{id} of the plan for #{name} is already there."
        task_row(result.changed ? "moved" : "unchanged", name, file, result, id)
      end

      private

      def write(name, file)
        result = @access.guarded_write(name, file) { yield }
        @access.record_change(name, result.plan.status) if result.changed
        result
      end

      def task_row(outcome, name, file, result, id)
        plan = result.plan
        task = plan.tasks.find { |candidate| candidate.id == id }
        @access.row(outcome, file).merge("task" => id, "state" => task&.state, "line" => task&.line, "phase" => task&.phase,
          "revision" => result.revision, "counts" => plan.counts, "percent" => plan.percent)
      end
    end
  end
end
