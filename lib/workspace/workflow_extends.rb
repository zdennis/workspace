require "digest"

module Workspace
  # The `extends:` half of a workflow definition: finds the parent, has it checked as a
  # definition of its own, and lays the child's file over its mapping. It works on the raw
  # YAML mappings, before {WorkflowDefinition} checks the result, so one set of checks covers
  # a definition that extends and one that doesn't.
  #
  # Two kinds of trouble are kept apart. {#failure} is a parent that can't be used (missing,
  # a cycle, a chain too long, or itself invalid): the child is then not checked at all, since
  # every other message would be noise. {#problems} are faults in the child's own `extends:`,
  # `replace:` and `steps:` against a good parent, which are listed with the rest.
  class WorkflowExtends
    # The most workflows an `extends:` chain may reach above the one being read.
    MAX_DEPTH = 4

    # @return [Array<Hash{String=>String}>] the workflows extended, nearest first: "id", "source", "path" and "sha256" (of that file's text)
    attr_reader :parents

    # @return [Array<String>] faults in the child's own `extends:`, `replace:` and `steps:`
    attr_reader :problems

    # @return [Array<String>] why the parent can't be used; empty when it can
    attr_reader :failure

    # @param id [String] the id of the definition being read
    # @param source [String] where it came from: "global", "builtin", "file" or "stdin"
    # @param lookup [#call, nil] given a workflow id and `below:` (a source name or nil), answers the parent's "text", "path" and "source", or nil
    # @param chain [Array<Array(String, String)>] the id and file of each definition from the first one read down to this one, to refuse a cycle
    def initialize(id:, source:, lookup:, chain:)
      @id = id
      @source = source
      @lookup = lookup
      @chain = chain
      @parents = []
      @problems = []
      @failure = []
    end

    # @param raw [Hash] the definition's YAML mapping
    # @return [Hash] the mapping to check: the same one when it extends nothing, else the parent's with this one laid over it.
    #   A key the child sets replaces the parent's value, except `inputs`, which merge by name. `replace:` swaps whole steps in
    #   place; `steps:` adds new ones, each after the step its `after:` names, else at the end.
    def resolve(raw)
      raw = raw.dup
      own = raw.delete("extends")
      replacements = raw.delete("replace")
      if own.nil?
        @problems << "replace only means something with extends:" unless replacements.nil?
        return raw
      end
      unless own.is_a?(String) && WorkflowDefinition::ID_PATTERN.match?(own)
        @failure << "extends must be the id of a workflow (#{WorkflowDefinition::ID_RULE}), got #{own.inspect[0, 60]}"
        return raw
      end
      parent = parent_of(own)
      return raw unless parent
      definition, found = parent
      @parents = [{"id" => own, "source" => found["source"], "path" => found["path"], "sha256" => Digest::SHA256.hexdigest(found["text"].to_s)}] + definition.parents
      base = anchor_prompt_files(definition.resolved_raw, found["path"])
      merged = base.except("id", "schema_version").merge(raw.except("steps"))
      merged["inputs"] = merge_inputs(base["inputs"], raw["inputs"]) if raw.key?("inputs")
      merged["steps"] = merged_steps("#{own} (#{found["path"]})", base["steps"], replacements, raw["steps"])
      merged
    end

    private

    # The parent as a definition read and checked on its own, with the file it came from; nil, with {#failure} set, when it can't be used.
    def parent_of(parent_id)
      if @chain.size > MAX_DEPTH
        @failure << "extends goes more than #{MAX_DEPTH} workflows up (#{(@chain.map(&:first) + [parent_id]).join(" -> ")})"
        return nil
      end
      unless @lookup
        @failure << "extends #{parent_id}: this definition can't be checked here, where no workflows are known"
        return nil
      end
      found = @lookup.call(parent_id, below: (parent_id == @id) ? @source : nil)
      unless found
        @failure << ((parent_id == @id) ? "extends #{parent_id}: no other workflow has that id, so there is nothing for it to extend" : "extends #{parent_id}: no workflow has that id")
        return nil
      end
      key = found["path"] || parent_id
      if @chain.any? { |_, each| each == key }
        @failure << "extends makes a cycle: #{(@chain.map(&:first) + [parent_id]).join(" -> ")}"
        return nil
      end
      begin
        [WorkflowDefinition.parse(found["text"].to_s, id: parent_id, source: found["source"], path: found["path"],
          parent_lookup: @lookup, chain: @chain + [[parent_id, key]]), found]
      rescue Workspace::Error => e
        @failure.concat((e.details["problems"] || [e.message]).map { |problem| "extends #{parent_id} (#{found["path"]}): #{problem}" })
        nil
      end
    end

    # The inputs of both, the child's winning by name. A child value that is not a mapping is kept as written, so it is reported.
    def merge_inputs(parent, child)
      return parent if child.nil?
      return child if !child.is_a?(Hash) || !(parent.nil? || parent.is_a?(Hash))
      (parent || {}).merge(child)
    end

    # A parent's relative `prompt_file:` names a file beside the parent, not beside the child.
    def anchor_prompt_files(raw, parent_path)
      steps = raw["steps"]
      return raw unless parent_path && steps.is_a?(Hash)
      anchored = steps.transform_values do |step|
        (step.is_a?(Hash) && step["prompt_file"].is_a?(String)) ? step.merge("prompt_file" => File.expand_path(step["prompt_file"], File.dirname(parent_path))) : step
      end
      raw.merge("steps" => anchored)
    end

    def merged_steps(parent_id, parent_steps, replacements, added)
      list = parent_steps.map { |step_id, step| [step_id.to_s, step] }
      unless replacements.nil? || replacements.is_a?(Hash)
        @problems << "replace must be a mapping of step id to the whole new step, got #{replacements.inspect[0, 60]}"
        replacements = nil
      end
      (replacements || {}).each do |step_id, step|
        index = list.index { |each, _| each == step_id.to_s }
        if index.nil?
          @problems << "replace names step #{step_id.to_s.inspect}, which #{parent_id} doesn't have (its steps: #{list.map(&:first).join(", ")})"
        elsif step.is_a?(Hash) && step.key?("after")
          @problems << "replace step #{step_id}: after: is for added steps; a replaced step keeps its place"
        else
          list[index] = [step_id.to_s, step]
        end
      end
      return list.to_h if added.nil?
      unless added.is_a?(Hash)
        @problems << "steps must be a mapping of step id to step"
        return list.to_h
      end
      anchors = {}
      added.each do |step_id, step|
        step_id = step_id.to_s
        if list.any? { |each, _| each == step_id }
          @problems << "step #{step_id} is already a step of #{parent_id}: put it under replace: to change it"
          next
        end
        after = step.is_a?(Hash) ? step["after"] : nil
        step = step.except("after") if step.is_a?(Hash)
        anchor = anchors[after] || after
        index = anchor.nil? ? list.size - 1 : list.index { |each, _| each == anchor.to_s }
        if index.nil?
          @problems << "step #{step_id}: after names step #{after.inspect[0, 40]}, which the steps so far don't have (#{list.map(&:first).join(", ")})"
          index = list.size - 1
        end
        list.insert(index + 1, [step_id, step])
        anchors[after] = step_id
      end
      list.to_h
    end
  end
end
