require "digest"
require "fileutils"
require "json"

module Workspace
  module Commands
    # `spine show` and `spine set`: one workspace's plan spine (the `spine/` folder of its notes
    # directory) as the stages {SpineTree} reads from it, and the one write to it, a stage's status, note and owner.
    # `show` is read-only: it creates no folder and writes no file, and a bad file is a warning in
    # the answer, never an error.
    class Spine
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The longest `--note`, as long as the `note:` a reader keeps.
      MAX_NOTE = SpineFile::VALUE_LIMITS.fetch("note")

      # The longest `--owner`.
      MAX_OWNER = 64

      # The longest `--by`.
      MAX_BY = 100

      # What `updated_by` holds when the caller is not a known agent pane.
      PERSON = "person"

      # Pane kinds that are not a coding agent.
      NOT_AGENTS = %w[shell unknown].freeze

      # The sources of an evaluation that read nothing (no stages to judge, or no reader wired).
      NOT_READ = %w[plan git gh review panes].to_h { |source| [source, "not_needed"] }.freeze

      # Characters a one-line value may not hold: controls, format characters and line separators.
      UNFIT = /[\p{Cc}\p{Cf}  ]/

      # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are
      # @param writer [Workspace::SpineWriter, nil] rewrites a stage file; `set` needs it
      # @param event_log [Workspace::EventLog, nil] gets `spine_changed`
      # @param lock_dir [String, nil] the CLI's state folder for the per-workspace write lock (never the notes folder); `set` needs it
      # @param env [Hash] environment lookup (`TMUX_PANE`)
      # @param clock [#call] returns the current Time
      # @param lock_wait [Numeric] seconds `set` waits for another writer before it gives up
      # @param spine_facts [Workspace::SpineFacts, #call, nil] what `show --evaluate` reads the facts with; a callable is called when first needed
      # @param spine_inferred [Workspace::SpineInferred, #call, nil] what `show --evaluate` infers the stages with when there
      #   is no `spine/`; a callable is called when first needed
      # @param output [IO]
      def initialize(notes:, writer: nil, event_log: nil, lock_dir: nil, env: ENV, clock: -> { Time.now }, lock_wait: 10, spine_facts: nil,
        spine_inferred: nil, output: $stdout)
        @notes = notes
        @spine_facts = spine_facts
        @spine_inferred = spine_inferred
        @writer = writer
        @event_log = event_log
        @lock_dir = lock_dir
        @env = env
        @clock = clock
        @lock_wait = lock_wait
        @output = output
      end

      # Sets the status, note or owner of one stage, and with +recursive+ of the stages under it that are not done.
      # Writers of one workspace take turns; each file is written whole, in tree order, and a refusal
      # stops the run with what was already written in `details.written`.
      #
      # @param name [String] the workspace
      # @param path [String] a stage path such as `implement/api`
      # @param status [String, nil] a status or an alias, written as the canonical value; nil leaves the status alone
      # @param note [String, nil] one line (empty clears); nil keeps the note when the status stays and clears it when it changes
      # @param owner [String, nil] a pane id, `you` or an agent label, one line of at most 64 characters (empty clears); nil leaves it alone
      # @param if_revision [String, nil] refuse with `stale_revision` unless the stage file's revision is this
      # @param recursive [Boolean] also set every sub-stage that is neither `completed` nor `skipped`
      # @param by [String, nil] the `updated_by` label; default the agent label of `$TMUX_PANE`, else `person`
      # @param json [Boolean] print one JSON document instead of a summary
      # @return [void]
      # @raise [Workspace::UsageError] none of status, note and owner given; an owner with +recursive+; a note, owner or label that is not one short line
      # @raise [Workspace::Error] `unknown_workspace`, `invalid_status`, `no_spine`, `unknown_stage`, `stale_revision`,
      #   `spine_unwritable`, or what {#show} raises
      def set(name:, path:, status: nil, note: nil, owner: nil, if_revision: nil, recursive: false, by: nil, json: false)
        raise Workspace::UsageError, "Give at least one of --status, --note and --owner." if status.nil? && note.nil? && owner.nil?
        raise Workspace::UsageError, "--owner can't be used with --recursive: an owner belongs to one stage." if owner && recursive
        canonical = status && SpineFile.canonical_status(status)
        if status && !SpineFile::STATUSES.include?(canonical)
          raise Workspace::Error.new("'#{status}' is not a status to set. Use one of: #{SpineFile::STATUSES.join(", ")}.",
            code: "invalid_status", details: {"status" => status, "allowed" => SpineFile::STATUSES})
        end
        note = one_line(note, "--note", MAX_NOTE)
        owner = one_line(owner, "--owner", MAX_OWNER)
        values = {"status" => canonical, "note" => note, "owner" => owner}.compact
        by = one_line(by, "--by", MAX_BY)
        raise Workspace::UsageError, "--by can't be empty." if by&.empty?

        notes_dir = @notes.info(name: name)["dir"]
        written = []
        unchanged = []
        @what = {}
        with_lock(name) do
          _, stage = stage!(name, path, SpineTree.read(real(notes_dir)))
          by ||= default_by(name)
          targets(stage, recursive).each_with_index do |target, index|
            write_stage(name, target, values, by, (index.zero? ? if_revision : nil), recursive, written, unchanged)
          end
        end
        report(name, written, unchanged, json)
      end

      # Ticks or unticks items of one stage's `## Done when` checklist (see {SpineWriter#check}), under the same
      # write lock as {#set}. It records `spine_changed` with `change: "done_when"` when a box changed.
      #
      # @param name [String] the workspace
      # @param path [String] a stage path
      # @param items [Array<Integer>] 1-based item numbers, as `show` lists them
      # @param done [Boolean] true to tick, false to untick
      # @param if_revision [String, nil] refuse with `stale_revision` unless the stage file's revision is this
      # @param by [String, nil] the label in the event; default the agent label of `$TMUX_PANE`, else `person`
      # @param json [Boolean] print one JSON document instead of a summary
      # @return [void]
      # @raise [Workspace::UsageError] no item given, or an item that is not a positive number
      # @raise [Workspace::Error] `no_spine`, `unknown_stage`, `unknown_item`, `stale_revision`, `spine_unwritable`
      def check(name:, path:, items:, done:, if_revision: nil, by: nil, json: false)
        raise Workspace::UsageError, "Give at least one --item N." if items.nil? || items.empty?
        raise Workspace::UsageError, "--item takes a positive number." unless items.all? { |n| n.is_a?(Integer) && n.positive? }
        by = one_line(by, "--by", MAX_BY)
        raise Workspace::UsageError, "--by can't be empty." if by&.empty?

        notes_dir = @notes.info(name: name)["dir"]
        stage = result = nil
        with_lock(name) do
          _, stage = stage!(name, path, SpineTree.read(real(notes_dir)))
          raise no_file(stage) unless stage.file
          by ||= default_by(name)
          result = @writer.check(stage.file.path, relative: stage.relative, numbers: items, done: done, if_revision: if_revision)
          record_check(name, stage, result, by) if result.changed
        end
        report_check(name, stage, result, done, json)
      end

      # Sets the goal's `title:` (see {SpineWriter#goal}), under the same write lock as {#set}; makes `spine/goal.md`
      # when it is missing. It records `spine_changed` with `change: "goal"` when the file changed.
      #
      # @param name [String] the workspace
      # @param text [String] one line of at most 120 characters
      # @param if_revision [String, nil] refuse with `stale_revision` unless `goal.md`'s revision is this
      # @param by [String, nil] the label in the event; default the agent label of `$TMUX_PANE`, else `person`
      # @param json [Boolean] print one JSON document instead of a summary
      # @return [void]
      # @raise [Workspace::UsageError] +text+ empty, over 120 characters, or not one line
      # @raise [Workspace::Error] `no_spine`, `stale_revision`, `spine_unwritable`
      def goal_set(name:, text:, if_revision: nil, by: nil, json: false)
        title = one_line(text, "TEXT", SpineFile::VALUE_LIMITS.fetch("title"))
        raise Workspace::UsageError, "Give the goal as TEXT." if title.nil? || title.empty?
        by = one_line(by, "--by", MAX_BY)
        raise Workspace::UsageError, "--by can't be empty." if by&.empty?

        notes_dir = @notes.info(name: name)["dir"]
        result = nil
        with_lock(name) do
          tree = SpineTree.read(real(notes_dir))
          raise Workspace::Error.new("#{name} has no spine/ in its notes directory. Run 'workspace spine init' first.", code: "no_spine", details: {"workspace" => name, "dir" => tree.dir}) unless tree.exists
          by ||= default_by(name)
          result = @writer.goal(File.join(tree.dir, SpineTree::GOAL_FILE), relative: SpineTree::GOAL_FILE, title: title, if_revision: if_revision)
          if result.changed
            @event_log&.record(type: "spine_changed", project: name, data: {"workspace" => name, "change" => "goal", "title" => result.title,
                                                                            "created" => result.created, "by" => by, "revision" => result.revision})
          end
        end
        goal = {"file" => SpineTree::GOAL_FILE, "title" => result.title, "revision" => result.revision}
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name, "goal" => goal, "created" => result.created, "changed" => result.changed})
        elsif result.created
          @output.puts "#{name}: goal.md made: #{result.title}"
        elsif result.changed
          @output.puts "#{name}: goal set: #{result.title}"
        else
          @output.puts "#{name}: goal already reads: #{result.title}"
        end
      end

      # @param name [String] the workspace
      # @param json [Boolean] print the document documented in docs/README.spine.md instead of a short summary
      # @param stage [String, nil] a stage path: show that one stage (and its sub-stages) instead of the tree
      # @param body [Boolean] add the text after the frontmatter: to the one stage, else to the goal
      # @param evaluate [Boolean] judge every stage against the plan, git, the pull request, the review agent
      #   and the panes (see {SpineEvaluator}); the only form of `show` that starts a process. A source that
      #   can't answer leaves its gates `unchecked`; it never fails the command. With no `spine/`, the stages are
      #   inferred (see {SpineInferred}) and listed under `inferred`
      # @return [void]
      # @raise [Workspace::Error] `unknown_workspace`, `notes_dir_unresolved` or `config_parse`; `unknown_stage` for a +stage+ that is not there
      def show(name:, json: false, stage: nil, body: false, evaluate: false)
        tree = read(name)
        found = stage && (tree.find(stage) || raise(unknown_stage(name, stage, tree)))
        return show_evaluated(name, tree, found, json, body) if evaluate
        if json
          head = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}
          doc = if found
            full = tree.to_h
            head.merge("dir" => full["dir"], "goal" => full["goal"], "stage" => found.to_h(body: body))
          else
            head.merge(tree.to_h(body: body))
          end
          @output.puts JSON.generate(doc)
        elsif found
          print_stage(found, body)
        else
          print_text(name, tree, body)
        end
      end

      # Whether the workspace has a `spine/` folder in its notes directory. A link named `spine` is not
      # one, and nothing is read, created or written.
      #
      # @param name [String] the workspace
      # @return [Boolean] false too when the notes directory can't be worked out
      def exists?(name:)
        dir = File.join(real(@notes.info(name: name)["dir"]), SpineTree::DIR_NAME)
        stat = File.lstat(dir)
        stat.directory? && !stat.symlink?
      rescue Workspace::Error, SystemCallError
        false
      end

      # @param name [String] the workspace
      # @return [SpineTree] the spine in the workspace's notes directory
      # @raise [Workspace::Error] as {#show}
      def read(name)
        notes_dir = @notes.info(name: name)["dir"]
        SpineTree.read(real(notes_dir))
      end

      # @param name [String] the workspace
      # @param path [String] a stage path
      # @param tree [SpineTree, nil] an already read tree; read when nil
      # @return [Array(SpineTree, SpineTree::Stage)]
      # @raise [Workspace::Error] `no_spine`, `unknown_stage`, or what {#read} raises
      def stage!(name, path, tree = nil)
        tree ||= read(name)
        raise Workspace::Error.new("#{name} has no spine/ in its notes directory.", code: "no_spine", details: {"workspace" => name, "dir" => tree.dir}) unless tree.exists
        [tree, tree.find(path) || raise(unknown_stage(name, path, tree))]
      end

      # One write to one stage file, as {#set} makes it, for `spine start`: under the workspace's write lock the
      # tree is read again and yielded with the stage, so the caller can refuse before anything changes; then
      # +values+ are written and a `spine_changed` line is recorded when the file changed.
      #
      # @param name [String] the workspace
      # @param path [String] a stage path
      # @param values [Hash{String => String}] as {SpineWriter#write} takes them
      # @param by [String] the `updated_by` label
      # @param if_revision [String, nil] refuse with `stale_revision` unless the file's revision is this
      # @yieldparam tree [SpineTree]
      # @yieldparam stage [SpineTree::Stage]
      # @return [Array(SpineTree::Stage, SpineWriter::Result)]
      # @raise [Workspace::Error] `no_spine`, `unknown_stage`, `stale_revision`, `spine_unwritable`, or what the block raises
      def write_one(name:, path:, values:, by:, if_revision: nil)
        notes_dir = @notes.info(name: name)["dir"]
        with_lock(name) do
          tree, stage = stage!(name, path, SpineTree.read(real(notes_dir)))
          yield tree, stage if block_given?
          raise no_file(stage) unless stage.file
          result = @writer.write(stage.file.path, relative: stage.relative, values: values, by: by,
            updated: @clock.call.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), if_revision: if_revision)
          record_change(name, stage, result, by) if result.changed
          [stage, result]
        end
      end

      # @param stage [SpineTree::Stage]
      # @return [Workspace::Error] `spine_unwritable` with reason `no_file`, for a stage that is only a folder
      def no_file(stage)
        Workspace::Error.new("#{stage.path} has no stage file, only a folder, so there is nothing to write.",
          code: "spine_unwritable", details: {"file" => stage.relative, "reason" => "no_file"})
      end

      private

      def show_evaluated(name, tree, found, json, body)
        inferrer = tree.exists ? nil : wired_inferred
        reading = (tree.exists || inferrer) ? live_facts(name, tree) : nil
        verdict = SpineEvaluator.call(tree, reading ? reading.facts : SpineEvaluator::Facts.new)
        if inferrer && reading
          verdict["inferred"] = inferrer.infer(workspace: name, checkout: @notes.checkout_root(name), result: reading)
          verdict["current"] = SpineEvaluator.current(verdict["inferred"])
        end
        sources = reading ? reading.sources : NOT_READ
        evaluated_at = @clock.call.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        verdict["goal"] = tree.to_h(body: true)["goal"] if body && !found
        stage_doc = found && find_doc(verdict["stages"], found.path)
        stage_doc&.merge!(SpineTree.body_keys(found.file)) if body
        unless json
          return print_evaluated_stage(stage_doc, sources, body, found) if found
          return print_evaluated(name, tree, verdict, sources, body)
        end
        head = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}
        tail = {"evaluated" => true, "evaluated_at" => evaluated_at, "current" => verdict["current"], "sources" => sources}
        doc = if found
          head.merge("dir" => verdict["dir"], "goal" => verdict["goal"], "stage" => stage_doc).merge(tail)
        else
          head.merge(verdict).merge(tail)
        end
        @output.puts JSON.generate(doc)
      end

      def live_facts(name, tree)
        reader = @spine_facts.respond_to?(:read) ? @spine_facts : @spine_facts&.call
        return nil unless reader
        gates = tree.exists ? SpineFacts.gates_in(tree.stages) : SpineInferred::FACT_GATES
        reader.read(workspace: name, checkout: @notes.checkout_root(name), notes_dir: File.dirname(tree.dir), gates: gates)
      end

      def wired_inferred = @spine_inferred.respond_to?(:infer) ? @spine_inferred : @spine_inferred&.call

      def find_doc(docs, path)
        docs.each do |doc|
          return doc if doc["path"] == path
          found = find_doc(doc["children"], path)
          return found if found
        end
        nil
      end

      def print_evaluated(name, tree, verdict, sources, body)
        unless tree.exists
          inferred = verdict["inferred"]
          @output.puts "#{name}: no spine/ in #{File.dirname(tree.dir)}#{"; inferred stages:" if inferred}"
          return unless inferred
          @output.puts "Current: #{verdict["current"] || "none"}"
          print_verdicts(inferred, 0)
          print_sources(sources)
          return
        end
        count = 0
        tree.each_stage { count += 1 }
        @output.puts "#{name}: #{count} #{(count == 1) ? "stage" : "stages"} in #{tree.dir}"
        @output.puts "Goal: #{tree.goal.value("title")}" if tree.goal&.value("title")
        print_body(tree.goal, body)
        @output.puts "Current: #{verdict["current"] || "none"}"
        print_verdicts(verdict["stages"], 0)
        print_sources(sources)
        tree.warnings.each { |w| @output.puts "warning #{w["code"]}: #{w["message"]}" }
      end

      def print_evaluated_stage(doc, sources, body, stage)
        @output.puts "Current: #{doc["current"] || "none"}"
        print_verdicts([doc], 0)
        stage.file&.value("description")&.then { |text| @output.puts "Description: #{text}" }
        stage.all_warnings.each { |w| @output.puts "warning #{w["code"]}: #{w["message"]}" }
        print_body(stage.file, body)
        print_sources(sources)
      end

      def print_verdicts(docs, depth)
        docs.each do |doc|
          pad = "  " * (depth + 1)
          line = "#{"  " * depth}#{doc["number"]} #{doc["id"]}  #{doc["state"]}"
          line << " (file says #{doc["status"]})" if doc["state"] == "disputed"
          line << " (from sub-stages)" if doc["from_sub_stages"]
          line << "  looks completed" if doc["looks_completed"]
          line << "  owner #{doc["owner"]}" if doc["owner"]
          line << " (#{doc["owner_state"]})" if doc["owner_state"]
          line << "  waits on #{doc["waits_on"].join(", ")}" unless doc["waits_on"].empty?
          line << "  dimmed" if doc["dimmed"]
          line << "  from #{doc["source"]}" if doc["inferred"]
          @output.puts line
          doc["disputes"].each { |dispute| @output.puts "#{pad}#{dispute["message"]}" }
          doc["gate_results"].each do |gate|
            next if gate["result"] == "pass" || (gate["result"] == "fail" && doc["state"] == "disputed")
            @output.puts "#{pad}#{gate["gate"]} #{gate["result"]}: #{gate["message"]}"
          end
          print_verdicts(doc["children"], depth + 1)
        end
      end

      def print_sources(sources)
        off = sources.reject { |_, status| status == "ok" || status == "not_needed" }
        @output.puts "Not read: #{off.map { |source, status| "#{source} (#{status})" }.join(", ")}" unless off.empty?
      end

      def one_line(text, flag, limit)
        return nil if text.nil?
        text = text.strip
        raise Workspace::UsageError, "#{flag} must be one line of at most #{limit} characters, without control characters." if text.size > limit || text.match?(UNFIT)
        text
      end

      def unknown_stage(name, path, tree)
        paths = []
        tree.each_stage { |stage| paths << stage.path }
        Workspace::Error.new("#{name} has no stage '#{path.inspect[1..-2]}'. Stages: #{paths.empty? ? "none" : paths.join(", ")}.",
          code: "unknown_stage", details: {"path" => path, "stages" => paths})
      end

      # The stage, then with +recursive+ the sub-stages under it that are not done, parents first. A stage whose
      # folder has no file is nothing to write: it is left out below the first, and refused as the first.
      def targets(stage, recursive)
        return [stage] unless recursive
        found = [stage]
        walk = lambda do |parent|
          parent.children.each do |child|
            found << child unless child.file.nil? || %w[completed skipped].include?(child.status)
            walk.call(child)
          end
        end
        walk.call(stage)
        found
      end

      def write_stage(name, stage, values, by, if_revision, recursive, written, unchanged)
        raise refusal(no_file(stage), recursive, written) unless stage.file
        updated = @clock.call.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        result = begin
          @writer.write(stage.file.path, relative: stage.relative, values: values, by: by,
            updated: updated, if_revision: if_revision)
        rescue Workspace::Error => e
          raise refusal(e, recursive, written)
        end
        unless result.changed
          unchanged << {"path" => stage.path, "file" => stage.relative, "status" => result.status, "owner" => result.owner, "revision" => result.revision}
          return
        end
        entry = {"path" => stage.path, "file" => stage.relative, "status" => result.status, "previous" => result.previous,
                 "revision" => result.revision, "updated" => updated, "updated_by" => by, "note" => result.note, "owner" => result.owner}
        @what[stage.path] = [field_change("note", result.previous_note, result.note), field_change("owner", result.previous_owner, result.owner)].compact.join(", ")
        written << entry
        record_change(name, stage, result, by)
      end

      def record_change(name, stage, result, by)
        data = {"workspace" => name, "path" => stage.path, "status" => result.status, "previous" => result.previous,
                "note" => result.note, "owner" => result.owner, "by" => by, "revision" => result.revision}
        data["change"] = "owner" if result.status == result.previous && result.note == result.previous_note
        @event_log&.record(type: "spine_changed", project: name, data: data)
      end

      def record_check(name, stage, result, by)
        data = {"workspace" => name, "path" => stage.path, "change" => "done_when", "items" => result.changed_items,
                "by" => by, "revision" => result.revision}
        @event_log&.record(type: "spine_changed", project: name, data: data)
      end

      def report_check(name, stage, result, done, json)
        total = result.items.size
        count = result.items.count { |item| item["done"] }
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name, "path" => stage.path,
            "file" => stage.relative, "items" => result.items, "done_when" => {"total" => total, "done" => count},
            "changed" => result.changed_items, "revision" => result.revision})
        elsif result.changed
          @output.puts "#{name}: #{stage.path} item #{result.changed_items.join(", ")} #{done ? "ticked" : "unticked"} (#{count}/#{total} done)"
        else
          @output.puts "#{name}: #{stage.path} already reads as asked (#{count}/#{total} done)"
        end
      end

      def field_change(key, before, after)
        return nil if before == after
        if after
          "#{key} #{(key == "note") ? "changed" : "set to #{after}"}"
        else
          "#{key} cleared"
        end
      end

      def refusal(error, recursive, written)
        return error unless recursive
        Workspace::Error.new(error.message, code: error.code, details: error.details.merge("written" => written.dup), retry_with: error.retry)
      end

      # The agent label of the pane the caller runs in (`claude %6`) when the workspace's agent daemon has logged
      # that pane as a coding agent, else `person`.
      def default_by(name)
        pane = @env["TMUX_PANE"].to_s
        return PERSON unless @event_log && pane.match?(/\A%\d+\z/)
        kind = @event_log.latest_agent_states(name).dig(pane, "kind")
        (kind.nil? || NOT_AGENTS.include?(kind)) ? PERSON : "#{kind} #{pane}"
      end

      def with_lock(name)
        raise Workspace::Error, "spine writes are not available: no writer or lock folder was wired" unless @writer && @lock_dir
        lock = open_lock(name)
        begin
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock_wait
          until lock.flock(File::LOCK_EX | File::LOCK_NB)
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              raise Workspace::Error.new("Another spine write for #{name} did not finish within #{@lock_wait} seconds. Nothing was changed; try again.",
                code: "spine_unwritable", details: {"reason" => "lock_busy"})
            end
            sleep 0.02
          end
          yield
        ensure
          lock.close
        end
      end

      def open_lock(name)
        FileUtils.mkdir_p(@lock_dir)
        File.open(File.join(@lock_dir, lock_name(name)), File::RDWR | File::CREAT, 0o600)
      rescue SystemCallError => e
        raise Workspace::Error.new("Can't take the spine write lock for #{name}: #{e.message}. Nothing was changed.",
          code: "spine_unwritable", details: {"reason" => "lock_unavailable"})
      end

      def lock_name(name)
        "#{name.gsub(/[^A-Za-z0-9_-]+/, "_")}-#{Digest::SHA1.hexdigest(name)[0, 8]}.lock"
      end

      def report(name, written, unchanged, json)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name,
            "written" => written, "unchanged" => unchanged})
          return
        end
        written.each do |row|
          line = if row["status"] == row["previous"]
            "#{row["path"]} still #{row["status"]}, #{@what[row["path"]]}"
          else
            ["#{row["path"]} set to #{row["status"]} (was #{row["previous"]})", @what[row["path"]]].reject { |t| t.to_s.empty? }.join(", ")
          end
          @output.puts "#{name}: #{line}"
        end
        unchanged.each { |row| @output.puts "#{name}: #{row["path"]} already reads #{row["status"]}" }
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def print_stage(stage, body)
        print_stages([stage], 0)
        stage.file&.value("description")&.then { |text| @output.puts "Description: #{text}" }
        stage.all_warnings.each { |w| @output.puts "warning #{w["code"]}: #{w["message"]}" }
        print_body(stage.file, body)
      end

      def print_body(file, body)
        return unless body
        text, cut = file&.body_excerpt
        return unless text
        @output.puts
        @output.puts text.gsub(/[\p{Cc}&&[^\n\t]]|\p{Cf}/) { |c| format("\\u{%x}", c.ord) }
        @output.puts "(body cut at #{SpineFile::MAX_BODY} bytes)" if cut
      end

      def print_text(name, tree, body = false)
        unless tree.exists
          @output.puts "#{name}: no spine/ in #{File.dirname(tree.dir)}"
          return
        end
        count = 0
        tree.each_stage { count += 1 }
        @output.puts "#{name}: #{count} #{(count == 1) ? "stage" : "stages"} in #{tree.dir}"
        @output.puts "Goal: #{tree.goal.value("title")}" if tree.goal&.value("title")
        print_body(tree.goal, body)
        print_stages(tree.stages, 0)
        tree.warnings.each { |w| @output.puts "warning #{w["code"]}: #{w["message"]}" }
        @output.puts "Not stages: #{tree.not_stages.join(", ")}" unless tree.not_stages.empty?
        @output.puts "Some entries were left out (#{tree.truncated})." if tree.truncated
      end

      def print_stages(stages, depth)
        stages.each do |stage|
          line = "#{"  " * depth}#{stage.number} #{stage.id}  #{stage.status}"
          line << " (sub-stages #{stage.rollup["status"]})" if stage.rollup
          owner = stage.file&.value("owner")
          line << "  owner #{owner}" if owner
          done = stage.file&.done_when
          line << "  #{done["done"]}/#{done["total"]} done" if done && done["total"].positive?
          warnings = stage.all_warnings.map { |w| w["code"] }.uniq
          line << "  warnings: #{warnings.join(", ")}" unless warnings.empty?
          @output.puts line
          print_stages(stage.children, depth + 1)
        end
      end
    end
  end
end
