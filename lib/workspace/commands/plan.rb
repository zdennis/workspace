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
    # The verbs each change one thing and are safe to repeat. `pause` rewrites only the `status:` line
    # ({PlanFile.set_status}); with `interrupt` it asks {PlanDispatch#interrupt_owners} to press the
    # agent's interrupt key in each owner pane that works. `start` and `start --task` are
    # {PlanDispatch}'s. `delete` renames the file and touches neither the session nor the worktree.
    # A verb that changes the file records `plan_changed` in the event log.
    class Plan
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # Seconds the agent daemon may take to answer.
      DAEMON_TIMEOUT = PaneDispatch::DAEMON_TIMEOUT

      # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are
      # @param access [Workspace::PlanAccess] finds the plan, writes its status, records `plan_changed`
      # @param dispatch [Workspace::Commands::PlanDispatch] interrupts the owner panes for `pause --interrupt`
      # @param catalog [Workspace::ProjectCatalog] lists the workspaces for `--all` and `--group`
      # @param groups [Workspace::ProjectGroups] resolves `--group` to its repositories
      # @param plan_state [Workspace::PlanState] works out each row
      # @param plan_config [Workspace::PlanConfig] reads `plan.stall_seconds`
      # @param snapshot_client [Workspace::AgentSnapshotClient] reads the owner pane's state from the daemon
      # @param ask_store_for [#call] given a workspace name, returns its {Workspace::AskStore}
      # @param task_store [Workspace::TaskStore] gives `init` a default title
      # @param clock [#call] returns the current Time, for the name of a deleted plan
      # @param output [IO] output stream
      def initialize(notes:, access:, dispatch:, catalog:, groups:, plan_state:, plan_config:, snapshot_client:, ask_store_for:, task_store:,
        clock: -> { Time.now }, output: $stdout)
        @notes = notes
        @access = access
        @dispatch = dispatch
        @catalog = catalog
        @groups = groups
        @plan_state = plan_state
        @plan_config = plan_config
        @snapshot_client = snapshot_client
        @ask_store_for = ask_store_for
        @task_store = task_store
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

      # Prints the plan of every workspace of every repository in a group: the rows of {#rows}, each with the
      # `repository` id it belongs to. The JSON document is the `status --json` one plus `group: {id, name}` and
      # `repositories: [{id, name, path, exists}]` (every member, even one with no workspace rows);
      # the lines are grouped under a heading per repository.
      #
      # @param group [String] a group id, slug or name
      # @param json [Boolean] print one JSON document instead of lines
      # @return [Array<Hash>] the rows
      # @raise [Workspace::Error] `unknown_group`
      def status_group(group:, json: false)
        found = @groups.find(group)
        projects = @catalog.all
        by_repository = found.repositories.to_h { |repository| [repository, group_rows(repository, projects)] }
        rows = by_repository.values.flatten(1)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "group" => {"id" => found.id, "name" => found.name},
                                      "repositories" => found.repositories.map { |r| {"id" => r.id, "name" => r.name, "path" => r.path, "exists" => r.exists} },
                                      "plans" => rows})
        else
          @output.puts "#{found.name} (#{found.id})"
          @output.puts "  no repositories: add one with 'workspace projects group add GROUP PATH'" if by_repository.empty?
          by_repository.each do |repository, repository_rows|
            @output.puts "#{repository.name}  #{repository.path}#{"  (checkout missing)" unless repository.exists}"
            @output.puts "  no workspaces" if repository_rows.empty?
            repository_rows.each { |row| print_row(row, indent: "  ") }
          end
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
        @access.path_for(name)
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
        raise @access.no_plan(name, file)
      end

      # Writes a new plan into the notes directory, making the directory first.
      #
      # @param name [String] the workspace
      # @param title [String, nil] the plan's title; the workspace's task title when nil, else none
      # @param from [String, nil] a document to import: it becomes the plan, under new frontmatter unless it has its own
      # @param force [Boolean] replace a plan that is already there
      # @param print [Boolean] print `Created <path>`; false for a caller that prints its own (`start --plan`)
      # @return [Hash] `path` and `message` (set when an imported document has no tasks to count)
      # @raise [Workspace::Error] `plan_exists` when a plan is there and +force+ is not set,
      #   `notes_dir_unwritable` when the directory or file can't be written
      def init(name:, title: nil, from: nil, force: false, print: true)
        file = path_for(name)
        raise plan_exists(file) if File.exist?(file) && !force
        imported = from && read_import(from)
        info = @notes.info(name: name, create: true)
        file = PlanFile.path_in(info["dir"])
        title = clean_title(title || task_title(name))
        write(file, imported ? imported_text(imported, title) : new_text(title), force: force)
        message = "The imported document has no tasks under '## Tasks' yet: add one line per task." if imported && PlanFile.read(file).tasks.empty?
        if print
          @output.puts "Created #{file}"
          @output.puts message if message
        end
        @access.record_change(name, PlanFile.read(file).status)
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
        file, plan = @access.require_plan(name)
        raise @access.plan_done(name, file) if @access.finished?(plan)
        changed = @access.write_status(name, file, "paused")
        @output.puts changed ? "Paused the plan for #{name}." : "The plan for #{name} is already paused."
        result = @access.row(changed ? "paused" : "unchanged", file)
        return result unless interrupt
        interrupts, warnings = @dispatch.interrupt_owners(name, plan)
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
        file, = @access.require_plan(name)
        unless yes
          raise Workspace::Error.new("Deleting the plan for '#{name}' needs confirmation: pass --yes.",
            code: "confirmation_required", details: {"name" => name, "path" => file},
            retry_with: {"flags" => ["--yes"], "destructive" => true})
        end
        target = deleted_name(file)
        begin
          File.rename(file, target)
        rescue Errno::ENOENT
          raise @access.no_plan(name, file)
        rescue SystemCallError => e
          raise @access.unwritable(file, e)
        end
        @access.record_change(name, "deleted")
        @output.puts "Deleted the plan for #{name}: renamed to #{target}."
        @access.row("deleted", file, message: "Renamed to #{target}.")
      end

      private

      def deleted_name(file)
        stamp = @clock.call.utc.strftime("%Y%m%dT%H%M%SZ")
        target = "#{file}.deleted-#{stamp}"
        suffix = 0
        target = "#{file}.deleted-#{stamp}-#{suffix += 1}" while File.exist?(target)
        target
      end

      def row_for(name, memo)
        info = @notes.info(name: name)
        file = PlanFile.path_in(info["dir"])
        project = WorkspaceLineage.split_worktree_name(name)&.first || name
        plan = PlanFile.read(file)
        return @plan_state.row(workspace: name, project: project, path: file, plan: plan) if plan.nil? || plan.tasks.empty?

        live = @access.session_live?(name, memo)
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

      def group_rows(repository, projects)
        project = projects.find { |candidate| candidate.id == repository.id }
        names = project ? project.members.select { |member| member.configured && member.exists }.map(&:workspace).uniq : []
        memo = {}
        names.map do |name|
          row_for(name, memo)
        rescue Workspace::Error => e
          broken_row(name, e)
        end.map { |row| row.merge("repository" => repository.id) }
      end

      def all_workspaces
        @catalog.all.flat_map(&:members).select { |member| member.configured && member.exists }.map(&:workspace).uniq
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

      def print_row(row, indent: "")
        label = row["workspace"] || row["path"]
        if row["exists"]
          counts = row["counts"]
          current = row["current"]
          line = "#{label}  #{row["state"]}  #{counts["done"] + counts["skipped"]}/#{counts["total"]} (#{row["percent"]}%)"
          line += "  #{[current["id"], current["title"]].compact.join(" ")}" if current
          @output.puts "#{indent}#{line}"
        else
          @output.puts "#{indent}#{label}  no plan"
        end
        row["warnings"].each do |warning|
          where = warning["line"] ? "line #{warning["line"]}: " : ""
          @output.puts "#{indent}  #{where}#{warning["code"]}: #{warning["message"]}"
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
