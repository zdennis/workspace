require "json"
require "fileutils"

module Workspace
  module Commands
    # `workspace plan`: reads and starts a workspace's plan, the counted task
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
    class Plan
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # Seconds the agent daemon may take to answer.
      DAEMON_TIMEOUT = 1.0

      # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are
      # @param catalog [Workspace::ProjectCatalog] lists the workspaces for `--all`
      # @param plan_state [Workspace::PlanState] works out each row
      # @param plan_config [Workspace::PlanConfig] reads `plan.stall_seconds`
      # @param tmux [Workspace::Tmux] says which sessions run
      # @param snapshot_client [Workspace::AgentSnapshotClient] reads the owner pane's state from the daemon
      # @param ask_store_for [#call] given a workspace name, returns its {Workspace::AskStore}
      # @param task_store [Workspace::TaskStore] gives `init` a default title
      # @param output [IO] output stream
      def initialize(notes:, catalog:, plan_state:, plan_config:, tmux:, snapshot_client:, ask_store_for:, task_store:, output: $stdout)
        @notes = notes
        @catalog = catalog
        @plan_state = plan_state
        @plan_config = plan_config
        @tmux = tmux
        @snapshot_client = snapshot_client
        @ask_store_for = ask_store_for
        @task_store = task_store
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
        raise Workspace::Error.new("No plan for '#{name}' at #{file}. Make one with 'workspace plan init --name #{name}'.",
          code: "no_plan", details: {"name" => name, "path" => file})
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
        {"path" => file, "message" => message}
      end

      private

      def row_for(name, memo)
        info = @notes.info(name: name)
        file = PlanFile.path_in(info["dir"])
        project = WorkspaceLineage.split_worktree_name(name)&.first || name
        plan = PlanFile.read(file)
        return @plan_state.row(workspace: name, project: project, path: file, plan: plan) if plan.nil? || plan.tasks.empty?

        live = session_live?(name, memo)
        panes = (plan.owner_pane && live != false) ? read_panes(name) : nil
        @plan_state.row(workspace: name, project: project, path: file, plan: plan, session_live: live, panes: panes,
          open_asks: open_asks(name), stall_seconds: @plan_config.stall_seconds_for(name))
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
