require "digest"
require "fileutils"
require "json"

module Workspace
  module Commands
    # `spine show` and `spine set`: one workspace's plan spine (the `spine/` folder of its notes
    # directory) as the stages {SpineTree} reads from it, and the one write to it, a stage's status.
    # `show` is read-only: it creates no folder and writes no file, and a bad file is a warning in
    # the answer, never an error.
    class Spine
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The longest `--note`, as long as the `note:` a reader keeps.
      MAX_NOTE = SpineFile::VALUE_LIMITS.fetch("note")

      # The longest `--by`.
      MAX_BY = 100

      # What `updated_by` holds when the caller is not a known agent pane.
      PERSON = "person"

      # Pane kinds that are not a coding agent.
      NOT_AGENTS = %w[shell unknown].freeze

      # Characters a one-line value may not hold: controls, format characters and line separators.
      UNFIT = /[\p{Cc}\p{Cf}  ]/

      # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are
      # @param writer [Workspace::SpineWriter, nil] rewrites a stage file; `set` needs it
      # @param event_log [Workspace::EventLog, nil] gets `spine_changed`
      # @param lock_dir [String, nil] the CLI's state folder for the per-workspace write lock (never the notes folder); `set` needs it
      # @param env [Hash] environment lookup (`TMUX_PANE`)
      # @param clock [#call] returns the current Time
      # @param lock_wait [Numeric] seconds `set` waits for another writer before it gives up
      # @param output [IO]
      def initialize(notes:, writer: nil, event_log: nil, lock_dir: nil, env: ENV, clock: -> { Time.now }, lock_wait: 10, output: $stdout)
        @notes = notes
        @writer = writer
        @event_log = event_log
        @lock_dir = lock_dir
        @env = env
        @clock = clock
        @lock_wait = lock_wait
        @output = output
      end

      # Sets the status of one stage, and with +recursive+ of the stages under it that are not done.
      # Writers of one workspace take turns; each file is written whole, in tree order, and a refusal
      # stops the run with what was already written in `details.written`.
      #
      # @param name [String] the workspace
      # @param path [String] a stage path such as `implement/api`
      # @param status [String] a status or an alias; written as the canonical value
      # @param note [String, nil] one line; nil keeps the note when the status stays and clears it when it changes
      # @param if_revision [String, nil] refuse with `stale_revision` unless the stage file's revision is this
      # @param recursive [Boolean] also set every sub-stage that is neither `completed` nor `skipped`
      # @param by [String, nil] the `updated_by` label; default the agent label of `$TMUX_PANE`, else `person`
      # @param json [Boolean] print one JSON document instead of a summary
      # @return [void]
      # @raise [Workspace::UsageError] a note or label that is not one short line
      # @raise [Workspace::Error] `unknown_workspace`, `invalid_status`, `no_spine`, `unknown_stage`, `stale_revision`,
      #   `spine_unwritable`, or what {#show} raises
      def set(name:, path:, status:, note: nil, if_revision: nil, recursive: false, by: nil, json: false)
        canonical = SpineFile.canonical_status(status)
        unless SpineFile::STATUSES.include?(canonical)
          raise Workspace::Error.new("'#{status}' is not a status to set. Use one of: #{SpineFile::STATUSES.join(", ")}.",
            code: "invalid_status", details: {"status" => status, "allowed" => SpineFile::STATUSES})
        end
        note = one_line(note, "--note", MAX_NOTE)
        by = one_line(by, "--by", MAX_BY)
        raise Workspace::UsageError, "--by can't be empty." if by&.empty?

        notes_dir = @notes.info(name: name)["dir"]
        written = []
        unchanged = []
        with_lock(name) do
          tree = SpineTree.read(real(notes_dir))
          raise Workspace::Error.new("#{name} has no spine/ in its notes directory.", code: "no_spine", details: {"workspace" => name, "dir" => tree.dir}) unless tree.exists
          stage = tree.find(path) || raise(unknown_stage(name, path, tree))
          by ||= default_by(name)
          targets(stage, recursive).each_with_index do |target, index|
            write_stage(name, target, canonical, note, by, (index.zero? ? if_revision : nil), recursive, written, unchanged)
          end
        end
        report(name, written, unchanged, json)
      end

      # @param name [String] the workspace
      # @param json [Boolean] print the document documented in docs/README.spine.md instead of a short summary
      # @return [void]
      # @raise [Workspace::Error] `unknown_workspace`, `notes_dir_unresolved` or `config_parse`; never because of a file's content
      def show(name:, json: false)
        tree = read(name)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}.merge(tree.to_h))
        else
          print_text(name, tree)
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

      private

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

      def write_stage(name, stage, status, note, by, if_revision, recursive, written, unchanged)
        unless stage.file
          raise refusal(Workspace::Error.new("#{stage.path} has no stage file, only a folder, so there is nothing to write.",
            code: "spine_unwritable", details: {"file" => stage.relative, "reason" => "no_file"}), recursive, written)
        end
        updated = @clock.call.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        result = begin
          @writer.write(stage.file.path, relative: stage.relative, status: status, note: note, by: by,
            updated: updated, if_revision: if_revision)
        rescue Workspace::Error => e
          raise refusal(e, recursive, written)
        end
        unless result.changed
          unchanged << {"path" => stage.path, "file" => stage.relative, "status" => result.status, "revision" => result.revision}
          return
        end
        entry = {"path" => stage.path, "file" => stage.relative, "status" => result.status, "previous" => result.previous,
                 "revision" => result.revision, "updated" => updated, "updated_by" => by, "note" => result.note}
        written << entry
        @event_log&.record(type: "spine_changed", project: name, data: {"workspace" => name, "path" => stage.path,
                                                                        "status" => result.status, "previous" => result.previous, "note" => result.note, "by" => by, "revision" => result.revision})
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
        raise Workspace::Error, "spine set is not available: no writer or lock folder was wired" unless @writer && @lock_dir
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
            "#{row["path"]} still #{row["status"]}, note #{row["note"] ? "changed" : "cleared"}"
          else
            "#{row["path"]} set to #{row["status"]} (was #{row["previous"]})"
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

      def print_text(name, tree)
        unless tree.exists
          @output.puts "#{name}: no spine/ in #{File.dirname(tree.dir)}"
          return
        end
        count = 0
        tree.each_stage { count += 1 }
        @output.puts "#{name}: #{count} #{(count == 1) ? "stage" : "stages"} in #{tree.dir}"
        @output.puts "Goal: #{tree.goal.value("title")}" if tree.goal&.value("title")
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
