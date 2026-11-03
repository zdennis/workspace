require "fileutils"
require "json"
require "shellwords"

module Workspace
  # The record of a `workspace rename` under way, one file per old workspace name, written before the
  # first git step and deleted after the last step. A re-run reads the names and the notes decision
  # from it rather than working them out again, since by then the rename's own steps have changed what
  # they are worked out from.
  class RenameJournal
    # @param config [Workspace::Config]
    # @param clock [#now]
    def initialize(config:, clock: Time)
      @config = config
      @clock = clock
    end

    # The journal of a workspace, by its old name or, since the checkout answers to the new name once
    # the config has moved, by the name it is getting.
    #
    # @param workspace [String]
    # @return [Hash, nil]
    # @raise [Workspace::Error] `rename_in_progress` when the workspace's own journal can't be read
    def read(workspace)
      path = @config.rename_journal_path(workspace) if File.basename(workspace) == workspace
      return parse(path) if path && File.file?(path)
      others.find { |journal| journal["new_workspace"] == workspace }
    end

    # @param plan [Workspace::RenamePlan::Plan]
    # @return [void]
    # @raise [SystemCallError] if the file can't be written
    def write(plan)
      path = @config.rename_journal_path(plan.workspace)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate(document(plan)), perm: 0o600)
      File.rename(temp, path)
    ensure
      File.delete(temp) if temp && File.exist?(temp)
    end

    # @param workspace [String] the old name
    # @return [void]
    # @raise [SystemCallError] if the file can't be removed
    def delete(workspace)
      path = @config.rename_journal_path(workspace)
      File.delete(path) if File.exist?(path)
    end

    private

    def document(plan)
      {"workspace" => plan.workspace, "new_workspace" => plan.new_workspace, "branch" => plan.branch, "new_branch" => plan.new_branch,
       "path" => plan.path, "new_path" => plan.new_path, "session" => plan.session, "new_session" => plan.new_session,
       "notes" => plan.notes.to_h.merge("problem" => plan.notes.problem), "started_at" => @clock.now.utc.iso8601}
    end

    def parse(path)
      parsed = JSON.parse(File.read(path))
      raise JSON::ParserError, "not an object" unless parsed.is_a?(Hash)
      parsed
    rescue JSON::ParserError, SystemCallError => e
      raise Workspace::Error.new("The rename journal #{path} can't be read (#{e.message}). A rename was started there; check the workspace, then delete the file.",
        code: "rename_in_progress", details: {"path" => path, "rerun" => false, "fix" => "rm #{Shellwords.escape(path)}"})
    end

    def others
      dir = @config.rename_journal_dir
      return [] unless Dir.exist?(dir)
      Dir.children(dir).select { |entry| entry.end_with?(".json") }.sort.filter_map do |entry|
        parse(File.join(dir, entry))
      rescue Workspace::Error
        nil
      end
    end
  end
end
