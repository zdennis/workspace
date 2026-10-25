module Workspace
  # Where a branch's commits have got to, from local git only (no fetch, no `gh`): pushed to
  # its upstream, and on the default branch by {Workspace::Git#branch_vs_base}'s one rule. It
  # reads and writes nothing.
  class DeliveryFacts
    # @param git [Workspace::Git]
    def initialize(git:)
      @git = git
    end

    # @param path [String, nil] the checkout
    # @param branch [String, nil] its branch
    # @return [Hash, nil] `base`, `branch`, `remote` (an origin exists), `upstream`, `upstream_gone`
    #   (an upstream is configured but its branch is missing), `pushed` (nil with no remote),
    #   `ahead_of_upstream`, `merged`, `ahead_of_base`; nil when git cannot answer or the branch does not exist
    def read(path, branch)
      return nil if path.to_s.empty? || branch.to_s.empty? || !File.directory?(path)
      against = @git.branch_vs_base(path, branch)
      return nil unless against
      config = @git.upstream_config(path, branch)
      upstream = config && upstream_name(config)
      gone = !config.nil? && !@git.commit_exists?(path, upstream_ref(config))
      unpushed = (config && !gone) ? @git.commits_unpushed(path, branch) : nil
      remote = !@git.remote_url(path).nil?
      {"base" => against["base"], "branch" => branch, "remote" => remote, "upstream" => upstream, "upstream_gone" => gone,
       "pushed" => remote ? (!unpushed.nil? && unpushed.zero?) : nil,
       "ahead_of_upstream" => unpushed, "merged" => against["merged"], "ahead_of_base" => against["ahead"]}
    rescue Workspace::Error, SystemCallError
      nil
    end

    private

    def upstream_name(config)
      branch = config[1].delete_prefix("refs/heads/")
      (config[0] == ".") ? branch : "#{config[0]}/#{branch}"
    end

    def upstream_ref(config)
      (config[0] == ".") ? config[1] : "refs/remotes/#{upstream_name(config)}"
    end
  end
end
