require "json"
require "fileutils"

module Workspace
  # Tracks in-flight pipeline state per work item, optionally persisting it so an
  # agent that is restarted can pick up work its panes are still running.
  class PipelineState
    # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration
    # @param state_path [String, nil] file to persist entries to, or nil to stay in memory
    def initialize(pipeline_config:, state_path: nil)
      @pipeline_config = pipeline_config
      @state_path = state_path
      @entries = {}
      load_from_disk if @state_path && File.exist?(@state_path)
    end

    # Starts tracking a work item at the first stage of its workspace's pipeline.
    #
    # @param work_item_ref [String] the coordinator's work item reference
    # @param workspace_name [String] workspace the item belongs to
    # @param dispatch_id [String] the coordinator's dispatch identifier
    # @return [Hash] the new state entry
    def start(work_item_ref:, workspace_name:, dispatch_id:)
      stage = @pipeline_config.stages_for(workspace_name)&.first
      entry = @entries[work_item_ref] = {
        work_item_ref: work_item_ref,
        workspace_name: workspace_name,
        dispatch_id: dispatch_id,
        pane_index: stage ? stage[:pane_index] : 0,
        phase: stage && stage[:role]
      }
      persist
      entry
    end

    # @param work_item_ref [String]
    # @return [Hash, nil] the current state entry, or nil when untracked
    def current(work_item_ref)
      @entries[work_item_ref]
    end

    # Moves a tracked work item onto a later pipeline stage.
    #
    # @param work_item_ref [String]
    # @param to_stage [Hash] the stage hash to move to, with :pane_index and :role
    # @return [Hash, nil] the updated entry, or nil when untracked
    def advance(work_item_ref:, to_stage:)
      entry = @entries[work_item_ref]
      return nil unless entry
      entry[:pane_index] = to_stage[:pane_index]
      entry[:phase] = to_stage[:role]
      persist
      entry
    end

    # Stops tracking a work item.
    #
    # @param work_item_ref [String]
    # @return [Hash, nil] the removed entry, or nil when untracked
    def complete(work_item_ref:)
      removed = @entries.delete(work_item_ref)
      persist if removed
      removed
    end

    # @return [Array<String>] every tracked work item reference
    def in_flight_refs
      @entries.keys
    end

    # @return [Array<Hash>] in-flight entries in the shape the register message expects
    def in_flight
      @entries.values.map do |entry|
        {
          "work_item_ref" => entry[:work_item_ref],
          "dispatch_id" => entry[:dispatch_id],
          "phase" => entry[:phase]
        }
      end
    end

    private

    # Written under the user's own state directory, so the file carries no
    # permissions a passer-by on a shared box could use. Written to a temp file
    # and renamed, because being killed mid-write is exactly the case this file
    # exists for and a half-written one would lose every in-flight item.
    def persist
      return unless @state_path
      FileUtils.mkdir_p(File.dirname(@state_path), mode: 0o700)
      temp_path = "#{@state_path}.#{Process.pid}.tmp"
      File.write(temp_path, JSON.pretty_generate(@entries), perm: 0o600)
      File.rename(temp_path, @state_path)
    end

    # A state file we cannot make sense of is worse than none: starting from
    # empty lets the coordinator's reconciliation decide what is still in
    # flight, where raising here would stop the agent from starting at all.
    def load_from_disk
      data = JSON.parse(File.read(@state_path))
      return unless data.is_a?(Hash)
      @entries = data.each_with_object({}) do |(ref, entry), entries|
        entries[ref] = entry.transform_keys(&:to_sym) if entry.is_a?(Hash)
      end
    rescue JSON::ParserError, SystemCallError
      @entries = {}
    end
  end
end
