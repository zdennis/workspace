require "json"

module Workspace
  module Commands
    # `template backup`, `template backups list|prune` and `template restore`: the batches of tmuxinator configs and
    # render records kept by {TmuxinatorBackupStore}, and putting one back.
    #
    # `restore` takes a batch of its own first (reason `restore`), so a restore can be undone by restoring that
    # one. Each workspace is done in turn inside its startup lock ({NameMigration#with_locks}, which waits) and
    # everything its row decides is read inside it. Per workspace the config and its render record are put back
    # together or not at all: a file is refused (`restore_conflict`) when its sha256 is neither what the batch
    # copied nor what the batch wrote (a `manual` batch wrote nothing, so only the copy), unless `--force`; a file the
    # batch created (no `sha_before`) is deleted. Both files are read before either is written; a record that can't be
    # written puts the config back too.
    class TemplateBackups
      # Bumped whenever a `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # @param backups [Workspace::TmuxinatorBackupStore] the batches
      # @param selection [Workspace::TemplateSelection] settles which workspaces `backup` copies
      # @param locks [Workspace::NameMigration] each workspace's startup lock
      # @param project_config [Workspace::ProjectConfig] finds a config and its path
      # @param retention [Workspace::TmuxinatorBackupConfig] `keep` and `max_age`, for `prune` and the prune after a batch
      # @param writer [Workspace::TmuxinatorConfigWriter] puts files back by its mode rules
      # @param library [Workspace::Library, nil] finds the store a backed-up template set goes back to; nil refuses to restore one
      # @param template_in_use [Workspace::TemplateInUse, nil] `restore` refuses to remove a set a key selects; nil checks nothing
      # @param output [IO] output stream
      def initialize(backups:, selection:, locks:, project_config:, retention:, writer:, library: nil, template_in_use: nil, output: $stdout)
        @template_in_use = template_in_use
        @library = library
        @backups = backups
        @selection = selection
        @locks = locks
        @project_config = project_config
        @retention = retention
        @files = TemplateBatchFiles.new(backups: backups, writer: writer)
        @output = output
      end

      # Copies each selected workspace's config and render record into a new `manual` batch.
      #
      # @param names [Array<String>] workspaces by name
      # @param all [Boolean] every workspace that has a config
      # @param project [nil, true, String] `--project`
      # @param cwd [String] where the current workspace is looked for
      # @param json [Boolean] print nothing; the caller prints the action document
      # @return [Hash] `results`, `status`, `exit_code`, `warnings` and `extra` (`backup`: the batch id, nil when nothing was copied)
      # @raise [Workspace::UsageError] for names mixed with `--all` or `--project`
      # @raise [Workspace::Error] `unknown_workspace`, `not_in_workspace`, or a batch that can't be made
      def backup(names: [], all: false, project: nil, cwd: Dir.pwd, json: false)
        selected = @selection.call(names: names, all: all, project: project, working_dir: cwd)
        batch = open_batch("manual")
        rows = selected.map do |name|
          locked(name) do
            next row(name, "skipped", "gone", "its tmuxinator config is gone") unless @project_config.exists?(name)
            @backups.add(batch, name: name, path: @project_config.config_path_for(name))
            row(name, "backed_up", nil, nil)
          rescue Error => e
            failed(name, e.code, e.message)
          rescue SystemCallError, IOError => e
            failed(name, "error", e.message)
          end
        end
        warnings = []
        id = close(batch, warnings)
        rows.each { |r| puts_row(r) } unless json
        @output.puts "Backup: #{id}" if id && !json
        result(rows, warnings, {"backup" => id})
      end

      # Prints the batches, newest first.
      #
      # @param json [Boolean] print the document instead of the table
      # @return [void]
      def list(json: false)
        rows = @backups.list.map { |manifest| batch_row(manifest) }
        if json
          @output.puts JSON.generate(JsonEnvelope.document("backups", rows, schema_version: JSON_SCHEMA_VERSION))
        elsif rows.empty?
          @output.puts "No tmuxinator backups."
        else
          rows.each do |r|
            line = "#{r["id"]}  #{r["reason"].to_s.ljust(7)}  #{r["workspaces"].length} workspace#{"s" unless r["workspaces"].length == 1}"
            line += ", templates: #{r["templates"].map { |t| TerminalText.escape(t) }.join(", ")}" if r["templates"].any?
            @output.puts line
          end
        end
      end

      # Removes the batches past `tmuxinator.backups.keep` and `tmuxinator.backups.max_age`.
      #
      # @param json [Boolean] print nothing; the caller prints the action document
      # @return [Hash] `results` (one `pruned` row per batch removed), `status`, `exit_code`, `extra` (`kept`)
      def prune(json: false)
        removed = @backups.prune(keep: @retention.keep, max_age: @retention.max_age)
        rows = removed.map { |id| {"id" => id, "outcome" => "pruned"} }
        @output.puts(removed.empty? ? "Nothing to prune." : removed.map { |id| "Pruned #{id}" }) unless json
        {results: rows, status: "ok", exit_code: 0, extra: {"kept" => @backups.list.length}}
      end

      # Puts a batch's configs, render records and template sets back. A set goes back through the library's own temp-and-rename
      # write after the set it replaces is copied into the restore's batch; one changed since the batch wrote it is refused
      # (`restore_conflict`) unless +force+.
      #
      # @param id [String] the batch id
      # @param names [Array<String>] only these workspaces or template sets of the batch; none is all of them
      # @param force [Boolean] also put back over a file changed since the batch wrote it
      # @param json [Boolean] print nothing; the caller prints the action document
      # @return [Hash] `results`, `status`, `exit_code`, `warnings` and `extra` (`backup`: the batch taken first, `restored_from`)
      # @raise [Workspace::Error] `backup_not_found`, `unknown_workspace` for a name the batch has no entry for, or a batch that can't be made
      def restore(id:, names: [], force: false, json: false)
        manifest = @backups.find(id)
        entries, sets = entries_for(manifest, names)
        batch = open_batch("restore")
        rows = entries.map { |entry| locked(entry["name"]) { restore_one(manifest, entry, batch, force) } }
        rows += sets.map { |set| restore_set(manifest, set, batch, force) }
        warnings = []
        kept = close(batch, warnings)
        unless json
          rows.each { |r| puts_row(r) }
          @output.puts "Backup: #{kept}" if kept
        end
        result(rows, warnings, {"backup" => kept, "restored_from" => id})
      end

      private

      # The workspace entries and the template sets +names+ pick out of a batch (a name no entry and no set has is unknown).
      def entries_for(manifest, names)
        return [manifest["entries"], manifest["sets"]] if names.empty?
        found = names.uniq.map do |name|
          entry = manifest["entries"].find { |listed| listed["name"] == name }
          set = manifest["sets"].find { |listed| listed["name"] == name } unless entry
          entry || set ||
            raise(Error.new("The backup #{manifest["id"]} has no workspace or template '#{name}'.", code: "unknown_workspace", details: {"name" => name, "id" => manifest["id"]}))
        end
        found.partition { |item| manifest["entries"].include?(item) }
      end

      # One template set of an import batch: put back when the library's copy is as the batch left it (or as it was), else
      # refused as changed since, unless +force+. What it replaces goes into the restore's own batch first.
      def restore_set(manifest, set, batch, force)
        name = set["name"]
        label = {"template" => name, "scope" => set["scope"]}
        raise Error, "template restore can't put a template set back: no library was wired" unless @library
        store = @library.write_store(scope: set["scope"], project: set["project"], cwd: Dir.pwd)
        path = store.path_for("template", name)
        now = File.directory?(path) ? LibraryStore.tree_sha(path) : nil
        before = set["sha_before"]
        return set_row(label, "unchanged", nil, "already as the backup has it") if now == before
        if !force && !now.nil? && now != set["sha_after"]
          return set_failed(label, "restore_conflict", "it changed since the backup was written; --force puts the backup over it (after a backup)")
        end
        return remove_set(set, store, path, batch, force, label) if before.nil?
        copy = @backups.set_copy_path(manifest, set)
        return set_failed(label, "backup_incomplete", "the backup holds no copy of this set") unless copy
        @backups.add_set(batch, name: name, scope: set["scope"], project: set["project"], path: path)
        begin
          store.copy_tree("template", name, copy)
        ensure
          @backups.finish_set(batch, name: name, scope: set["scope"], project: set["project"], sha_after: File.directory?(path) ? LibraryStore.tree_sha(path) : nil)
        end
        set_row(label, "restored", nil, nil)
      rescue Error => e
        set_failed(label, e.code || "error", e.message)
      rescue SystemCallError, IOError => e
        set_failed(label, "error", e.message)
      end

      # A set the import added (no `sha_before`) goes away again, unless a key selects it and not +force+.
      def remove_set(set, store, path, batch, force, label)
        name = set["name"]
        @template_in_use&.check!(name, store, verb: "remove") unless force
        @backups.add_set(batch, name: name, scope: set["scope"], project: set["project"], path: path)
        begin
          store.delete("template", name)
        ensure
          @backups.finish_set(batch, name: name, scope: set["scope"], project: set["project"], sha_after: File.directory?(path) ? LibraryStore.tree_sha(path) : nil)
        end
        set_row(label, "restored", nil, "removed: the import had added it")
      end

      def set_row(label, outcome, reason, message)
        {"workspace" => nil, "outcome" => outcome, "reason" => reason, "message" => message, "code" => nil}.merge(label)
      end

      def set_failed(label, code, message)
        set_row(label, "failed", code, message).merge("code" => code)
      end

      # One workspace, read and written inside its lock. Both copies and both current files are read into memory
      # before anything is written, and the config and record go back together or not at all.
      def restore_one(manifest, entry, batch, force)
        name = entry["name"]
        config_path, config_before, config_after = @files.facts(entry, :config)
        record_path, record_before, record_after = @files.facts(entry, :record)
        config_now = @files.sha(config_path)
        record_now = @files.sha(record_path)
        return row(name, "unchanged", nil, "already as the backup has it") if config_now == config_before && record_now == record_before
        if config_now.nil? && record_now.nil? && !config_after.nil?
          checkout = checkout_exists?(manifest, entry)
          if checkout == false
            return row(name, "skipped", "gone", "its tmuxinator config and render record are gone and so is its checkout (renamed or removed)")
          elsif checkout.nil? && !force
            return row(name, "skipped", "gone", "its tmuxinator config and render record are gone and the backup doesn't say where its checkout is, so it can't be told from a removed workspace; --force restores it anyway")
          end
        end

        unless force
          changed = []
          changed << "config" unless config_now.nil? || config_now == config_before || config_now == config_after
          changed << "record" unless record_now.nil? || record_now == record_before || record_now == record_after
          if changed.any?
            return failed(name, "restore_conflict", "its #{changed.join(" and ")} changed since the backup was written; --force puts the backup over it (after a backup)", "files" => changed)
          end
        end

        config_copy = @files.before_bytes(manifest, entry, :config)
        record_copy = @files.before_bytes(manifest, entry, :record)
        config_was = @files.read(config_path)
        @backups.add(batch, name: name, path: config_path)
        begin
          @files.write(entry, :config, config_copy)
          begin
            @files.write(entry, :record, record_copy)
          rescue Error, SystemCallError, IOError
            @files.write(entry, :config, config_was)
            raise
          end
        ensure
          @backups.finish(batch, name: name, sha_after: @files.sha(config_path), record_sha_after: @files.sha(record_path))
        end
        row(name, "restored", nil, nil, "files" => %w[config record])
      rescue Error => e
        failed(name, e.code || "error", e.message)
      rescue SystemCallError, IOError => e
        failed(name, "error", e.message)
      end

      # Whether the workspace's checkout is still a directory, read from the batch's render record (its
      # `worktree_path` or `project_root`), else from the `root:` of its config copy (as {TemplateAdopt} reads it).
      #
      # @return [Boolean, nil] nil when neither copy names a checkout
      def checkout_exists?(manifest, entry)
        root = record_root(manifest, entry) || config_root(manifest, entry)
        root && File.directory?(root)
      end

      def record_root(manifest, entry)
        copy = @backups.copy_path(manifest, entry["name"], kind: :record)
        inputs = copy && JSON.parse(File.read(copy))["inputs"]
        root = inputs["worktree_path"] || inputs["project_root"] if inputs.is_a?(Hash)
        root if root.is_a?(String) && !root.empty?
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def config_root(manifest, entry)
        copy = @backups.copy_path(manifest, entry["name"], kind: :config)
        copy && TemplateAdopt.root_of(File.read(copy))
      rescue SystemCallError
        nil
      end

      def open_batch(reason)
        @backups.open(reason: reason)
      rescue SystemCallError => e
        raise Error, "Can't make a tmuxinator backup batch, so nothing was changed: #{e.message}"
      end

      def close(batch, warnings)
        kept = !@backups.discard_if_empty(batch)
        begin
          @backups.prune(keep: @retention.keep, max_age: @retention.max_age)
        rescue SystemCallError => e
          warnings << {"code" => "prune_failed", "message" => "Old tmuxinator backups could not be pruned: #{e.message}"}
        end
        batch.id if kept
      end

      def locked(name, &block)
        @locks.with_locks(name, &block)
      rescue NameMigration::LockUnavailable, Error => e
        failed(name, "workspace_locked", "can't take the workspace's startup lock: #{e.message}")
      end

      def result(rows, warnings, extra)
        status = (rows.any? { |r| r["outcome"] == "failed" }) ? JsonEnvelope.action_status(rows) : "ok"
        {results: rows, status: status, exit_code: JsonEnvelope::ACTION_EXIT_CODES.fetch(status), warnings: warnings,
         extra: extra.merge("skipped" => rows.select { |r| r["outcome"] == "skipped" }.map { |r| r["reason"] }.tally)}
      end

      def batch_row(manifest)
        {"id" => manifest["id"], "created_at" => manifest["created_at"], "reason" => manifest["reason"],
         "workspaces" => manifest["entries"].map { |entry| entry["name"] }, "templates" => manifest["sets"].map { |set| set["name"] }}
      end

      def row(name, outcome, reason, message, extra = {})
        {"workspace" => name, "outcome" => outcome, "reason" => reason, "message" => message, "code" => nil}.merge(extra)
      end

      def failed(name, code, message, extra = {})
        row(name, "failed", code, message, extra.merge("code" => code))
      end

      def puts_row(row)
        line = "#{row["template"] ? "template " + TerminalText.escape(row["template"]) : TerminalText.escape(row["workspace"])}: #{row["outcome"].tr("_", " ")}"
        line += ": #{row["reason"]}" if row["reason"]
        line += " (#{TerminalText.escape(row["message"])})" if row["message"]
        @output.puts line
      end
    end
  end
end
