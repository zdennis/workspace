require "json"

module Workspace
  module Commands
    # The `workflow` and `step` subcommands: shows definitions, starts a run
    # in a workspace's agent pane, shows where runs stand, and lets a person
    # move one (resume, cancel, approve, reject) or the run's own agent report
    # on its step. {Workspace::WorkflowEngine} makes every transition.
    #
    # Reads print one JSON document with `json: true`. Mutations return the
    # row the CLI puts in its action document, and print a line for a person.
    class Workflow
      # Bumped whenever a `--json` document's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # Lines of a check's output `check` prints.
      CHECK_TAIL_LINES = 40

      # The workspace name `render` shows when the working directory is in no workspace.
      RENDER_WORKSPACE = "<workspace>".freeze

      # What `step done --status` accepts.
      REPORT_STATUSES = %w[pass fail].freeze

      # @param catalog [Workspace::WorkflowCatalog]
      # @param engine [Workspace::WorkflowEngine]
      # @param status [Workspace::WorkflowStatus]
      # @param workspace_facts [Workspace::WorkflowWorkspaceFacts, nil] reads the workspace facts `status --table` shows
      # @param store [Workspace::WorkflowRunStore]
      # @param panes [Workspace::WorkflowPanes]
      # @param files [Workspace::WorkflowFiles] writes a user's definitions (`add`)
      # @param run_files [Workspace::WorkflowRunFiles] lists a run's files (`files`)
      # @param attempts [Workspace::WorkflowAttempts, nil] reads a run's recorded attempts (`attempts`)
      # @param audit [Workspace::WorkflowAudit, nil] checks a run's evidence copies against their hashes (`audit`)
      # @param sweep [Workspace::WorkflowSweep, nil] looks at the runs still going and acts on the stopped ones (`sweep`)
      # @param needs_me [Workspace::WorkflowNeedsMe, nil] narrows the runs to the ones that wait for a person (`status --needs-me`)
      # @param stats [Workspace::WorkflowStats, nil] reads a workflow's runs into per-step figures (`stats`)
      # @param compare [Workspace::WorkflowCompare, nil] sets a workflow's runs side by side by definition or pack (`compare`)
      # @param simulator [Workspace::WorkflowSimulator, nil] plays a workflow with a scripted fake agent (`simulate`)
      # @param source_installer [Workspace::WorkflowSourceInstaller, nil] fetches, checks and caches the `workflows.sources` entries (`install`)
      # @param tmux [Workspace::Tmux] names the pid of a run's pane, for approve and reject
      # @param process_tree [Workspace::ProcessTree] says whether this process runs under that pane
      # @param lock_holder [Workspace::LockHolder] names the agent a refusal was made for
      # @param lint [Workspace::WorkflowLint] the checks `validate` makes against the library and the project's commands
      # @param pid [Integer] this process
      # @param clock [#call] returns the current Time
      # @param output [IO]
      # @param input [IO] read for `validate -` and `add ID -`
      # @param error_output [IO] gets the problems `show --source` finds in a file's text
      def initialize(lint:, catalog:, engine:, status:, store:, panes:, files:, run_files:, tmux:, process_tree:, lock_holder:, workspace_facts: nil, attempts: nil, audit: nil, sweep: nil, schedule: nil, needs_me: nil, branch_inputs: nil, stats: nil, compare: nil, step_check: nil, simulator: nil, source_installer: nil, pid: Process.pid,
        clock: -> { Time.now }, output: $stdout, input: $stdin, error_output: $stderr)
        @tmux = tmux
        @process_tree = process_tree
        @lock_holder = lock_holder
        @pid = pid
        @catalog = catalog
        @files = files
        @run_files = run_files
        @lint = lint
        @attempts = attempts
        @audit = audit
        @sweep = sweep
        @schedule = schedule
        @needs_me = needs_me
        @branch_inputs = branch_inputs
        @stats = stats
        @compare = compare
        @step_check = step_check
        @simulator = simulator
        @source_installer = source_installer
        @engine = engine
        @status = status
        @workspace_facts = workspace_facts
        @store = store
        @panes = panes
        @clock = clock
        @output = output
        @input = input
        @error_output = error_output
      end

      # Prints one definition, or every definition when +id+ is nil.
      # With +source:+ it answers the definition's file as it is, valid or not: the
      # text (nil when the bytes are not UTF-8), the sha256 of the raw bytes and
      # every problem. The definition's own fields are added only when there are
      # no problems. A file with problems is still an answer (exit 0).
      #
      # @param id [String, nil]
      # @param json [Boolean]
      # @param source [Boolean] answer the file's text instead of the parsed definition
      # @param project [String, nil] the project whose definitions come first (see {Workspace::WorkflowCatalog})
      # @return [void]
      # @raise [Workspace::Error] code `unknown_workflow`; without +source:+ also `invalid_workflow`
      def show(id: nil, json: false, source: false, project: nil)
        return list(json: json, project: project) unless id
        return show_source(id, json, project) if source
        definition = @catalog.find(id, project: project)
        data = definition.to_h
        if json
          return document("workflow" => with_branch_fills(data).merge("source" => definition.source, "path" => definition.path, "sha256" => definition.sha256, "resolved_sha256" => definition.resolved_sha256).merge("project" => (definition.source == "project") ? project : nil).merge(extends_field(definition)))
        end
        @output.puts "#{data["id"]}: #{data["title"]} (#{definition.source}, #{definition.path})"
        @output.puts data["description"] if data["description"]
        @output.puts "Use when: #{data["use_when"]}" if data["use_when"]
        definition.parents.each { |parent| @output.puts "Extends: #{parent["id"]} (#{parent["source"]}, #{parent["path"]})" }
        @output.puts "Applies to: #{data["applies_to"].join(", ")}" if data["applies_to"].any?
        @output.puts "Inputs:" if data["inputs"].any?
        data["inputs"].each { |name, spec| @output.puts "  #{name}#{" (required)" if spec["required"]}#{": #{spec["description"]}" if spec["description"]}" }
        @output.puts "Steps:"
        data["steps"].each { |step| @output.puts "  #{step["id"].ljust(12)} #{step_traits(step)}".rstrip }
      end

      LIST_HEADER = ["ID", "SOURCE", "DESCRIPTION"].freeze

      # Lists every workflow definition the catalog can find, as a table of id, source
      # (project, global, source:N or builtin) and description (the definition's
      # `description:`, else its title). An unusable definition's description names its
      # first problem instead.
      #
      # @param json [Boolean]
      # @param project [String, nil] the project whose definitions come first
      # @return [void]
      def list(json: false, project: nil)
        entries = @catalog.list(project: project)
        return document("workflows" => entries) if json
        return @output.puts "No workflows." if entries.empty?

        rows = entries.map do |entry|
          description = if entry["problems"].any?
            "INVALID: #{entry["problems"].first}"
          else
            entry["description"] || entry["title"] || ""
          end
          [entry["id"], entry["source"], description]
        end
        print_grid(LIST_HEADER, rows)
      end

      # Checks a definition's text with the checks a definition on disk gets, and
      # writes nothing. +prompt_file:+ resolves against the file's directory for a
      # PATH and against the current directory for stdin.
      #
      # @param path [String] a file, or "-" for stdin
      # @param id [String, nil] the id to check it as; else a string `id:` in the text, else the file's name, else "stdin" for `-` or "file"
      # @param json [Boolean]
      # @param project [String, nil] the project whose definitions come first; `scope` and a `shadowed` warning say where PATH sits
      # @return [void]
      # @raise [Workspace::UsageError] when PATH can't be read
      # @raise [Workspace::Error] code `invalid_workflow`, with `details.problems` listing every problem
      #
      # A valid definition also prints its +warnings+ (text lines, or the `warnings` array in JSON) and what it could not check
      # (+not_checked+); neither changes the exit code.
      def validate(path:, id: nil, json: false, project: nil)
        stdin = path == "-"
        text = read_text(path, stdin)
        id ||= claimed_id(text) || (stdin ? STDIN_ID : file_id(path))
        lookup, chain = draft_lookup(id, text, project)
        definition = WorkflowDefinition.parse(text, id: id, source: stdin ? "stdin" : "file",
          path: stdin ? nil : File.expand_path(path), base_dir: stdin ? Dir.pwd : nil, parent_lookup: lookup, chain: chain)
        found = @lint.call(definition, cwd: Dir.pwd)
        scope = stdin ? nil : @catalog.scope_of(path, project: project)
        warnings = definition.warnings + found["warnings"] + shadow_warnings(definition.id, scope, project)
        if json
          document("workflow" => definition.to_h.merge("source" => definition.source, "scope" => scope, "path" => definition.path, "sha256" => definition.sha256, "resolved_sha256" => definition.resolved_sha256).merge(extends_field(definition)),
            "warnings" => warnings, "not_checked" => found["not_checked"])
        else
          @output.puts "#{definition.to_h["id"]}: valid (#{definition.steps.size} steps)#{", in the #{scope} definitions" if scope}"
          warnings.each { |warning| @output.puts "warning: #{TerminalText.escape(warning["message"])}" }
          found["not_checked"].each { |each| @output.puts "not checked: #{TerminalText.escape(each["message"])}" }
        end
      end

      # Prints the instructions a step's agent would be sent for its first attempt, composed
      # by {Workspace::WorkflowEngine#render}, and writes nothing. A missing required input is
      # refused as `start` refuses it (`input_required`): a prompt with its placeholders left
      # unfilled would read as a prompt that works.
      #
      # Text: the instructions on the output, byte for byte when it is not a terminal; on a
      # terminal control, bidi and zero-width characters (from a pack, a definition or an
      # input) are escaped through {Workspace::TerminalText}, line by line. Warnings and the
      # values that are previews go to the error output. With +json+ one document carries them all.
      #
      # @param id [String] a workflow id
      # @param step [String] a step id
      # @param workspace [String] the workspace the run would be in, or nil outside any
      # @param worktree [String] the checkout the packs and commands are read from
      # @param inputs [Hash{String=>String}]
      # @param json [Boolean]
      # @param project [String, nil] the project whose definitions are read first
      # @return [void]
      # @raise [Workspace::Error] code `unknown_workflow`, `invalid_workflow`, `unknown_step`, `input_required`, `invalid_input`, or a pack's
      def render(id:, step:, workspace:, worktree:, inputs: {}, json: false, project: nil)
        definition = @catalog.find(id, project: project)
        preview_workspace = workspace.nil?
        result = @engine.render(definition: definition, step: step, workspace: workspace || RENDER_WORKSPACE, worktree: worktree, inputs: inputs)
        previews = [{"name" => "run", "value" => result["run"]}, {"name" => "artifacts", "value" => result["artifacts_dir"]}]
        previews.insert(1, {"name" => "workspace", "value" => result["workspace"]}) if preview_workspace
        warnings = []
        warnings << {"code" => "not_in_checkout", "message" => "#{worktree} is not in a git checkout: the project's own packs and commands.test/commands.lint were not read."} unless result["in_checkout"]
        if json
          return document("workflow" => result["workflow"], "step" => result["step"], "workspace" => result["workspace"], "worktree" => result["worktree"],
            "inputs" => result["inputs"], "gate" => result["gate"], "packs" => result["packs"], "instructions_path" => result["instructions"],
            "previews" => previews, "warnings" => warnings, "text" => result["text"])
        end
        write_text(result["text"])
        warnings.each { |warning| @error_output.puts "warning: #{TerminalText.escape(warning["message"])}" }
        shown = previews.map { |each| "{{#{each["name"]}}} = #{TerminalText.escape(each["value"])}" }.join(", ")
        @error_output.puts "preview values, not a run's: #{shown}; the instructions file would be #{TerminalText.escape(result["instructions"])}."
        @error_output.puts "step #{TerminalText.escape(result["step"])} has gate: #{TerminalText.escape(result["gate"])}: the run waits for `workflow approve` after its turn ends." if result["gate"]
      end

      # Runs the `status:` command of a step once, outside any run (see {Workspace::WorkflowStepCheck}), in
      # +worktree+ with the environment a run gives it. The command comes from a catalog definition, so this
      # runs a shell command with the same trust as a run does. It takes no lock (the step's `uses:` is not
      # held) and writes no run file, event or binding.
      #
      # Text: the last {CHECK_TAIL_LINES} lines of the check's output on the output (escaped through
      # {Workspace::TerminalText} on a terminal), then one summary line on the error output. With +json+ one
      # document: `ok: true` (the check ran) and `passed`, the exit code, `timed_out`, the log and artifacts.
      #
      # @param id [String] a workflow id
      # @param step [String] a step id
      # @param worktree [String] the checkout the command runs in
      # @param artifacts [String, nil] an existing directory standing for the run's artifacts
      # @param json [Boolean]
      # @param project [String, nil] the project whose definitions are read first
      # @return [Hash{Symbol=>Integer}] `exit_code`: 0 when the check passed, 1 when it failed, timed out or could not start
      # @raise [Workspace::Error] code `unknown_workflow`, `invalid_workflow`, `unknown_step`,
      #   `step_without_status`, `workflow_command_unset`, `artifacts_not_directory`
      def check(id:, step:, worktree:, artifacts: nil, json: false, project: nil)
        raise Workspace::Error, "workflow check is not available: no step check was wired" unless @step_check
        result = @step_check.call(definition: @catalog.find(id, project: project), step: step, worktree: worktree, artifacts: artifacts)
        tail = log_tail(result["log"])
        if json
          document("workflow" => result["workflow"], "step" => result["step"], "worktree" => worktree, "passed" => result["passed"], "command" => result["command"],
            "exit_code" => result["exit_code"], "timed_out" => result["timed_out"], "error" => result["error"], "timeout" => result["timeout"],
            "duration" => result["duration"], "log" => result["log"], "artifacts" => result["artifacts"], "artifacts_created" => result["artifacts_created"],
            "base_sha" => result["base_sha"], "tail" => tail,
            "warnings" => result["in_checkout"] ? [] : [{"code" => "not_in_checkout", "message" => "#{worktree} is not in a git checkout."}])
        else
          write_text(tail)
          @error_output.puts "warning: #{TerminalText.escape(worktree)} is not in a git checkout." unless result["in_checkout"]
          @error_output.puts check_summary(result)
        end
        {exit_code: result["passed"] ? 0 : 1}
      end

      # Plays a workflow through the real engine with the scripted fake agent in +script+ and prints the
      # transitions (see {Workspace::WorkflowSimulator}). It makes no real run, pane, lock, inbox item or
      # notification, and writes only to a temporary directory it removes. A simulated stop (a failed check,
      # a spent budget) is the answer, not an error: the exit code is 0.
      #
      # @param id [String] a workflow id
      # @param script [String] the path of the script file
      # @param inputs [Hash{String=>String}] input values; they win over the script's `inputs:`
      # @param json [Boolean]
      # @param project [String, nil] the project whose definitions are read first
      # @return [void]
      # @raise [Workspace::Error] code `unknown_workflow`, `invalid_workflow`, `invalid_script`, `input_required`, `invalid_input`
      # @raise [Workspace::UsageError] when the script can't be read
      def simulate(id:, script:, inputs: {}, json: false, project: nil)
        raise Workspace::Error, "workflow simulate is not available: no simulator was wired" unless @simulator
        definition = @catalog.find(id, project: project)
        parsed = WorkflowSimScript.parse(read_script(script), definition: definition.to_h, source: script)
        result = @simulator.call(definition: definition, script: parsed, inputs: inputs)
        return document(result.merge("script" => script)) if json
        print_simulation(result, script)
      end

      # Saves a definition as a user's file, `ID.yml` in the workflows directory, after
      # the checks `validate` runs. A relative `prompt_file:` is read from that directory,
      # where the file will be loaded. A preset of the same id is allowed: the copy shadows it.
      #
      # @param id [String] the workflow's id; a string `id:` in the text must match it
      # @param path [String] a file, or "-" for stdin
      # @param dry_run [Boolean] run every check (the file's existence under its lock) and write no definition; the directory and lock file may be created
      # @param project [String, nil] the project the caller is in (see {Workspace::WorkflowProject}); definitions stay in the user's config and these write only its workflows directory
      # @return [Hash{String=>Object}] the action row: outcome "added" or "dry_run", with "workflow", "path" and "sha256"
      # @raise [Workspace::UsageError] when PATH can't be read
      # @raise [Workspace::Error] code `invalid_workflow` (a bad id, or text that doesn't pass), `workflow_exists`
      def add(id:, path:, dry_run: false, project: nil)
        @files.path(id)
        stdin = path == "-"
        text = read_text(path, stdin)
        lookup, chain = draft_lookup(id, text, project)
        WorkflowDefinition.parse(text, id: id, source: stdin ? "stdin" : "file", path: stdin ? nil : File.expand_path(path), base_dir: @files.dir, parent_lookup: lookup, chain: chain)
        found = @catalog.locate(id, project: project)
        written = @files.add(id, text, dry_run: dry_run)
        note = if found&.first == "project"
          "; the project definition at #{found.last} hides it in #{project}"
        elsif found&.first&.start_with?("source:")
          "; the source definition at #{found.last} shadows it"
        elsif found&.first == "builtin"
          "; it shadows the preset of the same id"
        end
        message = "#{dry_run ? "Would add" : "Added"} workflow #{id} at #{written["path"]}#{note}."
        @output.puts message
        {"workspace" => nil, "outcome" => dry_run ? "dry_run" : "added", "reason" => nil, "message" => message, "workflow" => id}.merge(written).merge(extended_by(id))
      end

      # Replaces a user's definition file when it is still the one the caller read. The new
      # text gets the checks `add` runs (a relative `prompt_file:` from the workflows directory);
      # the current file is only hashed, so a broken one can be replaced.
      #
      # @param id [String] the workflow's id
      # @param path [String] a file, or "-" for stdin
      # @param if_sha256 [String] the sha256 of the file's raw bytes, from `show ID --source --json` or `show --json`
      # @param dry_run [Boolean] run every check and write no definition
      # @param project [String, nil] the project the caller is in (see {Workspace::WorkflowProject}); definitions stay in the user's config and these write only its workflows directory
      # @return [Hash{String=>Object}] the action row: outcome "updated" or "dry_run", with "workflow", "path" and "sha256"
      # @raise [Workspace::UsageError] when PATH can't be read
      # @raise [Workspace::Error] code `invalid_workflow`, `unknown_workflow`, `builtin_workflow`, `stale_workflow`
      def update(id:, path:, if_sha256:, dry_run: false, project: nil)
        @files.path(id)
        stdin = path == "-"
        text = read_text(path, stdin)
        lookup, chain = draft_lookup(id, text, project)
        WorkflowDefinition.parse(text, id: id, source: stdin ? "stdin" : "file", path: stdin ? nil : File.expand_path(path), base_dir: @files.dir, parent_lookup: lookup, chain: chain)
        written = @files.update(id, text, if_sha256: if_sha256, dry_run: dry_run, project: project)
        hidden = @catalog.locate(id, project: project)
        note = "; the project definition at #{hidden.last} hides it in #{project}" if hidden&.first == "project"
        message = "#{dry_run ? "Would update" : "Updated"} workflow #{id} at #{written["path"]}#{note}."
        @output.puts message
        {"workspace" => nil, "outcome" => dry_run ? "dry_run" : "updated", "reason" => nil, "message" => message, "workflow" => id}.merge(written).merge(extended_by(id))
      end

      # Fetches the `workflows.sources` entries, checks every definition in each against the
      # lookup a run will use, and caches the GitHub ones under the state directory (a local
      # source is checked in place and never copied). A source with one invalid file is
      # refused whole and its cache keeps the version it had; the others still install.
      # Re-running updates: it reports what is new, changed or gone since the cached version.
      # Writes nothing to the user's workflows directory. To drop a source, unset it from
      # `workflows.sources` and delete its cache directory (the report prints the hint).
      #
      # @param source [Integer, nil] the 1-based position in `workflows.sources` of the one source to install; nil installs all
      # @return [Hash{String=>Object}] the action row: outcome "installed", "unchanged" or "failed" (a source was refused),
      #   with "sources" (a row each) and "warnings"
      # @raise [Workspace::UsageError] when +source+ is not a position in the list
      # @raise [Workspace::Error] code `workflow_source_invalid`, `workflow_source_local_missing`, `workflow_source_gh_missing`, `workflow_source_failed`
      def install(source: nil)
        raise Workspace::Error, "workflow install is not available: no source installer was wired" unless @source_installer
        result = @source_installer.install(only: source)
        rows = result["sources"]
        outcome = if result["failed"]
          "failed"
        elsif rows.any? { |row| row["outcome"] == "installed" }
          "installed"
        else
          "unchanged"
        end
        if rows.empty?
          message = "No workflows.sources are set; add one with `workspace config set workflows.sources`."
          @output.puts message
        else
          rows.each { |row| print_install_row(row) }
          cached = rows.reject { |row| row["kind"] == "local" }.map { |row| row["path"] }
          @output.puts "To stop using a source, remove it from workflows.sources (`workspace config set workflows.sources`) and delete #{cached.map { |each| TerminalText.escape(each) }.join(", ")}." if cached.any?
          message = "#{rows.count { |row| row["outcome"] != "refused" }} of #{rows.size} workflow sources installed."
        end
        result["warnings"].each { |warning| @error_output.puts "warning: #{TerminalText.escape(warning["message"])}" }
        {"workspace" => nil, "outcome" => outcome, "reason" => nil, "message" => message, "sources" => rows, "warnings" => result["warnings"]}
      end

      # Deletes every workflow installed from the `workflows.sources` entries (a GitHub
      # source's cache directory), leaving the presets and the user's own files in place. A
      # local source is only reported: it is read where it is, so there is nothing to
      # remove. The entries stay listed in `workflows.sources`; the report says how to drop
      # them too. Without +yes+ (and not a dry run) it asks first; "y" confirms.
      #
      # @param yes [Boolean] skip the prompt
      # @param dry_run [Boolean] report and delete nothing; needs no +yes+
      # @param json [Boolean]
      # @return [Hash{String=>Object}, nil] the action row: outcome "uninstalled",
      #   "dry_run" or "unchanged", with "sources" (a row each); nil when the prompt was declined
      def uninstall(yes: false, dry_run: false, json: false)
        unless yes || dry_run
          answer = Prompt.ask(@input, @output, "Uninstall every workflow installed from workflows.sources? [y/N] ", retry_flags: ["--yes"], destructive: true)
          unless answer.to_s.strip.casecmp?("y")
            @output.puts "Cancelled."
            return nil
          end
        end
        result = @source_installer.uninstall(dry_run: dry_run)
        rows = result["sources"]
        removed = result["removed"]
        outcome = if dry_run
          "dry_run"
        elsif removed.zero?
          "unchanged"
        else
          "uninstalled"
        end
        message = if rows.empty?
          "No workflows.sources are set; nothing is installed from a source."
        elsif removed.positive?
          "#{dry_run ? "Would remove" : "Removed"} #{removed} of #{rows.size} source caches. The entries stay in workflows.sources; unset them with `workspace config unset workflows.sources`."
        else
          suffix = dry_run ? " (dry run)" : ""
          "Nothing to remove#{suffix}: no GitHub source has a cache."
        end
        @output.puts message
        rows.each do |row|
          note = {"local" => "read in place; nothing to remove", "absent" => "no cache", "invalid" => "not a usable source", "dry_run" => "would remove", "removed" => "removed"}.fetch(row["outcome"], row["outcome"])
          @output.puts "  source:#{row["index"]} #{TerminalText.escape(row["source"])}: #{note}"
        end
        {"workspace" => nil, "outcome" => outcome, "reason" => nil, "message" => message, "sources" => rows}
      end

      # Refuses, before anyone is asked anything, an id that has no file of the user's.
      #
      # @param id [String]
      # @param project [String, nil] the project the caller is in
      # @return [void]
      # @raise [Workspace::Error] code `invalid_workflow`, `builtin_workflow`, `unknown_workflow`
      def check_removable(id:, project: nil)
        @files.ensure_present(id, project: project)
      end

      # Deletes a user's definition file. Without +yes+ (and not a dry run) it asks first,
      # before the file's lock is taken; "y" confirms, anything else answers nothing. A preset of
      # the same id is untouched and is in effect again, unless the project (+project+) has its own definition of the id.
      #
      # @param id [String] the workflow's id
      # @param yes [Boolean] skip the prompt
      # @param dry_run [Boolean] run every check and delete nothing; needs no +yes+
      # @param project [String, nil] the project the caller is in (see {Workspace::WorkflowProject}); definitions stay in the user's config and these write only its workflows directory
      # @return [Hash{String=>Object}, nil] the action row: outcome "removed" or "dry_run", with "workflow" and "path"; nil when the prompt was declined
      # @raise [Workspace::Error] code `invalid_workflow`, `unknown_workflow`, `builtin_workflow`, `confirmation_required` (input is off)
      def remove(id:, yes: false, dry_run: false, project: nil)
        check_removable(id: id, project: project)
        target = @files.path(id)
        affected = extended_by(id)
        unless yes || dry_run
          answer = Prompt.ask(@input, @output, "Remove workflow #{id} (#{target})? [y/N] ", retry_flags: ["--yes"], destructive: true)
          unless answer.to_s.strip.casecmp?("y")
            @output.puts "Cancelled."
            return nil
          end
        end
        removed = @files.remove(id, dry_run: dry_run, project: project)
        after = if removed["project_path"]
          "; the project definition at #{removed["project_path"]} stays in effect in #{project}"
        elsif removed["preset"]
          "; the preset of the same id is in effect again"
        end
        message = "#{dry_run ? "Would remove" : "Removed"} workflow #{id} at #{removed["path"]}#{after}."
        @output.puts message
        {"workspace" => nil, "outcome" => dry_run ? "dry_run" : "removed", "reason" => nil, "message" => message, "workflow" => id, "path" => removed["path"]}.merge(affected)
      end

      # Starts a run of a workflow in a workspace.
      #
      # @param id [String] the workflow
      # @param workspace [String]
      # @param worktree [String] the workspace's checkout
      # @param inputs [Hash{String=>String}]
      # @param pane [String, nil] the pane to run in (a pane id or `window.pane`); nil for the workspace's Claude pane
      # @param note [String, nil] added to every step's instructions
      # @param dry_run [Boolean] check everything and start nothing
      # @param project [String, nil] the project whose definitions are read first
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`); a run for that pane is
      #   created and parked, so nothing is typed into the caller
      # @param fill_from_branch [Boolean] fill +task+ and +pr+ from the branch checked out at +worktree+ when not
      #   given; only the CLI's `workflow run` passes true, and only for a checkout it resolved
      # @return [Hash{String=>Object}] the action row, with `inputs_from` (which inputs the branch filled);
      #   `outcome` is "parked" for a run parked from its own pane
      # @raise [Workspace::Error] see {Workspace::WorkflowEngine#preflight}
      def run(id:, workspace:, worktree:, inputs: {}, pane: nil, note: nil, dry_run: false, caller_pane: nil, project: nil, fill_from_branch: false)
        definition = @catalog.find(id, project: project)
        filled, from = (fill_from_branch && @branch_inputs) ? @branch_inputs.call(definition, worktree, inputs) : [inputs, {}]
        if dry_run
          pane_id = pane ? @panes.locate(workspace, pane) : @panes.default_pane(workspace, start_daemon: false)
          checked = @engine.preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: filled, pane: pane_id)
          line = "Would start #{id} in #{workspace} at step #{checked["step"]}" \
            "#{pane_id ? " in pane #{pane_id}" : " (its agent daemon is not running; starting the run starts it and picks the Claude pane)"}." \
            "#{fill_sentence(filled, from)}"
          @output.puts line
          return {"workspace" => workspace, "outcome" => "dry_run", "reason" => nil, "message" => line, "workflow" => id,
                  "step" => checked["step"], "pane" => pane_id, "inputs" => checked["inputs"], "packs" => checked["packs"], "inputs_from" => from}
        end
        pane_id = pane ? @panes.locate(workspace, pane) : @panes.default_pane(workspace)
        if caller_in_pane?(workspace, caller_pane, pane_id) && @panes.parkable?(workspace, pane_id)
          created = @engine.start(definition: definition, workspace: workspace, worktree: worktree, inputs: filled, pane: pane_id, note: note, dispatch: false)
          return park_resume(WorkflowRun.from_h(created), from: nil, note: nil, pane: nil, target: pane_id, turn_over: nil).merge("inputs_from" => from)
        end
        row(@engine.start(definition: definition, workspace: workspace, worktree: worktree, inputs: filled, pane: pane_id, note: note), "started").merge("inputs_from" => from)
      end

      # Prints where runs stand: one run, or the runs of a scope.
      #
      # @param run [String, nil] a run id
      # @param scope [Workspace::StatusScope::Scope, nil] `:workspace` lists that workspace's
      #   runs still going, `:project` all of a project's runs, `:all` every run; nil is `:all`
      # @param json [Boolean]
      # @param hint [Boolean] when a workspace has no run going, say where finished runs are
      # @param table [Boolean] one row per run with its workspace's status and what exists, finished runs at every scope
      # @return [void]
      # @raise [Workspace::Error] code `unknown_run`
      def status(run: nil, scope: nil, json: false, hint: true, table: false)
        return needs_me(scope, json) if scope&.kind == :needs_me
        result = if run
          @status.run(run)
        elsif scope&.kind == :workspace
          @status.runs(workspace: scope.workspace, all: table)
        elsif scope&.kind == :project
          @status.in_project(scope.project)
        else
          @status.runs(workspace: nil, all: true)
        end
        return status_table(result, scope, run, json) if table
        return document("generated_at" => @clock.call.utc.iso8601, "runs" => result["runs"], "warnings" => result["warnings"]) if json
        @output.puts status_empty_text(scope, hint) if result["runs"].empty? && !run
        result["runs"].each { |each| describe(each) }
        result["warnings"].each { |warning| @output.puts "Warning: #{warning}" }
      end

      # Prints a run's history, oldest first, going or finished.
      #
      # @param run [String] a run id
      # @param since [Integer] only events on lines after this line number
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `unknown_run`
      def events(run:, since: 0, json: false)
        result = @store.events(run, since: since)
        return document("run" => run, "events" => result["events"], "truncated" => result["truncated"], "next_since" => result["next_since"], "warnings" => result["warnings"]) if json
        @output.puts "No events#{" after line #{since}" if since.positive?} for #{run}." if result["events"].empty?
        result["events"].each do |event|
          rest = event.except("n", "ts", "type").map { |key, value| "#{key}=#{(value.is_a?(String) && !value.match?(/[[:cntrl:]]/)) ? value : JSON.generate(value)}" }
          @output.puts [event["n"].to_s.rjust(4), event["ts"], event["type"], *rest].join("  ")
        end
        @output.puts "More events follow: pass --since #{result["next_since"]}." if result["truncated"]
        result["warnings"].each { |warning| @output.puts "Warning: #{warning}" }
      end

      # Prints the files a run keeps (each attempt's prompt and check log, each
      # step's `produces` entries) and whether each exists. Reads file metadata
      # only; a symlink is reported as a link and never followed.
      #
      # @param run [String] a run id
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `unknown_run`
      def files(run:, json: false)
        record = @store.run(run)
        rows = @run_files.list(record)
        return document("run" => run, "artifacts_dir" => @run_files.artifacts_dir(record), "files" => rows) if json
        @output.puts "No files recorded for #{run}." if rows.empty?
        rows.each do |file|
          state = if file["link"]
            "link"
          else
            (file["exists"] ? "#{file["bytes"]} bytes" : "missing")
          end
          @output.puts [file["kind"].ljust(9), file["step"], file["attempt"] ? "attempt #{file["attempt"]}" : "-", state, file["path"]].join("  ")
        end
      end

      # Prints the attempts a run recorded, going or finished, oldest first. Reads the
      # run file and writes nothing; a key an old run never recorded is `null`.
      #
      # @param run [String] a run id
      # @param step [String, nil] only this step's attempts
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `unknown_run`, or `unknown_step` for a +step+ the run doesn't have
      def attempts(run:, step: nil, json: false)
        raise Workspace::Error, "workflow attempts is not available: no attempts reader was wired" unless @attempts
        result = @attempts.read(@store.run(run), step: step)
        return document("run" => run, "attempts" => result["attempts"], "unowned_reasons" => result["unowned_reasons"]) if json
        @output.puts "No attempts recorded for #{run}#{" step #{TerminalText.escape(step)}" if step}." if result["attempts"].empty?
        unless result["attempts"].empty?
          table = [%w[STEP ATTEMPT OUTCOME CODE HEAD DURATION TOKENS]] + result["attempts"].map { |each| attempt_cells(each) }
          widths = table.transpose.map { |column| column.map(&:length).max }
          table.each { |cells| @output.puts cells.each_with_index.map { |cell, index| cell.ljust(widths[index]) }.join("  ").rstrip }
        end
        result["unowned_reasons"].each do |reason|
          @output.puts "Reason outside any attempt: #{[reason["step"], reason["code"], reason["since"], reason["until"] || "now"].map { |each| TerminalText.escape(each) }.join("  ")}"
        end
      end

      STATS_HEADER = %w[STEP ATTEMPTS PASSED FAILED MEDIAN RESUMES TOKENS/RUN].freeze

      # Prints how each step of a workflow went across its runs, going and finished (see {Workspace::WorkflowStats}
      # for what every figure means). Reads the run files and their histories and writes nothing.
      #
      # @param workflow [String] a definition id; it need not exist now, only the runs matter
      # @param last [Numeric, nil] only runs started in the last this many seconds
      # @param last_text [String, nil] the `--last` text, to say the window back
      # @param scope [Workspace::StatusScope::Scope, nil] narrows to one workspace or project; nil is every workspace
      #   (and the definition is looked up with no project)
      # @param json [Boolean]
      # @return [Hash] `exit_code` 3 when a run file could not be read (the figures are then incomplete), else 0
      def stats(workflow:, last: nil, last_text: nil, scope: nil, json: false)
        raise Workspace::Error, "workflow stats is not available: no stats reader was wired" unless @stats
        include = scope_filter(scope)
        result = @stats.read(workflow: workflow, last: last, include: include)
        partial = result["unreadable"].positive?
        definition = current_definition(workflow, scope)
        if json
          document("workflow" => workflow, "status" => partial ? "partial" : "ok", "last" => last_text,
            "since" => last && (@clock.call - last).utc.iso8601, "workspace" => scope&.workspace, "project" => scope&.project&.name,
            "definition" => definition, "runs" => result["runs"], "unreadable" => result["unreadable"], "undated" => result["undated"],
            "unattributed_resumes" => result["unattributed_resumes"], "steps" => result["steps"])
        else
          print_stats(workflow, last_text, result)
          @output.puts "The definition now in effect is a project definition (#{TerminalText.escape(definition["path"])})." if definition && definition["source"] == "project"
        end
        {exit_code: partial ? 3 : 0}
      end

      COMPARE_HEADER = %w[SHA RUNS PASS-1ST RESUMES/RUN].freeze

      # Prints the runs of a workflow in groups by definition or pack text, side by side (see
      # {Workspace::WorkflowCompare} for what a run counts under and what PASS-1ST means), and always the
      # warning that this shows a direction and proves nothing. Reads the run files and writes nothing.
      #
      # @param workflow [String] a definition id; it need not exist now
      # @param by [String] "definition" or "pack:NAME"
      # @param last [Numeric, nil] only runs started in the last this many seconds
      # @param last_text [String, nil] the `--last` text
      # @param scope [Workspace::StatusScope::Scope, nil] narrows to one workspace or project
      # @param json [Boolean]
      # @return [Hash] `exit_code` 3 when a run file could not be read, else 0
      # @raise [Workspace::UsageError] for a `by` that is not `definition` or `pack:NAME`
      def compare(workflow:, by: "definition", last: nil, last_text: nil, scope: nil, json: false)
        raise Workspace::Error, "workflow compare is not available: no compare reader was wired" unless @compare
        result = @compare.read(workflow: workflow, by: by, last: last, include: scope_filter(scope))
        partial = result["unreadable"].positive?
        if json
          document("workflow" => workflow, "status" => partial ? "partial" : "ok", "last" => last_text,
            "since" => last && (@clock.call - last).utc.iso8601, "workspace" => scope&.workspace, "project" => scope&.project&.name,
            **result)
        else
          print_compare(workflow, last_text, result)
        end
        {exit_code: partial ? 3 : 0}
      end

      # Checks the evidence copies a run kept against the hashes recorded for them, going or
      # finished. Reads the run file and the evidence directory and writes nothing.
      #
      # @param run [String] a run id
      # @param step [String, nil] only this step's attempts
      # @param json [Boolean]
      # @return [Hash] `exit_code`: 0 when no copy mismatched, 1 when one is changed, missing or replaced
      # @raise [Workspace::Error] code `unknown_run`, or `unknown_step` for a +step+ the run doesn't have
      def audit(run:, step: nil, json: false)
        raise Workspace::Error, "workflow audit is not available: no audit reader was wired" unless @audit
        result = @audit.read(@store.run(run).to_h, step: step)
        if json
          document("run" => run, "step" => step, "clean" => result["clean"], "counts" => result["counts"], "directory" => result["directory"],
            "files" => result["files"], "without_evidence" => result["without_evidence"])
        else
          print_audit(run, step, result)
        end
        {exit_code: result["clean"] ? 0 : 1}
      end

      # One pass over the runs still going (see {Workspace::WorkflowSweep}): records the ones whose pane or
      # agent is gone, starts a workspace's agent daemon that is not running, decides a step whose agent ended
      # its turn unseen, and applies `on_timeout` to a step past its `timeout`. Prints a line for each run it
      # acted on or noted. Needs no agent daemon, and leaves a run alone when this process runs in its pane.
      #
      # @param run [String, nil] only this run
      # @param name [String, nil] only this workspace's runs
      # @param dry_run [Boolean] say what would be done and do nothing
      # @param json [Boolean] the caller prints the action document, so no count line is written
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [Hash{Symbol=>Object}] `exit_code` (1 when a result is `failed`: the action document turns that into 3 or 1),
      #   `results` (the rows) and, for a dry run, `status`
      # @raise [Workspace::Error] code `unknown_run`
      def sweep(run: nil, name: nil, dry_run: false, json: false, caller_pane: nil)
        raise Workspace::Error, "workflow sweep is not available: no sweep was wired" unless @sweep
        allow = lambda do |stored|
          refuse_caller!(WorkflowRun.from_h(stored), caller_pane, "workflow sweep", "A run is moved by a person or the sweep, not by its own agent")
          nil
        rescue Workspace::Error => e
          raise unless e.code == "bound_pane"
          e.message.lines.first.to_s.strip
        end
        rows = @sweep.call(run: run, workspace: name, dry_run: dry_run, allow: allow)
        print_sweep(rows, summary: !json)
        {exit_code: ((rows.any? { |each| each["outcome"] == "failed" }) ? 1 : 0), results: rows, status: (dry_run ? "dry_run" : nil)}
      end

      # `workflow sweep --install`, `--uninstall` or `--installed`: the opt-in launchd
      # entry that runs the sweep every five minutes. Changes nothing unless asked.
      #
      # @param action [Symbol] `:install`, `:uninstall` or `:status`
      # @param dry_run [Boolean] say what would be done and change nothing
      # @return [Hash] the outcome for `run_action`: `exit_code` and `results` (one row)
      # @raise [Workspace::Error] see {Workspace::SweepSchedule}
      def schedule(action, dry_run: false)
        raise Workspace::Error, "workflow sweep --install is not available: no schedule was wired" unless @schedule
        row = case action
        when :install then @schedule.install(dry_run: dry_run)
        when :uninstall then @schedule.uninstall(dry_run: dry_run)
        else @schedule.status
        end
        @output.puts row["message"]
        {exit_code: 0, results: [row], status: ((row["outcome"] == "dry_run") ? "dry_run" : nil)}
      end

      # Gets a run going again. Everything the engine would refuse is refused
      # first; only then is a daemon started or a pane picked.
      #
      # @param run [String] a run id
      # @param from [String, nil] start again at this step
      # @param note [String, nil] added to the next attempt's instructions
      # @param pane [String, nil] move the run to this pane of its workspace
      # @param extra_attempts [Integer, nil] add this to the run's attempt allowance
      # @param extra_tokens [Integer, nil] add this to the run's token budget (see {Workspace::WorkflowEngine#resume})
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [Hash{String=>Object}] the action row; `outcome` is "unchanged" when an agent
      #   is working on the step or its check is still running
      # @raise [Workspace::Error] code `bound_pane` for `--from` at a waiting gate from a pane
      #   bound to a run, or see {Workspace::WorkflowEngine#resume}
      def resume(run:, from: nil, note: nil, pane: nil, extra_attempts: nil, extra_tokens: nil, caller_pane: nil)
        stored = @store.run(run)
        pane_id = nil
        turn_over = nil
        unless WorkflowRunStore::TERMINAL_STATES.include?(stored.state)
          state = stored.steps.fetch(stored.current)
          refuse_bound_pane!(caller_pane, "workflow resume --from") if from && state.gate_waiting?
          refuse_caller!(stored, caller_pane, "workflow resume", "A guarded or checked step is resumed by a person") if from.nil? && checked_step?(stored)
          @engine.refuse_resume(stored.to_h, from: from)
          pane_id = resume_pane(stored, pane)
          if pane_id.nil? && from.nil? && state.state == "running" && stored.reason.nil? &&
              @panes.idle?(stored.workspace, @panes.pane_of(run) || stored.pane)
            turn_over = {"step" => stored.current, "attempt" => state.last_attempt&.n}
          end
        end
        target = pane_id || @panes.pane_of(run) || stored.pane
        if !WorkflowRunStore::TERMINAL_STATES.include?(stored.state) && caller_in_pane?(stored.workspace, caller_pane, target) &&
            @panes.parkable?(stored.workspace, target)
          return park_resume(stored, from: from, note: note, pane: pane_id, target: target, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens)
        end
        resumed = @engine.resume(run, from: from, note: note, pane: pane_id, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens)
        row(resumed, resumed["unchanged"] ? "unchanged" : "resumed", message: resumed["unchanged"] && "Nothing was done: #{resumed["unchanged"]}.")
      end

      # @param run [String] a run id
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
      def cancel(run:)
        row(@engine.cancel(run), "cancelled")
      end

      # Passes a gate. Refused from a pane a run is bound to, and from a
      # process under the run's own pane, so an agent can't pass its own gate.
      #
      # @param run [String] a run id
      # @param note [String, nil] added to the next step's instructions
      # @param step [String, nil] the gated step the caller saw
      # @param attempt [Integer, nil] that step's attempt the caller saw
      # @param note_sha256 [String, nil] the sha256 of the gate's note the caller read
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `bound_pane`, or see {Workspace::WorkflowEngine#approve}
      def approve(run:, note: nil, step: nil, attempt: nil, note_sha256: nil, caller_pane: nil)
        guard = ->(stored) { refuse_caller!(WorkflowRun.from_h(stored), caller_pane, "workflow approve") }
        row(@engine.approve(run, note: note, step: step, attempt: attempt, note_sha256: note_sha256, guard: guard), "approved")
      end

      # Turns a gate down, refused where {#approve} is.
      #
      # @param run [String] a run id
      # @param note [String] why
      # @param to [String, nil] the step to run again
      # @param step [String, nil] the gated step the caller saw
      # @param attempt [Integer, nil] that step's attempt the caller saw
      # @param extra_attempts [Integer, nil] add this to the run's attempt allowance
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `bound_pane`, or see {Workspace::WorkflowEngine#reject}
      def reject(run:, note:, to: nil, step: nil, attempt: nil, extra_attempts: nil, extra_tokens: nil, caller_pane: nil)
        guard = ->(stored) { refuse_caller!(WorkflowRun.from_h(stored), caller_pane, "workflow reject") }
        row(@engine.reject(run, note: note, to: to, step: step, attempt: attempt, guard: guard, extra_attempts: extra_attempts, extra_tokens: extra_tokens), "rejected")
      end

      # What the agent daemon runs when a turn ends in a bound pane, and on
      # its timer for a run nothing else would wake. A parked resume is looked at
      # here, by either: it is carried out once the turn in its pane is proven over,
      # and ended when the pane or its agent is gone or its time is up. Prints nothing.
      #
      # @param run [String] a run id
      # @param turn_ended [Boolean] a turn ended; false is the timer's look
      # @param pane [String, nil] the pane the turn ended in
      # @param turn_started [Time, nil] when the turn that ended began, when the daemon knows
      # @param stopped_at [Time, nil] when the daemon saw the turn end
      # @param background [Array<Hash>, nil] the tasks (`"id"`, `"type"`) the Stop listed as still going
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [void]
      # @raise [Workspace::Error] code `bound_pane` for a step with a guard or a status check, from a pane
      #   bound to the run or a process under it
      def advance(run:, turn_ended: false, pane: nil, turn_started: nil, stopped_at: nil, background: nil, caller_pane: nil)
        stored = begin
          @store.run(run)
        rescue Workspace::Error
          nil
        end
        # The agent daemon runs this as a process of its own. Run from the agent's pane, it would let
        # the agent decide its own step, with a fake `git` first on PATH for the guard.
        if stored && checked_step?(stored)
          refuse_caller!(stored, caller_pane, "workflow advance", "A guarded or checked step is decided by the agent daemon")
        end
        return release_parked(stored, caller_pane) if stored&.parked
        turn_ended ? @engine.turn_ended(run, pane: pane, turn_started: turn_started, stopped_at: stopped_at, background: background || []) : @engine.tick(run)
        nil
      end

      # The agent's own report on its step (`step done`).
      #
      # @param pane [String, nil] the pane the agent runs in (`$TMUX_PANE`)
      # @param status [String] "pass" or "fail"
      # @param summary [String, nil]
      # @param code [String, nil] a word for why, matching {WorkflowDefinition::CODE_PATTERN} (`usage` otherwise)
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `not_bound` outside a run's pane, `step_not_running`
      def step_done(pane:, status: "pass", summary: nil, code: nil)
        raise UsageError, "--status must be pass or fail, got #{status.to_s[0, 40].inspect}." unless REPORT_STATUSES.include?(status)
        raise UsageError, "--code must be a lowercase word that starts with a letter, then letters, digits and underscores (at most 40), got #{code.to_s[0, 60].inspect}." unless code.nil? || WorkflowDefinition::CODE_PATTERN.match?(code)
        if (refusal = WorkflowDefinition.engine_code_refusal(code))
          raise UsageError, "--code #{refusal}"
        end
        run_id = bound_run!(pane)
        reported = @engine.report(run_id, status: status, summary: summary, code: code)
        @output.puts "Recorded #{status} for step #{reported["step"]} (attempt #{reported["attempt"]}) of run #{run_id}. " \
          "End your turn now; the step is decided when the turn ends."
        {"workspace" => @store.run(run_id).workspace, "outcome" => "recorded", "reason" => nil, "message" => nil, "run_id" => run_id,
         "step" => reported["step"], "attempt" => reported["attempt"], "reported" => reported["reported"].slice("status", "summary", "code")}
      end

      # Prints the step the calling pane is on (`step status`).
      #
      # @param pane [String, nil] the pane the agent runs in (`$TMUX_PANE`)
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `not_bound` outside a run's pane
      def step_status(pane:, json: false)
        run = @store.run(bound_run!(pane))
        step = run.definition["steps"].find { |each| each["id"] == run.current }
        state = run.steps.fetch(run.current)
        attempt = state.last_attempt || WorkflowRun::Attempt.from_h({})
        started = attempt.started_at && Time.iso8601(attempt.started_at)
        strict = Workspace::WorkflowProduced.strict?(run.definition)
        produces = step["produces"].map { |file| File.join(run.artifacts_dir, file) }.map do |path|
          # A file an earlier attempt left has to be written again to count.
          found = Workspace::WorkflowProduced.inspect_file(path, strict: strict)
          {"path" => path, "exists" => found.exists, "problem" => found.rule, "current" => found.current?(started) == true}
        end
        info = {"run_id" => run.id, "workflow" => run.workflow, "workspace" => run.workspace, "step" => run.current,
                "attempt" => attempt.n, "state" => state.state, "instructions" => attempt.prompt_file,
                "artifacts_dir" => run.artifacts_dir, "produces" => produces, "check" => !step["status"].nil?,
                "reported" => attempt.reported&.slice("status", "summary")}
        info["proofs"] = attempt.proofs if attempt.proofs
        return document("step" => info) if json
        @output.puts "Step #{info["step"]} (attempt #{info["attempt"]}, #{info["state"]}) of workflow run #{info["run_id"]} (#{info["workflow"]}) in #{info["workspace"]}."
        @output.puts "Instructions: #{info["instructions"]}" if info["instructions"]
        produces.each do |file|
          found = if file["current"]
            "there"
          elsif file["problem"]
            PRODUCES_PROBLEMS.fetch(file["problem"], file["problem"])
          else
            file["exists"] ? "left by an earlier attempt; write it again" : "missing"
          end
          @output.puts "Must be written by the time your turn ends: #{file["path"]} (#{found})"
        end
        @output.puts "When your turn ends, the runner runs the step's check." if info["check"]
        @output.puts "Reported: #{info["reported"]["status"]}#{" (#{info["reported"]["summary"]})" if info["reported"]["summary"]}" if info["reported"]
      end

      private

      # The last {CHECK_TAIL_LINES} lines of a check log, read from its last 64 KiB.
      def log_tail(path)
        text = File.open(path, "rb") do |file|
          file.seek([file.size - 65_536, 0].max)
          file.read
        end.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        text.lines.last(CHECK_TAIL_LINES).join
      rescue SystemCallError
        ""
      end

      def check_summary(result)
        how = if result["timed_out"] then "timed out after #{result["timeout"]}s"
        elsif result["error"] then TerminalText.escape(result["error"])
        else "exit #{result["exit_code"]}"
        end
        made = result["artifacts_created"] ? " (made for this check, empty)" : ""
        "step #{TerminalText.escape(result["step"])} check #{result["passed"] ? "passed" : "failed"}: #{how}, #{result["duration"]}s; log #{TerminalText.escape(result["log"])}; " \
          "artifacts #{TerminalText.escape(result["artifacts"])}#{made}"
      end

      # The script's text, read as bytes so that a file that is not UTF-8 is a problem the script check lists.
      def read_script(path)
        raise UsageError, "Can't read #{path}: not a regular file" unless File.stat(path).file?
        File.binread(path, WorkflowSimScript::MAX_BYTES + 1).to_s.dup.force_encoding(Encoding::UTF_8)
      rescue SystemCallError => e
        raise UsageError, "Can't read #{path}: #{e.message.sub(/ (@ .*)?- .*\z/, "")}"
      end

      # The text of `simulate`: the outcome, the history as it happened, then each step's attempts and the budget.
      def print_simulation(result, script)
        @output.puts "Simulated #{TerminalText.escape(result["workflow"])} with #{TerminalText.escape(script)}: #{result["actions"]} actions, outcome #{result["outcome"]}."
        if result["capped"]
          @output.puts "The simulation was cut off after #{result["max_actions"]} actions (the cap) with the run still going; the history below is what happened before that."
        elsif (stopped = result["stopped"])
          at = "step #{TerminalText.escape(stopped["step"])}#{", attempt #{stopped["attempt"]}" if stopped["attempt"]}"
          @output.puts "The run stopped at #{at}, waiting for a person: #{TerminalText.escape(stopped["reason"] || "no reason stored")}."
        end
        @output.puts ""
        result["transitions"].each do |event|
          details = event.except("n", "at", "type").map { |key, value| "#{key}=#{TerminalText.escape(value.is_a?(String) ? value : JSON.generate(value))}" }
          @output.puts "  #{format("%3d", event["n"])}  +#{event["at"]}s  #{TerminalText.escape(event["type"])}#{"  #{details.join(" ")}" unless details.empty?}"
        end
        @output.puts ""
        result["steps"].each do |step|
          outcomes = step["attempts"].map { |each| "#{each["outcome"] || "unfinished"}#{" (#{each["code"]})" if each["code"]}" }
          @output.puts "#{TerminalText.escape(step["id"])}: #{step["attempts"].size} attempt#{"s" unless step["attempts"].size == 1}#{": #{outcomes.join(", ")}" unless outcomes.empty?}"
        end
        if (budget = result["budget"])
          @output.puts "tokens: #{budget["used"]} of #{budget["allowance"]} used#{" (spent)" if budget["spent"]}"
        end
        @output.puts "Nothing ran: status checks and require proofs came from the script, and no real run, pane, lock or inbox item was made."
      end

      # The instructions to the output: as they are to a pipe or file, with each line escaped on a terminal.
      def write_text(text)
        return @output.write(text) unless @output.respond_to?(:tty?) && @output.tty?
        text.each_line { |line| @output.write(TerminalText.escape(line.chomp, keep_tabs: true) + (line.end_with?("\n") ? "\n" : "")) }
      end

      # The text of `audit`: one row per recorded file, then the attempts with no evidence and where the copies are.
      def print_audit(run, step, result)
        files = result["files"]
        if files.empty? && result["without_evidence"].empty?
          @output.puts "No attempts recorded for #{run}#{" step #{TerminalText.escape(step)}" if step}."
          return
        end
        unless files.empty?
          table = [%w[STEP ATTEMPT KIND STATUS NAME DETAIL]] + files.map { |each| audit_cells(each) }
          widths = table.transpose.map { |column| column.map(&:length).max }
          table.each { |cells| @output.puts cells.each_with_index.map { |cell, index| cell.ljust(widths[index]) }.join("  ").rstrip }
        end
        unless result["without_evidence"].empty?
          list = result["without_evidence"].map { |each| "#{TerminalText.escape(each["step"])} #{TerminalText.escape(each["attempt"])}" }.join(", ")
          @output.puts "No evidence recorded (the attempt predates it): #{list}"
        end
        counts = result["counts"].map { |status, count| "#{count} #{status}" }.join(", ")
        @output.puts "#{files.size} #{(files.size == 1) ? "file" : "files"}#{": " + counts unless counts.empty?}. #{result["clean"] ? "No copy differs from its record." : "A copy differs from its record."}"
        @output.puts "Evidence kept in #{TerminalText.escape(result["directory"].to_s)}/" if result["directory"]
      end

      # One text row of `audit`: step, attempt, kind, status, name, detail.
      def audit_cells(row)
        short = ->(sha) { sha&.[](0, 12) }
        detail = case row["status"]
        when "changed"
          if row["now_sha256"]
            "recorded #{short.call(row["recorded_sha256"])}, now #{short.call(row["now_sha256"])}"
          else
            row["reason"]
          end
        when "replaced", "not_copied", "too_large", "missing" then row["reason"]
        end
        detail = [detail, ("checkout copy differs" if row["source_status"] == "differs")].compact.join("; ")
        [row["step"], row["attempt"] || "-", row["kind"] || "-", row["status"].upcase.tr("_", " "), row["name"] || "-", detail.empty? ? "-" : detail].map { |cell| TerminalText.escape(cell) }
      end

      # One text row of `attempts`: step, attempt, outcome, code, head, duration, tokens.
      def attempt_cells(row)
        head = row["head"].is_a?(Hash) ? row["head"] : {}
        heads = [head["before"], head["after"]].map { |sha| sha.is_a?(String) ? sha[0, 7] : "-" }
        usage = row["usage"].is_a?(Hash) ? row["usage"] : nil
        tokens = usage ? "#{usage["input_tokens"]}/#{usage["output_tokens"]}" : "-"
        [row["step"], row["attempt"] || "-", (row["outcome"] || "-") + ((row["redelivered"] == true) ? " (retried)" : ""), attempt_code(row["code"]), heads.join(">"), attempt_duration(row), tokens].map { |cell| TerminalText.escape(cell) }
      end

      # The code as the table shows it: an agent-reported code has no length limit.
      def attempt_code(code)
        return "-" if code.nil?
        text = TerminalText.escape(code)
        (text.length > 40) ? "#{text[0, 39]}~" : text
      end

      def attempt_duration(row)
        seconds = Time.iso8601(row["ended_at"].to_s) - Time.iso8601(row["started_at"].to_s)
        (seconds >= 0) ? "#{seconds.round}s" : "-"
      rescue ArgumentError
        "-"
      end

      QUIET_SWEEP_REASONS = %w[healthy parked checking not_running finished held idle delivering prompt timed_out backoff pane_busy already_recorded].freeze

      def print_sweep(rows, summary:)
        shown = rows.reject { |each| each["outcome"] == "nothing" && QUIET_SWEEP_REASONS.include?(each["reason"]) }
        shown.each do |each|
          label = (each["outcome"] == "nothing") ? "left alone (#{each["reason"]})" : each["outcome"].tr("_", " ")
          @output.puts "#{each["run_id"]}  #{each["workspace"]}  step #{each["step"]}  #{label}#{": #{TerminalText.escape(each["message"])}" if each["message"]}"
        end
        return unless summary
        @output.puts "Looked at #{rows.size} run#{"s" unless rows.size == 1}; #{shown.empty? ? "nothing to report" : "#{shown.size} reported above"}."
      end

      def scope_filter(scope)
        if scope&.workspace
          ->(run) { run.workspace == scope.workspace }
        elsif scope&.project
          ->(run) { @status.in_project?(run, scope.project) }
        end
      end

      def print_compare(workflow, last_text, result)
        window = last_text ? " started in the last #{TerminalText.escape(last_text)}" : ""
        name = TerminalText.escape(workflow)
        by = TerminalText.escape(result["by"])
        groups = result["groups"]
        if groups.empty?
          what = result["by"].start_with?("pack:") ? "run of #{name}#{window} used #{by.sub("pack:", "pack ")}" : "run of #{name}#{window}"
          @output.puts "No #{what}."
        else
          rows = [COMPARE_HEADER] + groups.map { |each| compare_cells(each).map { |cell| TerminalText.escape(cell) } }
          widths = rows.transpose.map { |column| column.map(&:length).max }
          rows.each { |line| @output.puts line.each_with_index.map { |cell, i| i.zero? ? cell.ljust(widths[i]) : cell.rjust(widths[i]) }.join("  ") }
          @output.puts "#{result["matched"]} #{(result["matched"] == 1) ? "run" : "runs"} of #{name}#{window}, grouped by #{by}."
        end
        running = groups.sum { |each| each["running"] }
        cancelled = groups.sum { |each| each["cancelled"] }
        @output.puts "PASS-1ST is the share of settled runs that completed with every step passing on its one delivered attempt. Settled: completed, or cancelled or stuck after a miss (a stuck run counts as a miss while it waits)." if groups.any?
        @output.puts "#{running} run#{"s" unless running == 1} still going and #{cancelled} cancelled with no miss, left out of PASS-1ST." if running.positive? || cancelled.positive?
        @output.puts "#{result["without_pack"]} run#{"s" unless result["without_pack"] == 1} did not use #{by.sub("pack:", "pack ")} and #{(result["without_pack"] == 1) ? "is" : "are"} in no group." if result["without_pack"].positive?
        @output.puts "#{result["no_attempts"]} run#{"s" unless result["no_attempts"] == 1} never delivered an attempt and #{(result["no_attempts"] == 1) ? "is" : "are"} in no group." if result["no_attempts"].positive?
        @output.puts "unknown: runs stored without the hash; mixed: runs that saw more than one." if groups.any? { |each| %w[unknown mixed].include?(each["sha"]) }
        @output.puts result["warning"]
        @output.puts "Warning: #{result["undated"]} run#{"s" unless result["undated"] == 1} with no start time left out of the window." if result["undated"].positive?
        @output.puts "Warning: #{result["unreadable"]} run file#{"s" unless result["unreadable"] == 1} could not be read; the figures are incomplete." if result["unreadable"].positive?
      end

      def compare_cells(group)
        percent = group["pass_first_percent"] ? "#{group["pass_first_percent"]}%" : "-"
        [group["sha"].to_s[0, 8], group["runs"], percent, format("%.1f", group["resumes_per_run"])].map(&:to_s)
      end

      def print_stats(workflow, last_text, result)
        window = last_text ? " started in the last #{TerminalText.escape(last_text)}" : ""
        name = TerminalText.escape(workflow)
        steps = result["steps"]
        if result["runs"].zero?
          @output.puts "No runs of #{name}#{window}."
        else
          rows = [STATS_HEADER] + steps.map { |each| stats_cells(each).map { |cell| TerminalText.escape(cell) } }
          widths = rows.transpose.map { |column| column.map(&:length).max }
          rows.each { |line| @output.puts line.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
          @output.puts "#{result["runs"]} #{(result["runs"] == 1) ? "run" : "runs"} of #{name}#{window}."
          undelivered = steps.sum { |each| each["not_delivered"] }
          @output.puts "#{undelivered} attempt#{"s" unless undelivered == 1} never reached the agent and #{(undelivered == 1) ? "is" : "are"} left out." if undelivered.positive?
          unfinished = steps.sum { |each| each["unfinished"] }
          @output.puts "#{unfinished} attempt#{"s" unless unfinished == 1} had not ended and #{(unfinished == 1) ? "is" : "are"} left out." if unfinished.positive?
          @output.puts "#{result["unattributed_resumes"]} resume#{"s" unless result["unattributed_resumes"] == 1} named no step and #{(result["unattributed_resumes"] == 1) ? "is" : "are"} not in the table." if result["unattributed_resumes"].positive?
          counted_unfinished = steps.sum { |each| each["tokens_from_unfinished"] }
          @output.puts "TOKENS/RUN also counts the tokens of #{counted_unfinished} attempt#{"s" unless counted_unfinished == 1} that ended with no result (cancelled, or restarted by a resume), which is why a step can show tokens with no finished attempts." if counted_unfinished.positive?
          partial_tokens = steps.any? { |each| each["tokens"]["runs_uncounted"].positive? }
          @output.puts "TOKENS/RUN is the mean over the runs that recorded tokens; * marks a step where some runs recorded none, - where none did." if partial_tokens
        end
        @output.puts "Warning: #{result["undated"]} run#{"s" unless result["undated"] == 1} with no start time left out of the window." if result["undated"].positive?
        @output.puts "Warning: #{result["unreadable"]} run file#{"s" unless result["unreadable"] == 1} could not be read; the figures are incomplete." if result["unreadable"].positive?
      end

      def stats_cells(row)
        tokens = row["tokens"]
        mean = if tokens["mean"].nil? then "-"
        else
          text = format_tokens(tokens["mean"])
          tokens["runs_uncounted"].positive? ? "#{text}*" : text
        end
        median = row["median_seconds"] ? Duration.humanize(row["median_seconds"]) : "-"
        [row["step"], row["attempts"], row["passed"], row["failed"], median, row["resumes"], mean].map(&:to_s)
      end

      def format_tokens(count)
        return count.to_s if count < 1000
        return "#{(count / 1000.0).round}k" if count < 999_500
        "#{(count / 1_000_000.0).round(1)}M"
      end

      NEEDS_ME_HEADER = %w[RUN WORKSPACE STEP WAITING WHY DO].freeze

      # `status --needs-me`: the runs still going that wait for a person, longest wait first.
      #
      # @return [Hash] `exit_code` 3 when a run file could not be read (the list is then incomplete), else 0
      def needs_me(scope, json)
        raise Workspace::Error, "workflow status --needs-me is not available: no reader was wired" unless @needs_me
        result = if scope.workspace
          @status.runs(workspace: scope.workspace)
        elsif scope.project
          @status.in_project(scope.project)
        else
          @status.runs
        end
        rows = @needs_me.rows(result["runs"])
        unreadable = result["unreadable"].to_i
        partial = unreadable.positive?
        if json
          document("generated_at" => @clock.call.utc.iso8601, "status" => partial ? "partial" : "ok", "unreadable" => unreadable, "runs" => rows, "warnings" => result["warnings"])
        else
          if rows.empty?
            @output.puts partial ? "No readable workflow run needs you; #{unreadable} could not be read." : "No workflow runs need you."
          else
            lines = [NEEDS_ME_HEADER] + rows.map { |each| needs_me_cells(each).map { |cell| TerminalText.escape(cell) } }
            widths = lines.transpose.map { |column| column.map(&:length).max }
            lines.each { |line| @output.puts line.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
          end
          result["warnings"].each { |warning| @output.puts "Warning: #{warning}" }
        end
        {exit_code: partial ? 3 : 0}
      end

      def needs_me_cells(row)
        why = row["kind"] || row["code"]
        note = row["gate_file"]&.fetch("name", nil)
        why = "#{why} (#{row["detail"] || note})" if row["detail"] || note
        action = row["next_action"]
        command = action ? ([action["action"]] + action["args"] + needed(action)).join(" ") : "-"
        [row["run"], row["workspace"], row["step"].to_s, wait_text(row["waiting_seconds"]), why, command]
      end

      def wait_text(seconds)
        return "-" unless seconds
        days, rest = seconds.divmod(86_400)
        hours, rest = rest.divmod(3600)
        minutes = rest / 60
        return "#{days}d #{hours}h" if days.positive?
        return "#{hours}h #{minutes}m" if hours.positive?
        return "#{minutes}m" if minutes.positive?
        "#{seconds}s"
      end

      PRODUCES_PROBLEMS = {"symlink" => "a link; write a regular file", "not_regular_file" => "not a regular file", "empty" => "empty; write its content"}.freeze

      TABLE_HEADER = ["Run", "State", "Workspace", "Status", "Config", "tmux session", "Worktree", "State dir"].freeze

      def status_table(result, scope, run, json)
        runs = result["runs"]
        facts = @workspace_facts.call(runs.map { |each| each["workspace"] })
        rows = runs.map { |each| table_row(each, facts.fetch(each["workspace"], {}), worktree_exists?(each["worktree"])) }
        if json
          return document("generated_at" => @clock.call.utc.iso8601, "rows" => rows.map { |row| table_json(row) }, "warnings" => result["warnings"])
        end
        @output.puts table_empty_text(scope) if rows.empty? && !run
        print_table(rows) unless rows.empty?
        result["warnings"].each { |warning| @output.puts "Warning: #{warning}" }
      end

      def worktree_exists?(path)
        File.directory?(path) if path.is_a?(String)
      rescue ArgumentError
        nil
      end

      def table_row(run, facts, worktree)
        finished = WorkflowRunStore::TERMINAL_STATES.include?(run["state"])
        {"run" => run, "facts" => facts, "worktree" => worktree, "finished" => finished}
      end

      def table_json(row)
        run = row["run"]
        facts = row["facts"]
        {"id" => run["id"], "workflow" => run["workflow"], "state" => run["state"], "step" => (row["finished"] ? nil : run.dig("current", "step")),
         "workspace" => run["workspace"], "workspace_status" => facts["status"] || "unknown", "agent" => facts["agent"],
         "has_config" => facts["config"], "has_tmux_session" => facts["tmux_session"], "has_worktree" => row["worktree"], "has_state_dir" => facts["state_dir"]}
      end

      def print_table(rows)
        lines = rows.map do |row|
          run = row["run"]
          facts = row["facts"]
          state = row["finished"] ? run["state"] : "#{run["state"]} (#{run.dig("current", "step")})"
          [run["id"], state, run["workspace"], workspace_status_text(facts), *[facts["config"], facts["tmux_session"], row["worktree"], facts["state_dir"]].map { |value| yes_no(value) }]
        end
        print_grid(TABLE_HEADER, lines)
      end

      # One grid: the header, then one row per line, each column as wide as its widest
      # cell. Every cell goes through TerminalText.escape.
      def print_grid(header, lines)
        widths = header.each_index.map { |i| ([header[i]] + lines.map { |line| line[i].to_s }).map { |cell| TerminalText.escape(cell).length }.max }
        ([header] + lines).each do |line|
          @output.puts line.each_with_index.map { |cell, i| TerminalText.escape(cell.to_s).ljust(widths[i]) }.join("  ").rstrip
        end
      end

      def workspace_status_text(facts)
        case facts["status"]
        when "live" then "Live, agent #{facts["agent"] || "unknown"}"
        when "stopped" then "Stopped"
        when "gone" then "Gone"
        else "Unknown"
        end
      end

      def yes_no(value)
        {true => "yes", false => "no"}.fetch(value, "?")
      end

      def table_empty_text(scope)
        case scope&.kind
        when :workspace then "No workflow runs in #{scope.workspace}."
        else status_empty_text(scope, false)
        end
      end

      def status_empty_text(scope, hint)
        case scope&.kind
        when :workspace
          text = "No workflow runs in #{scope.workspace} still going."
          hint ? "#{text}\nFinished runs show with --project or --all." : text
        when :project then "No workflow runs in project #{scope.project.name}."
        else "No workflow runs."
        end
      end

      # The id a text with no --id is checked as when it names none.
      STDIN_ID = "stdin"
      FILE_ID = "file"

      # A run that has ended: its park is gone with it, and there is nothing to record.
      RUN_ENDED_CODES = %w[run_not_active unknown_run].freeze

      def read_text(path, stdin)
        (stdin ? @input.read : File.binread(path)).to_s.dup.force_encoding(Encoding::UTF_8)
      rescue SystemCallError => e
        raise UsageError, "Can't read #{path}: #{e.message.sub(/ (@ .*)?- .*\z/, "")}"
      end

      # A string `id:` in the text, if it parses far enough to have one.
      def claimed_id(text)
        value = YAML.safe_load(text)&.then { |doc| doc["id"] if doc.is_a?(Hash) }
        value if value.is_a?(String)
      rescue Psych::Exception, ArgumentError
        nil
      end

      # How a definition being read finds the workflow its `extends:` names.
      def parent_lookup(project: nil)
        ->(id, below: nil) { @catalog.parent(id, below: below, project: project) }
      end

      # The definition document with +fills_from_branch+ on each declared input `workflow run` fills from the branch.
      def with_branch_fills(data)
        return data unless data["inputs"]

        inputs = data["inputs"].dup
        WorkflowBranchInputs::FILLABLE.each do |name|
          inputs[name] = (inputs[name] || {}).merge("fills_from_branch" => true) if inputs.key?(name)
        end
        data.merge("inputs" => inputs)
      end

      # The `extends` field of a definition document: the parents nearest first, left out when there are none.
      def extends_field(definition)
        parents = definition.parents
        parents.empty? ? {} : {"extends" => parents.map { |parent| parent.slice("id", "source", "path", "sha256") }}
      end

      # The parent lookup and chain for a draft that will be installed as +id+: the draft stands in for the installed file, so a
      # cycle through it is found now and not when the next definition is read. Without a files directory, the plain lookup.
      def draft_lookup(id, text, project = nil)
        installed = begin
          @files&.path(id)
        rescue Workspace::Error
          nil
        end
        base = parent_lookup(project: project)
        return [base, nil] unless installed
        lookup = ->(parent_id, below: nil) { (parent_id == id && below.nil?) ? {"text" => text, "path" => installed, "source" => "global"} : base.call(parent_id, below: below) }
        [lookup, [[id, installed]]]
      end

      def print_install_row(row)
        @output.puts "source:#{row["index"]} #{TerminalText.escape(row["source"])}: #{row["outcome"]}"
        if row["outcome"] == "refused"
          row["problems"].each { |problem| @output.puts "  #{TerminalText.escape(problem["file"])}: #{TerminalText.escape(problem["message"])} (#{problem["code"]})" }
          @output.puts "  nothing from this source was installed; the cache keeps its previous version."
          return
        end
        {"installed" => "new", "changed" => "changed", "removed" => "removed"}.each do |key, label|
          row[key].each { |id| @output.puts "  #{label}: #{TerminalText.escape(id)} (source:#{row["index"]})" }
        end
        @output.puts "  workflows: #{row["workflows"].map { |id| TerminalText.escape(id) }.join(", ")}" if row["workflows"].any? && row["outcome"] != "installed"
      end

      # Warns on stderr of the definitions that extend +id+, which a change to it reaches, and answers the row field naming them (empty when none).
      def extended_by(id)
        children = @catalog.extended_by(id)
        return {} if children.empty?
        @error_output.puts "warning: #{children.join(", ")} #{(children.size == 1) ? "extends" : "extend"} #{id}, directly or through another workflow, so this change affects #{(children.size == 1) ? "it" : "them"}."
        {"extended_by" => children}
      end

      def file_id(path)
        name = File.basename(path, ".*")
        IdPatterns::WORKFLOW_ID.match?(name) ? name : FILE_ID
      end

      # A definition file in a directory a lookup reaches later than another file of its id is never the one a
      # run reads; say so, with where the one that wins is.
      def shadow_warnings(id, scope, project)
        return [] unless scope
        winner = @catalog.locate(id.to_s, project: project)
        order = @catalog.ordered_sources(project)
        return [] if winner.nil? || winner.first == scope || order.index(winner.first) > order.index(scope)
        [{"code" => "shadowed", "message" => "A #{winner.first} definition of #{id} (#{winner.last}) is found first, so this file is not the one a run reads."}]
      end

      # Where a lookup of the id finds its definition now, for the project the scope names (nil for every workspace);
      # the runs counted may have run an earlier or another definition. nil when none has the id.
      def current_definition(id, scope)
        project = scope&.project&.name || WorkflowCatalog.project_of(scope&.workspace)
        found = @catalog.locate(id, project: project)
        found && {"source" => found.first, "project" => (found.first == "project") ? project : nil, "path" => found.last}
      end

      def document(body)
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true}.merge(body))
      end

      def show_source(id, json, project)
        found = @catalog.source(id, project: project)
        data = {"id" => id}.merge(found)
        data = WorkflowDefinition.parse(found["text"], id: id, source: found["source"], path: found["path"], parent_lookup: parent_lookup).to_h.merge(data) if found["problems"].empty?
        return document("workflow" => data) if json
        @output.print found["text"] if found["text"]
        found["problems"].each { |problem| @error_output.puts TerminalText.escape("#{id}: #{problem}") }
      end

      def step_traits(step)
        traits = []
        traits << "produces #{step["produces"].join(", ")}" if step["produces"].any?
        traits << "uses #{step["uses"].join(", ")}" if step["uses"].any?
        traits << "check" if step["status"]
        traits << "gate: #{step["gate"]}" if step["gate"]
        traits << "on fail: back to #{step["on_fail"]["goto"]}, #{step["on_fail"]["max"]} time(s)" if step["on_fail"]
        traits << "continues the conversation" if step["context"] == "continue"
        traits.join("; ")
      end

      # The run the step's pane is bound to keeps the pane it has unless that pane is gone:
      # only then is the workspace's Claude pane looked up (which starts its agent daemon).
      # Whether the run's current step has a `guard:`, a `status:` check or a `command` proof. An agent that
      # re-ran its own check from a shell could put a fake `git` first on PATH.
      def checked_step?(run)
        step = Array(run.definition&.dig("steps")).find { |each| each["id"] == run.current }
        !!(step && (step["guard"] || step["status"] || Array(step["require"]).any? { |entry| entry.key?("command") || entry.key?("exec") }))
      end

      # The caller is in the pane the resume would type into, so nothing is typed:
      # the resume is stored and the daemon carries it out once this turn ends.
      def park_resume(stored, from:, note:, pane:, target:, turn_over:, extra_attempts: nil, extra_tokens: nil)
        existing = WorkflowEngine.parked(stored.to_h, @clock.call) == :waiting
        parked = @engine.park(stored.id, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens)
        if parked["unchanged"]
          message = "Nothing was done: #{parked["unchanged"]}."
          if existing
            message += " End your turn now."
            message += " The --from, --note or --pane given to this call was not kept." if from || note || pane
          end
          return row(parked, "unchanged", message: message)
        end
        message = "Run from the run's own pane, so nothing was typed. Once this turn ends, the agent daemon will carry out " \
          "the resume in pane #{target}, at most 1 hour from now. End your turn now; a sub-agent should finish and let " \
          "the main agent end its turn."
        row(parked, "parked", message: message).merge("parked" => {"pane" => target, "expires_at" => parked.dig("parked", "expires_at")})
      end

      def resume_pane(stored, pane)
        return @panes.locate(stored.workspace, pane) if pane
        gone = stored.reason&.dig("code") == "pane_gone" || (@panes.pane_of(stored.id) && !@panes.alive?(stored.id))
        gone ? @panes.default_pane(stored.workspace) : nil
      end

      # A gate is passed by a person. The check guards against an agent's mistake and is not
      # a boundary: an agent can clear `$TMUX_PANE`.
      def refuse_bound_pane!(caller_pane, verb, subject = "A gate is passed by a person")
        bound = caller_pane && @panes.run_on(caller_pane)
        return unless bound
        raise Workspace::Error.new("#{subject}: this pane (#{caller_pane}) is bound to workflow run #{bound}, " \
          "so `#{verb}` is refused here. Run it from another terminal.",
          code: "bound_pane", details: {"pane" => caller_pane, "run_id" => bound})
      end

      # Both checks guard against an agent's mistake: `$TMUX_PANE` names a bound pane,
      # or this process runs under the run's own pane (with `$TMUX_PANE` unset or another
      # pane's). When tmux or the process table can't be read, only the first runs.
      # `$TMUX_PANE` is not compared with the run's pane: a stored id can name another
      # session's pane after tmux restarts, which is what the binding check tells apart.
      def refuse_caller!(run, caller_pane, verb, subject = "A gate is passed by a person")
        refuse_bound_pane!(caller_pane, verb, subject)
        pane = @panes.pane_of(run.id) || run.pane
        return unless caller_in_pane?(run.workspace, nil, pane)
        agent = calling_agent
        raise Workspace::Error.new("#{subject}: this process runs under pane #{pane}, which workflow run #{run.id} " \
          "is bound to, so `#{verb}` is refused here. Run it from another terminal.",
          code: "bound_pane", details: {"pane" => pane, "run_id" => run.id, "agent" => agent})
      end

      # Whether this process is in the pane: `$TMUX_PANE` names it, or the process
      # runs under the pane's own process. Takes the workspace because a caller can
      # ask before any run exists.
      def caller_in_pane?(workspace, caller_pane, target)
        return false unless target
        return true if caller_pane == target
        pid = pane_pid(workspace, target)
        !pid.nil? && under?(pid)
      end

      # Proof comes before expiry, so a turn that ended just past the limit still runs.
      # From inside the target pane only the expiry is looked at: a turn there can't be
      # over, and its own process must not start what follows it. Everything here is read
      # outside the run's lock; the park's id settles two processes that both saw the proof.
      def release_parked(run, caller_pane)
        workspace = run.workspace
        target = run.parked["pane"] || @panes.pane_of(run.id) || run.pane
        unless caller_in_pane?(workspace, caller_pane, target)
          return release_park(run) if @panes.main_turn_over?(workspace, target)
          return end_park(run, "pane_gone", "pane #{target} of '#{workspace}' is gone, so nothing was typed") if @panes.pane_gone?(target)
          return end_park(run, "not_an_agent", "the agent in pane #{target} has exited, so nothing was typed") if @panes.agent_gone?(workspace, target)
        end
        return unless WorkflowEngine.parked(run.to_h, @clock.call) == :expired
        checking = run.current_step&.state == "checking"
        end_park(run, "parked_timeout", WorkflowEngine.park_timeout_message(target, checking: checking))
      end

      # A release that raised would raise again on every tick, and with proof ahead of
      # expiry would never reach the limit, so any failure ends the park.
      def release_park(run)
        released = @engine.release_park(run.id, run.parked["id"])
        unchanged = released && released["unchanged"]
        @error_output.puts "workflow: the parked resume of run #{run.id} did nothing: #{unchanged}" if unchanged
        nil
      rescue Workspace::Error => e
        unless RUN_ENDED_CODES.include?(e.code)
          @error_output.puts "workflow: the parked resume of run #{run.id} failed: #{first_line(e)}"
          end_park(run, e.code.to_s, first_line(e))
        end
      rescue => e
        @error_output.puts "workflow: the parked resume of run #{run.id} failed: #{first_line(e)}"
        end_park(run, "error", first_line(e))
      end

      def end_park(run, code, message)
        @engine.park_failed(run.id, run.parked["id"], code: code, message: message)
        nil
      rescue Workspace::Error => e
        park_not_ended(run, e) unless RUN_ENDED_CODES.include?(e.code)
      rescue => e
        park_not_ended(run, e)
      end

      def park_not_ended(run, error)
        @error_output.puts "workflow: could not end the parked resume of run #{run.id}: #{first_line(error)}"
        nil
      end

      def first_line(error)
        error.message.lines.first.to_s.scrub.strip
      end

      def pane_pid(workspace, pane)
        detail = @tmux.pane_details(@tmux.session_name_for(workspace), window: nil).find { |each| each[:id] == pane }
        (detail && detail[:pid].positive?) ? detail[:pid] : nil
      rescue SystemCallError
        nil
      end

      def under?(pane_pid)
        @process_tree.snapshot.ancestors(@pid).any? { |process| process[:pid] == pane_pid }
      rescue Workspace::Error, SystemCallError
        false
      end

      def calling_agent
        holder = @lock_holder.current
        holder && {"pid" => holder[:pid], "started" => holder[:started]}
      rescue Workspace::Error
        nil
      end

      def bound_run!(pane)
        run_id = pane && !pane.empty? && @panes.run_on(pane)
        return run_id if run_id
        raise Workspace::Error.new("This pane is not bound to a workflow run#{" (not inside tmux)" if pane.nil? || pane.empty?}.",
          code: "not_bound", details: {"pane" => pane})
      end

      # The dry-run line's note of what the branch filled, empty when it filled nothing.
      def fill_sentence(filled, from)
        return "" if from.empty?
        pull = from.select { |_, source| source == "pull_request" }.keys
        if pull.any?
          number = from["pr"] ? filled["pr"] : filled["task"].to_s[/\A#(\d+)/, 1]
          " Fills #{(WorkflowBranchInputs::FILLABLE & pull).join(" and ")} from pull request ##{number}."
        else
          " Fills #{from.keys.join(" and ")} from branch #{filled["task"].to_s.delete_prefix("Branch ")}."
        end
      end

      # The action row for a run after a transition. A step that could not be
      # started is a failed action, though the run exists and can be resumed.
      def row(run, verb, message: nil)
        shown = @status.run(run["id"])["runs"].first
        reason = shown.dig("current", "reason")
        undelivered = reason && reason.dig("details", "kind") == "dispatch"
        describe(shown)
        @output.puts message if message
        {"workspace" => run["workspace"], "outcome" => (undelivered && verb != "unchanged") ? "failed" : verb, "reason" => reason&.fetch("code"),
         "message" => (undelivered && verb != "unchanged") ? reason.dig("details", "message") : message, "run" => shown}
      end

      def describe(run)
        current = run["current"]
        where = %w[completed cancelled failed].include?(run["state"]) ? "" : "  step #{current["step"]}#{" (attempt #{current["attempt"]})" if current["attempt"]}, #{current["state"]}"
        @output.puts "#{run["id"]}  #{run["workflow"]}  #{run["workspace"]}  #{run["state"]}#{where}"
        reason = current["reason"]
        @output.puts "  #{reason["code"]}: #{reason_text(reason)}" if reason
        current["flags"].each { |flag| @output.puts "  flag: #{flag}" }
        parked = current["parked"]
        @output.puts "  parked: pane #{parked["pane"]} until #{parked["expires_at"]}; carried out once that pane's turn ends" if parked
        reason&.fetch("actions")&.each { |action| @output.puts "    workspace #{action["action"]} #{(action["args"] + needed(action)).join(" ")}" }
        Array(run["guard_warnings"]).each { |each| @output.puts "  warning: #{each["code"]} at step #{each["step"]} (attempt #{each["attempt"]}): #{each["message"]}" }
      end

      # What a person has to supply, shown as an upper-case placeholder where it goes.
      def needed(action)
        action["needs"].flat_map { |need| [need["flag"] || "--", need["name"].upcase] }
      end

      def budget_sentence(details)
        minimum = details["uncounted"].to_i.positive? ? " (at least; #{details["uncounted"]} ended attempt#{"s" unless details["uncounted"] == 1} not counted)" : ""
        "#{delimit(details["used"])} of #{delimit(details["allowance"])} tokens#{minimum}  (resume --extra-tokens #{details["suggested"]})"
      end

      def delimit(number)
        number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
      end

      def reason_text(reason)
        details = reason["details"]
        case reason["code"]
        when "waiting_lock"
          holder = details["holder"]
          who = if holder["run_id"]
            "run #{holder["run_id"]}#{" (step #{holder["step"]})" if holder["step"]}#{" in #{holder["workspace"]}" if holder["workspace"]}"
          else
            "#{(holder["kind"] == "process") ? "the dev environment" : "an agent"}#{" in #{holder["worktree"]}" if holder["worktree"]} (pid #{holder["pid"]})"
          end
          "queued for #{details["resource"]}, #{details["position"]} of #{details["total"]}, held by #{who}"
        when "waiting_you"
          case details["kind"]
          when "gate" then "step #{details["step"]} passed and waits for approval#{" (#{details["artifacts"].join(", ")})" if details["artifacts"].any?}"
          when "prompt" then "pane #{details["pane"]} is waiting for an answer#{": #{details["message"]}" if details["message"]}"
          when "ask" then "open question #{details["ask"]}: #{details["question"]}"
          when "delivery" then "step #{details["step"]}'s line was on its way to pane #{details["pane"]} when the process typing it stopped; the agent may not have it"
          else "step #{details["step"]} could not be started (#{details["error"]}): #{details["message"]}"
          end
        when "turn_ended_incomplete"
          stale = Array(details["stale"])
          # Task types and ids come from a stored run, so they are escaped like any text printed to a terminal.
          tasks = Array(details["background_tasks"]).grep(Hash).map { |task| TerminalText.escape("#{task["type"]} #{task["id"]}") }
          ["the turn ended", ("without #{details["missing"].join(", ")}" if details["missing"].any?),
            ("with #{stale.join(", ")} left by an earlier attempt and not written again" if stale.any?),
            ("with #{Array(details["invalid"]).map { |each| "#{each["file"]} (#{PRODUCES_PROBLEMS.fetch(each["rule"], each["rule"])})" }.join(", ")}" if Array(details["invalid"]).any?),
            ("and background tasks were still listed after 90 minutes: #{tasks.join(", ")}" if tasks.any?)].compact.join(" ")
        when "failed_check"
          if details["cause"] == "reported"
            "step #{details["step"]} was reported failed#{": #{details["summary"]}" if details["summary"]}"
          elsif details["cause"] == "timeout"
            "step #{details["step"]} ran past its #{details["timeout"]} second time limit and was failed by the sweep"
          elsif details["cause"] == "require"
            "step #{details["step"]} failed #{details["code"]}: #{TerminalText.escape(details["detail"].to_s)}"
          else
            "step #{details["step"]}'s check #{details["timed_out"] ? "ran past its time limit" : "exited #{details["exit_code"].inspect}"}; log: #{details["log"]}"
          end
        when "budget_spent"
          "step #{details["step"]} was not started: #{budget_sentence(details)}"
        when "retry_backoff"
          "step #{details["step"]} failed; step #{details["to"]} starts again at #{details["until"]} (after #{details["seconds"].to_f.round} seconds), or sooner with a resume"
        when "pane_gone" then "pane #{details["pane"]} of #{details["workspace"]} is not running#{": #{details["message"]}" if details["message"]}"
        else details.to_s
        end
      end
    end
  end
end
