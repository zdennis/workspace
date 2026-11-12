require "digest"

module Workspace
  # `template apply`: re-renders existing tmuxinator configs from their render records with the tmuxinator
  # template each one selects today and the current agent settings, after a copy of each into one backup batch.
  #
  # Each workspace is done in turn inside its startup lock ({NameMigration#with_locks}, which waits; a dry run takes none), and
  # everything its row decides is read inside it: whether the config is still there, the file, the record and
  # where it stands ({TemplateStatus#assess}). The names come in as a list only, so a workspace renamed or
  # removed while apply waited is `skipped: gone` and nothing is written under its old name.
  #
  # Row outcomes: `unchanged`, `applied` (`running` says its tmux session is up, so a relaunch takes it;
  # `record_only` that only the render record was rewritten, for another set that renders the same text),
  # `would_apply` in its place under a dry run, `skipped` (`modified`, `approx` (a record `template adopt` made without an exact render) or untracked records, `gone`, or
  # `not_reached` after a roll back) and `failed` (`reason` is the error code, `workspace_locked` for a lock
  # that can't be taken); with a roll back, rows already written become `rolled_back`. A failed row does not
  # stop the others unless +rollback+ is asked for.
  class TemplateApply
    # @!attribute rows [Array<Hash>] one per workspace, in order (see the class description)
    # @!attribute backup [String, nil] the batch id kept; nil for a dry run or when nothing was written
    # @!attribute rolled_back [Boolean] whether the batch was put back after a failed row
    # @!attribute warnings [Array<Hash>] `{code, message}` (and `workspace`, `kind`, `path` for a file a roll back
    #   left): `rollback_left_file`, `rollback_failed`, `rollback_unreadable`, `prune_failed`
    Result = Data.define(:rows, :backup, :rolled_back, :warnings)

    # @param status [Workspace::TemplateStatus] where each config stands and what a render writes today
    # @param writer [Workspace::TmuxinatorConfigWriter] writes a config and its render record
    # @param backups [Workspace::TmuxinatorBackupStore] the batch each write is copied into first
    # @param locks [Workspace::NameMigration] each workspace's startup lock
    # @param project_config [Workspace::ProjectConfig] finds a config and its agent pane text
    # @param tmux [Workspace::Tmux] whether a workspace's session is running
    # @param differ [#call] `(old, new, old_label:, new_label:)` to a unified diff (a {TextDiff})
    # @param retention [Workspace::TmuxinatorBackupConfig] `keep` and `max_age` for the prune after a batch
    def initialize(status:, writer:, backups:, locks:, project_config:, tmux:, differ:, retention:)
      @status = status
      @writer = writer
      @backups = backups
      @locks = locks
      @project_config = project_config
      @tmux = tmux
      @differ = differ
      @retention = retention
      @files = TemplateBatchFiles.new(backups: backups, writer: writer)
    end

    # @param names [Array<String>] the workspaces, in order
    # @param dry_run [Boolean] decide every row but write nothing, and take no batch
    # @param diff [Boolean] add each row's `diff`: the config against what a render writes today
    # @param force [Boolean] overwrite a config edited since it was rendered
    # @param rollback [Boolean] on the first failed row, put back every file the batch wrote and stop
    # @return [Result]
    # @raise [Workspace::Error] when the backup batch can't be made; nothing is written then
    def call(names, dry_run: false, diff: false, force: false, rollback: false)
      batch = dry_run ? nil : open_batch
      rows = []
      warnings = []
      rolled_back = false
      names.each_with_index do |name, index|
        rows << locked(name, dry_run) { one(name, batch, dry_run: dry_run, diff: diff, force: force) }
        next unless rollback && batch && rows.last["outcome"] == "failed"

        kept = roll_back(batch, warnings)
        rows.each { |row| row.merge!("outcome" => "rolled_back", "message" => "put back by --rollback-all-on-error") if row["outcome"] == "applied" && !kept.include?(row["workspace"]) }
        names.drop(index + 1).each { |rest| rows << row(rest, "skipped", "not_reached", "not reached: the batch was rolled back") }
        rolled_back = true
        break
      end
      Result.new(rows: rows, backup: batch && close_batch(batch, warnings), rolled_back: rolled_back, warnings: warnings)
    end

    private

    def open_batch
      @backups.open(reason: "apply")
    rescue SystemCallError => e
      raise Error, "Can't make a tmuxinator backup batch, so nothing was applied: #{e.message}"
    end

    # A dry run writes nothing, so it takes no lock (and makes no lock file).
    def locked(name, dry_run, &block)
      return yield if dry_run
      @locks.with_locks(name, &block)
    rescue NameMigration::LockUnavailable, Error => e
      # `one` answers its own errors as rows, so an Error here came from building the lock's path.
      failed(name, "workspace_locked", "can't take the workspace's startup lock: #{e.message}")
    end

    # One workspace's row, read and written inside its lock.
    def one(name, batch, dry_run:, diff:, force:)
      return row(name, "skipped", "gone", "its tmuxinator config is gone (renamed or removed while apply waited)") unless @project_config.exists?(name)

      found = @status.assess(name)
      state = found.row.state
      base = {"state" => state, "template" => found.row.selected}
      if state == "untracked"
        return row(name, "skipped", "untracked", "no render record to render it from; run: workspace template adopt #{name}", base)
      end
      if state == "modified" && !force
        return with_diff(approx_row(name, base), found, diff) if found.record.approx
        return with_diff(row(name, "skipped", "modified", "edited since it was rendered; --force overwrites it (after a backup)", base.merge("code" => "template_modified")), found, diff)
      end
      unless found.rendered
        return failed(name, found.error&.code || "error", found.error&.message || "its tmuxinator template can't be read", base)
      end
      return with_diff(row(name, "unchanged", nil, nil, base), found, diff) if state == "current"

      record_only = found.text == found.rendered
      write(name, batch, found, record_only) unless dry_run
      running = !record_only && running?(name)
      message = if record_only then "already up to date; only its render record was updated"
      elsif running then "running: relaunch to take effect"
      end
      with_diff(row(name, dry_run ? "would_apply" : "applied", nil, message, base.merge("running" => running, "record_only" => record_only)), found, diff)
    rescue Error => e
      failed(name, e.code, e.message, base || {})
    rescue SystemCallError, IOError => e
      failed(name, "error", e.message, base || {})
    end

    # A config that already holds the render keeps its bytes (and mtime): only the record is rewritten.
    def write(name, batch, found, record_only)
      @backups.add(batch, name: name, path: @project_config.config_path_for(name))
      inputs = found.inputs.merge(agent_command: @project_config.agent_pane_text(found.rendered, name))
      fields = {kind: found.record.kind, template: found.row.selected, template_sha: found.template_sha, inputs: inputs}
      record_only ? @writer.write_record_for(name, found.rendered, **fields) : @writer.write(name, found.rendered, **fields)
      @backups.finish(batch, name: name, sha_after: sha(found.rendered), record_sha_after: file_sha(@writer.record_path(name)))
    end

    def row(name, outcome, reason, message, extra = {})
      {"workspace" => name, "outcome" => outcome, "reason" => reason, "message" => message, "state" => nil, "template" => nil,
       "running" => false, "record_only" => false, "code" => nil}.merge(extra)
    end

    # A record `template adopt` could not make exact: no render ever wrote this file.
    def approx_row(name, base)
      row(name, "skipped", "approx", "adopted without an exact render, so it may hold edits; --force overwrites it (after a backup)", base.merge("code" => "template_approx"))
    end

    def failed(name, code, message, extra = {})
      row(name, "failed", code, message, extra.merge("code" => code))
    end

    def with_diff(row, found, diff)
      return row unless diff
      path = @project_config.config_path_for(row["workspace"])
      text = (found.rendered && found.text != found.rendered) ? @differ.call(found.text, found.rendered, old_label: path, new_label: "rendered") : nil
      row.merge("diff" => text)
    end

    def running?(name)
      @tmux.session_exists?(@tmux.session_name_for(name), project: name)
    rescue Error, SystemCallError
      false
    end

    # Puts back every file the batch wrote, each under its workspace's lock, deleting the ones it created. A
    # file changed since the batch wrote it, or gone, is left as it is. Answers the names it could not put back.
    def roll_back(batch, warnings)
      manifest = @backups.find(batch.id)
      manifest["entries"].reject do |entry|
        @locks.with_locks(entry["name"]) do
          put_back(manifest, entry, :config, entry["path"], entry["sha_before"], entry.fetch("sha_after", :unknown), warnings) &
            put_back(manifest, entry, :record, entry["record_path"], entry["record_sha_before"], entry.fetch("record_sha_after", :unknown), warnings)
        end
      rescue NameMigration::LockUnavailable, SystemCallError, IOError, Error => e
        warnings << {"code" => "rollback_failed", "workspace" => entry["name"], "message" => "#{entry["name"]}: could not be put back: #{e.message}"}
        false
      end.map { |entry| entry["name"] }
    rescue Error => e
      warnings << {"code" => "rollback_unreadable", "message" => "The batch could not be read to put it back: #{e.message}"}
      []
    end

    # Whether the file is as it was before the batch when this returns.
    def put_back(manifest, entry, kind, path, before, after, warnings)
      now = file_sha(path)
      return true if now == before
      if after != :unknown && now != after
        what = (kind == :record) ? "its render record" : "its tmuxinator config"
        warnings << {"code" => "rollback_left_file", "workspace" => entry["name"], "kind" => kind.to_s, "path" => path,
                     "message" => "#{entry["name"]}: #{what} #{path} changed after apply wrote it, so it was left as it is#{" (only the render record; the config was put back)" if kind == :record && warnings.none? { |w| w["workspace"] == entry["name"] && w["kind"] == "config" }}"}
        return false
      end
      @files.put(manifest, entry, kind)
      true
    end

    def close_batch(batch, warnings)
      kept = !@backups.discard_if_empty(batch)
      begin
        @backups.prune(keep: @retention.keep, max_age: @retention.max_age)
      rescue SystemCallError => e
        warnings << {"code" => "prune_failed", "message" => "Old tmuxinator backups could not be pruned: #{e.message}"}
      end
      batch.id if kept
    end

    def sha(text)
      Digest::SHA256.hexdigest(text)
    end

    def file_sha(path)
      @files.sha(path)
    end
  end
end
