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

      # What `step done --code` accepts.
      CODE_PATTERN = /\A[a-z][a-z0-9_]{0,39}\z/

      # What `step done --status` accepts.
      REPORT_STATUSES = %w[pass fail].freeze

      # @param catalog [Workspace::WorkflowCatalog]
      # @param engine [Workspace::WorkflowEngine]
      # @param status [Workspace::WorkflowStatus]
      # @param store [Workspace::WorkflowRunStore]
      # @param panes [Workspace::WorkflowPanes]
      # @param files [Workspace::WorkflowFiles] writes a user's definitions (`add`)
      # @param run_files [Workspace::WorkflowRunFiles] lists a run's files (`files`)
      # @param tmux [Workspace::Tmux] names the pid of a run's pane, for approve and reject
      # @param process_tree [Workspace::ProcessTree] says whether this process runs under that pane
      # @param lock_holder [Workspace::LockHolder] names the agent a refusal was made for
      # @param pid [Integer] this process
      # @param clock [#call] returns the current Time
      # @param output [IO]
      # @param input [IO] read for `validate -` and `add ID -`
      # @param error_output [IO] gets the problems `show --source` finds in a file's text
      def initialize(catalog:, engine:, status:, store:, panes:, files:, run_files:, tmux:, process_tree:, lock_holder:, pid: Process.pid,
        clock: -> { Time.now }, output: $stdout, input: $stdin, error_output: $stderr)
        @tmux = tmux
        @process_tree = process_tree
        @lock_holder = lock_holder
        @pid = pid
        @catalog = catalog
        @files = files
        @run_files = run_files
        @engine = engine
        @status = status
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
      # @return [void]
      # @raise [Workspace::Error] code `unknown_workflow`; without +source:+ also `invalid_workflow`
      def show(id: nil, json: false, source: false)
        return list(json) unless id
        return show_source(id, json) if source
        definition = @catalog.find(id)
        data = definition.to_h
        if json
          return document("workflow" => data.merge("source" => definition.source, "path" => definition.path, "sha256" => definition.sha256))
        end
        @output.puts "#{data["id"]}: #{data["title"]} (#{definition.source}, #{definition.path})"
        @output.puts data["description"] if data["description"]
        @output.puts "Inputs:" if data["inputs"].any?
        data["inputs"].each { |name, spec| @output.puts "  #{name}#{" (required)" if spec["required"]}#{": #{spec["description"]}" if spec["description"]}" }
        @output.puts "Steps:"
        data["steps"].each { |step| @output.puts "  #{step["id"].ljust(12)} #{step_traits(step)}".rstrip }
      end

      # Checks a definition's text with the checks a definition on disk gets, and
      # writes nothing. +prompt_file:+ resolves against the file's directory for a
      # PATH and against the current directory for stdin.
      #
      # @param path [String] a file, or "-" for stdin
      # @param id [String, nil] the id to check it as; else a string `id:` in the text, else the file's name, else "stdin" for `-` or "file"
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::UsageError] when PATH can't be read
      # @raise [Workspace::Error] code `invalid_workflow`, with `details.problems` listing every problem
      def validate(path:, id: nil, json: false)
        stdin = path == "-"
        text = read_text(path, stdin)
        id ||= claimed_id(text) || (stdin ? STDIN_ID : file_id(path))
        definition = WorkflowDefinition.parse(text, id: id, source: stdin ? "stdin" : "file",
          path: stdin ? nil : File.expand_path(path), base_dir: stdin ? Dir.pwd : nil)
        if json
          document("workflow" => definition.to_h.merge("source" => definition.source, "path" => definition.path, "sha256" => definition.sha256))
        else
          @output.puts "#{definition.to_h["id"]}: valid (#{definition.steps.size} steps)"
        end
      end

      # Saves a definition as a user's file, `ID.yml` in the workflows directory, after
      # the checks `validate` runs. A relative `prompt_file:` is read from that directory,
      # where the file will be loaded. A preset of the same id is allowed: the copy shadows it.
      #
      # @param id [String] the workflow's id; a string `id:` in the text must match it
      # @param path [String] a file, or "-" for stdin
      # @param dry_run [Boolean] run every check (the file's existence under its lock) and write no definition; the directory and lock file may be created
      # @return [Hash{String=>Object}] the action row: outcome "added" or "dry_run", with "workflow", "path" and "sha256"
      # @raise [Workspace::UsageError] when PATH can't be read
      # @raise [Workspace::Error] code `invalid_workflow` (a bad id, or text that doesn't pass), `workflow_exists`
      def add(id:, path:, dry_run: false)
        @files.path(id)
        stdin = path == "-"
        text = read_text(path, stdin)
        WorkflowDefinition.parse(text, id: id, source: stdin ? "stdin" : "file", path: stdin ? nil : File.expand_path(path), base_dir: @files.dir)
        builtin = @catalog.locate(id)&.first == "builtin"
        written = @files.add(id, text, dry_run: dry_run)
        message = "#{dry_run ? "Would add" : "Added"} workflow #{id} at #{written["path"]}#{"; it shadows the preset of the same id" if builtin}."
        @output.puts message
        {"workspace" => nil, "outcome" => dry_run ? "dry_run" : "added", "reason" => nil, "message" => message, "workflow" => id}.merge(written)
      end

      # Replaces a user's definition file when it is still the one the caller read. The new
      # text gets the checks `add` runs (a relative `prompt_file:` from the workflows directory);
      # the current file is only hashed, so a broken one can be replaced.
      #
      # @param id [String] the workflow's id
      # @param path [String] a file, or "-" for stdin
      # @param if_sha256 [String] the sha256 of the file's raw bytes, from `show ID --source --json` or `show --json`
      # @param dry_run [Boolean] run every check and write no definition
      # @return [Hash{String=>Object}] the action row: outcome "updated" or "dry_run", with "workflow", "path" and "sha256"
      # @raise [Workspace::UsageError] when PATH can't be read
      # @raise [Workspace::Error] code `invalid_workflow`, `unknown_workflow`, `builtin_workflow`, `stale_workflow`
      def update(id:, path:, if_sha256:, dry_run: false)
        @files.path(id)
        stdin = path == "-"
        text = read_text(path, stdin)
        WorkflowDefinition.parse(text, id: id, source: stdin ? "stdin" : "file", path: stdin ? nil : File.expand_path(path), base_dir: @files.dir)
        written = @files.update(id, text, if_sha256: if_sha256, dry_run: dry_run)
        message = "#{dry_run ? "Would update" : "Updated"} workflow #{id} at #{written["path"]}."
        @output.puts message
        {"workspace" => nil, "outcome" => dry_run ? "dry_run" : "updated", "reason" => nil, "message" => message, "workflow" => id}.merge(written)
      end

      # Refuses, before anyone is asked anything, an id that has no file of the user's.
      #
      # @param id [String]
      # @return [void]
      # @raise [Workspace::Error] code `invalid_workflow`, `builtin_workflow`, `unknown_workflow`
      def check_removable(id:)
        @files.ensure_present(id)
      end

      # Deletes a user's definition file. Without +yes+ (and not a dry run) it asks first,
      # before the file's lock is taken; "y" confirms, anything else answers nothing. A preset of
      # the same id is untouched and is in effect again.
      #
      # @param id [String] the workflow's id
      # @param yes [Boolean] skip the prompt
      # @param dry_run [Boolean] run every check and delete nothing; needs no +yes+
      # @return [Hash{String=>Object}, nil] the action row: outcome "removed" or "dry_run", with "workflow" and "path"; nil when the prompt was declined
      # @raise [Workspace::Error] code `invalid_workflow`, `unknown_workflow`, `builtin_workflow`, `confirmation_required` (input is off)
      def remove(id:, yes: false, dry_run: false)
        check_removable(id: id)
        target = @files.path(id)
        unless yes || dry_run
          answer = Prompt.ask(@input, @output, "Remove workflow #{id} (#{target})? [y/N] ", retry_flags: ["--yes"], destructive: true)
          unless answer.to_s.strip.casecmp?("y")
            @output.puts "Cancelled."
            return nil
          end
        end
        removed = @files.remove(id, dry_run: dry_run)
        message = "#{dry_run ? "Would remove" : "Removed"} workflow #{id} at #{removed["path"]}#{"; the preset of the same id is in effect again" if removed["preset"]}."
        @output.puts message
        {"workspace" => nil, "outcome" => dry_run ? "dry_run" : "removed", "reason" => nil, "message" => message, "workflow" => id, "path" => removed["path"]}
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
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] see {Workspace::WorkflowEngine#preflight}
      def run(id:, workspace:, worktree:, inputs: {}, pane: nil, note: nil, dry_run: false)
        definition = @catalog.find(id)
        if dry_run
          pane_id = pane ? @panes.locate(workspace, pane) : @panes.default_pane(workspace, start_daemon: false)
          checked = @engine.preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane_id)
          @output.puts "Would start #{id} in #{workspace} at step #{checked["step"]}" \
            "#{pane_id ? " in pane #{pane_id}" : " (its agent daemon is not running; starting the run starts it and picks the Claude pane)"}."
          return {"workspace" => workspace, "outcome" => "dry_run", "reason" => nil, "message" => nil, "workflow" => id,
                  "step" => checked["step"], "pane" => pane_id, "inputs" => checked["inputs"], "packs" => checked["packs"]}
        end
        pane_id = pane ? @panes.locate(workspace, pane) : @panes.default_pane(workspace)
        row(@engine.start(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane_id, note: note), "started")
      end

      # Prints where runs stand: one run, or the runs still going.
      #
      # @param run [String, nil] a run id
      # @param workspace [String, nil] only this workspace's runs
      # @param all [Boolean] finished runs too
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `unknown_run`
      def status(run: nil, workspace: nil, all: false, json: false)
        result = run ? @status.run(run) : @status.runs(workspace: workspace, all: all)
        return document("generated_at" => @clock.call.utc.iso8601, "runs" => result["runs"], "warnings" => result["warnings"]) if json
        @output.puts "No workflow runs#{" in #{workspace}" if workspace}#{" still going" unless all}." if result["runs"].empty?
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
        record = @store.find(run)
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

      # Gets a run going again. Everything the engine would refuse is refused
      # first; only then is a daemon started or a pane picked.
      #
      # @param run [String] a run id
      # @param from [String, nil] start again at this step
      # @param note [String, nil] added to the next attempt's instructions
      # @param pane [String, nil] move the run to this pane of its workspace
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [Hash{String=>Object}] the action row; `outcome` is "unchanged" when an agent
      #   is working on the step or its check is still running
      # @raise [Workspace::Error] code `bound_pane` for `--from` at a waiting gate from a pane
      #   bound to a run, or see {Workspace::WorkflowEngine#resume}
      def resume(run:, from: nil, note: nil, pane: nil, caller_pane: nil)
        stored = @store.find(run)
        pane_id = nil
        turn_over = nil
        unless WorkflowRunStore::TERMINAL_STATES.include?(stored["state"])
          state = stored["steps"].fetch(stored["current"])
          refuse_bound_pane!(caller_pane, "workflow resume --from") if from && state.dig("gate", "state") == "waiting"
          refuse_caller!(stored, caller_pane, "workflow resume", "A guarded or checked step is resumed by a person") if from.nil? && checked_step?(stored)
          @engine.refuse_resume(stored, from: from)
          pane_id = resume_pane(stored, pane)
          if pane_id.nil? && from.nil? && state["state"] == "running" && stored["reason"].nil? &&
              @panes.idle?(stored["workspace"], @panes.pane_of(run) || stored["pane"])
            turn_over = {"step" => stored["current"], "attempt" => state["attempts"].last&.fetch("n", nil)}
          end
        end
        resumed = @engine.resume(run, from: from, note: note, pane: pane_id, turn_over: turn_over)
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
        guard = ->(stored) { refuse_caller!(stored, caller_pane, "workflow approve") }
        row(@engine.approve(run, note: note, step: step, attempt: attempt, note_sha256: note_sha256, guard: guard), "approved")
      end

      # Turns a gate down, refused where {#approve} is.
      #
      # @param run [String] a run id
      # @param note [String] why
      # @param to [String, nil] the step to run again
      # @param step [String, nil] the gated step the caller saw
      # @param attempt [Integer, nil] that step's attempt the caller saw
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `bound_pane`, or see {Workspace::WorkflowEngine#reject}
      def reject(run:, note:, to: nil, step: nil, attempt: nil, caller_pane: nil)
        guard = ->(stored) { refuse_caller!(stored, caller_pane, "workflow reject") }
        row(@engine.reject(run, note: note, to: to, step: step, attempt: attempt, guard: guard), "rejected")
      end

      # What the agent daemon runs when a turn ends in a bound pane, and on
      # its timer for a run nothing else would wake. Prints nothing.
      #
      # @param run [String] a run id
      # @param turn_ended [Boolean] a turn ended; false is the timer's look
      # @param pane [String, nil] the pane the turn ended in
      # @param turn_started [Time, nil] when the turn that ended began, when the daemon knows
      # @param caller_pane [String, nil] the pane this command runs in (`$TMUX_PANE`)
      # @return [void]
      # @raise [Workspace::Error] code `bound_pane` for a step with a guard or a status check, from a pane
      #   bound to the run or a process under it
      def advance(run:, turn_ended: false, pane: nil, turn_started: nil, caller_pane: nil)
        stored = begin
          @store.find(run)
        rescue Workspace::Error
          nil
        end
        # The agent daemon runs this as a process of its own. Run from the agent's pane, it would let
        # the agent decide its own step, with a fake `git` first on PATH for the guard.
        if stored && checked_step?(stored)
          refuse_caller!(stored, caller_pane, "workflow advance", "A guarded or checked step is decided by the agent daemon")
        end
        turn_ended ? @engine.turn_ended(run, pane: pane, turn_started: turn_started) : @engine.tick(run)
        nil
      end

      # The agent's own report on its step (`step done`).
      #
      # @param pane [String, nil] the pane the agent runs in (`$TMUX_PANE`)
      # @param status [String] "pass" or "fail"
      # @param summary [String, nil]
      # @param code [String, nil] a word for why, matching {CODE_PATTERN} (`usage` otherwise)
      # @return [Hash{String=>Object}] the action row
      # @raise [Workspace::Error] code `not_bound` outside a run's pane, `step_not_running`
      def step_done(pane:, status: "pass", summary: nil, code: nil)
        raise UsageError, "--status must be pass or fail, got #{status.to_s[0, 40].inspect}." unless REPORT_STATUSES.include?(status)
        raise UsageError, "--code must be a lowercase word that starts with a letter, then letters, digits and underscores (at most 40), got #{code.to_s[0, 60].inspect}." unless code.nil? || CODE_PATTERN.match?(code)
        if code && Workspace::WorkflowEngine::ENGINE_CODES.include?(code)
          raise UsageError, "--code #{code} is a word the engine sets itself (#{Workspace::WorkflowEngine::ENGINE_CODES.join(", ")}); choose another."
        end
        run_id = bound_run!(pane)
        reported = @engine.report(run_id, status: status, summary: summary, code: code)
        @output.puts "Recorded #{status} for step #{reported["step"]} (attempt #{reported["attempt"]}) of run #{run_id}. " \
          "End your turn now; the step is decided when the turn ends."
        {"workspace" => @store.find(run_id)["workspace"], "outcome" => "recorded", "reason" => nil, "message" => nil, "run_id" => run_id,
         "step" => reported["step"], "attempt" => reported["attempt"], "reported" => reported["reported"].slice("status", "summary", "code")}
      end

      # Prints the step the calling pane is on (`step status`).
      #
      # @param pane [String, nil] the pane the agent runs in (`$TMUX_PANE`)
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] code `not_bound` outside a run's pane
      def step_status(pane:, json: false)
        run = @store.find(bound_run!(pane))
        step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
        state = run["steps"].fetch(run["current"])
        attempt = state["attempts"].last || {}
        started = attempt["started_at"] && Time.iso8601(attempt["started_at"])
        produces = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }.map do |path|
          # A file an earlier attempt left has to be written again to count.
          {"path" => path, "exists" => File.exist?(path), "current" => File.exist?(path) && (started.nil? || File.mtime(path) >= started)}
        end
        info = {"run_id" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"], "step" => run["current"],
                "attempt" => attempt["n"], "state" => state["state"], "instructions" => attempt["prompt_file"],
                "artifacts_dir" => run["artifacts_dir"], "produces" => produces, "check" => !step["status"].nil?,
                "reported" => attempt["reported"]&.slice("status", "summary")}
        return document("step" => info) if json
        @output.puts "Step #{info["step"]} (attempt #{info["attempt"]}, #{info["state"]}) of workflow run #{info["run_id"]} (#{info["workflow"]}) in #{info["workspace"]}."
        @output.puts "Instructions: #{info["instructions"]}" if info["instructions"]
        produces.each do |file|
          found = if file["current"]
            "there"
          else
            file["exists"] ? "left by an earlier attempt; write it again" : "missing"
          end
          @output.puts "Must be written by the time your turn ends: #{file["path"]} (#{found})"
        end
        @output.puts "When your turn ends, the runner runs the step's check." if info["check"]
        @output.puts "Reported: #{info["reported"]["status"]}#{" (#{info["reported"]["summary"]})" if info["reported"]["summary"]}" if info["reported"]
      end

      private

      # The id a text with no --id is checked as when it names none.
      STDIN_ID = "stdin"
      FILE_ID = "file"

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

      def file_id(path)
        name = File.basename(path, ".*")
        WorkflowDefinition::ID_PATTERN.match?(name) ? name : FILE_ID
      end

      def document(body)
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true}.merge(body))
      end

      def show_source(id, json)
        found = @catalog.source(id)
        data = {"id" => id}.merge(found)
        data = WorkflowDefinition.parse(found["text"], id: id, source: found["source"], path: found["path"]).to_h.merge(data) if found["problems"].empty?
        return document("workflow" => data) if json
        @output.print found["text"] if found["text"]
        found["problems"].each { |problem| @error_output.puts "#{id}: #{problem}" }
      end

      def list(json)
        entries = @catalog.list
        return document("workflows" => entries) if json
        @output.puts "No workflows." if entries.empty?
        entries.each do |entry|
          problems = entry["problems"].any? ? "  INVALID: #{entry["problems"].first}" : ""
          @output.puts "#{entry["id"].ljust(16)} #{entry["source"].ljust(8)} #{entry["title"]}#{problems}"
        end
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
      # Whether the run's current step has a `guard:` or a `status:` check. An agent that
      # re-ran its own check from a shell could put a fake `git` first on PATH.
      def checked_step?(run)
        step = Array(run.dig("definition", "steps")).find { |each| each["id"] == run["current"] }
        !!(step && (step["guard"] || step["status"]))
      end

      def resume_pane(stored, pane)
        return @panes.locate(stored["workspace"], pane) if pane
        gone = stored.dig("reason", "code") == "pane_gone" || (@panes.pane_of(stored["id"]) && !@panes.alive?(stored["id"]))
        gone ? @panes.default_pane(stored["workspace"]) : nil
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
      def refuse_caller!(run, caller_pane, verb, subject = "A gate is passed by a person")
        refuse_bound_pane!(caller_pane, verb, subject)
        pane = @panes.pane_of(run["id"]) || run["pane"]
        pane_pid = pane && pane_pid(run["workspace"], pane)
        return unless pane_pid && under?(pane_pid)
        agent = calling_agent
        raise Workspace::Error.new("#{subject}: this process runs under pane #{pane}, which workflow run #{run["id"]} " \
          "is bound to, so `#{verb}` is refused here. Run it from another terminal.",
          code: "bound_pane", details: {"pane" => pane, "run_id" => run["id"], "agent" => agent})
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

      # The action row for a run after a transition. A step that could not be
      # started is a failed action, though the run exists and can be resumed.
      def row(run, verb, message: nil)
        shown = @status.run(run["id"])["runs"].first
        reason = shown.dig("current", "reason")
        undelivered = reason && reason.dig("details", "kind") == "dispatch"
        describe(shown)
        @output.puts message if message
        {"workspace" => run["workspace"], "outcome" => undelivered ? "failed" : verb, "reason" => reason&.fetch("code"),
         "message" => undelivered ? reason.dig("details", "message") : message, "run" => shown}
      end

      def describe(run)
        current = run["current"]
        where = %w[completed cancelled failed].include?(run["state"]) ? "" : "  step #{current["step"]}#{" (attempt #{current["attempt"]})" if current["attempt"]}, #{current["state"]}"
        @output.puts "#{run["id"]}  #{run["workflow"]}  #{run["workspace"]}  #{run["state"]}#{where}"
        reason = current["reason"]
        @output.puts "  #{reason["code"]}: #{reason_text(reason)}" if reason
        current["flags"].each { |flag| @output.puts "  flag: #{flag}" }
        reason&.fetch("actions")&.each { |action| @output.puts "    workspace #{action["action"]} #{(action["args"] + needed(action)).join(" ")}" }
      end

      # What a person has to supply, shown as an upper-case placeholder where it goes.
      def needed(action)
        action["needs"].flat_map { |need| [need["flag"] || "--", need["name"].upcase] }
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
            ("and background tasks were still listed after 90 minutes: #{tasks.join(", ")}" if tasks.any?)].compact.join(" ")
        when "failed_check"
          if details["cause"] == "reported"
            "step #{details["step"]} was reported failed#{": #{details["summary"]}" if details["summary"]}"
          else
            "step #{details["step"]}'s check #{details["timed_out"] ? "ran past its time limit" : "exited #{details["exit_code"].inspect}"}; log: #{details["log"]}"
          end
        when "pane_gone" then "pane #{details["pane"]} of #{details["workspace"]} is not running#{": #{details["message"]}" if details["message"]}"
        else details.to_s
        end
      end
    end
  end
end
