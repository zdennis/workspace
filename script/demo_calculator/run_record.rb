require "digest"

module DemoCalculator
  # The record `run` writes beside a run, so `eval` can score it later.
  module RunRecord
    # Builds the record as a hash with string keys.
    #
    # @param stamp [String] the run's UTC stamp
    # @param base_sha [String] the commit the run branch started from
    # @param branch [String] the run branch
    # @param workspace_sha [String, nil] the sha of the workspace checkout that drove the run
    # @param workspace_version [String, nil] the `workspace` version
    # @param items [Array<Hash>] one `{"workflow" => id, "id" => queue item id}` per queued workflow
    # @param definitions [Hash{String => String}] each workflow id => the text of its definition file
    # @return [Hash]
    def self.build(stamp:, base_sha:, branch:, workspace_sha:, workspace_version:, items:, definitions:)
      {
        "stamp" => stamp,
        "base_sha" => base_sha,
        "branch" => branch,
        "workspace" => {"sha" => workspace_sha, "version" => workspace_version},
        "items" => items.map { |item| {"workflow" => item["workflow"], "id" => item["id"]} },
        "definitions" => definitions.to_h { |id, text| [id, Digest::SHA256.hexdigest(text)] },
        "wait" => nil
      }
    end
  end
end
