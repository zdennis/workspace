module Workspace
  # Tracks in-flight pipeline state per work item.
  class PipelineState
    # @param pipeline_config [Workspace::PipelineConfig] per-project pipeline configuration
    def initialize(pipeline_config:)
      @pipeline_config = pipeline_config
      @entries = {}
    end

    # Starts tracking a work item at the first stage of its workspace's pipeline.
    #
    # @param work_item_ref [String] the coordinator's work item reference
    # @param workspace_name [String] workspace the item belongs to
    # @param dispatch_id [String] the coordinator's dispatch identifier
    # @return [Hash] the new state entry
    def start(work_item_ref:, workspace_name:, dispatch_id:)
      stage = @pipeline_config.stages_for(workspace_name)&.first
      @entries[work_item_ref] = {
        work_item_ref: work_item_ref,
        workspace_name: workspace_name,
        dispatch_id: dispatch_id,
        pane_index: stage ? stage[:pane_index] : 0,
        phase: stage && stage[:role],
        message_id_counter: 0,
        sequence: 0
      }
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
      entry
    end

    # Stops tracking a work item.
    #
    # @param work_item_ref [String]
    # @return [Hash, nil] the removed entry, or nil when untracked
    def complete(work_item_ref:)
      @entries.delete(work_item_ref)
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
  end
end
