require "pathname"

module Workspace
  # The checkout contention check of a definition's `fan_out` groups. Siblings of one group share the run's checkout,
  # so under `checkout: shared` (the default) each must leave it alone (`guard: unchanged`, which is also what a step
  # with no `guard:` gets) and no two may name the same `produces` file. Under `checkout: shared-edit` the guard
  # requirement drops and a warning says the engine can't tell whether the siblings edit disjoint paths.
  #
  # Reads only built steps and the definition's `groups`; a definition with no groups is never touched. Every problem
  # goes to the `report` callable, so {WorkflowDefinition} collects them with its own, as {WorkflowReviewSpec} does.
  class WorkflowFanOutSpec
    # @param report [#call] given a problem message
    def initialize(report:)
      @report = report
    end

    # Reports each `checkout: shared` group whose siblings could collide: one with a `guard: config` sibling, and each
    # `produces` file two siblings name. A `shared-edit` group is the author's promise and is never refused. The result does not depend on the order of the siblings.
    #
    # @param steps [Array<Hash>] the built, flattened steps
    # @param groups [Hash{String=>Hash}] group id to its "checkout" and sibling ids
    # @return [void]
    def check(steps, groups)
      by_id = steps.to_h { |step| [step["id"], step] }
      groups.each do |group_id, group|
        next unless group["checkout"] == "shared"
        siblings = group["steps"].filter_map { |id| by_id[id] }
        siblings.each do |step|
          next unless step["guard"] == "config"
          problem "step #{step["id"]} (in fan_out group #{group_id}): guard: config lets it edit the checkout, which siblings of a checkout: shared group share; use guard: unchanged, or set checkout: shared-edit on #{group_id}"
        end
        collisions(siblings).each do |file, ids|
          problem "fan_out group #{group_id}: steps #{ids.join(" and ")} both produce #{file.inspect}; siblings of a fan_out group need separate produces files"
        end
      end
    end

    # The warnings for `checkout: shared-edit` groups.
    #
    # @param groups [Hash{String=>Hash}, nil] the definition's `groups`
    # @return [Array<Hash{String=>String}>] each with "code" (`fan_out_edits_unverified`), "step" (the group id) and "message"
    def self.warnings(groups)
      (groups || {}).filter_map do |group_id, group|
        next unless group["checkout"] == "shared-edit"
        {"code" => "fan_out_edits_unverified", "step" => group_id,
         "message" => "fan_out group #{group_id} sets checkout: shared-edit, so its siblings may edit the checkout and the engine can't verify that they edit disjoint paths. The checks of the step after the group are the safety net; give each sibling its own paths in its prompt."}
      end
    end

    private

    # Each file two or more of the siblings produce, with the ids that produce it, in the order first met.
    def collisions(siblings)
      owners = Hash.new { |hash, file| hash[file] = [] }
      siblings.each do |step|
        step["produces"].map { |file| Pathname.new(file).cleanpath.to_s }.uniq.each { |file| owners[file] << step["id"] }
      end
      owners.select { |_file, ids| ids.size > 1 }
    end

    def problem(message)
      @report.call(message)
      nil
    end
  end
end
