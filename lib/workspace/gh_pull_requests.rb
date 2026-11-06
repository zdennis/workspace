require "open3"
require "json"

module Workspace
  # Asks the `gh` CLI about pull requests for `prune`: whether `gh` is
  # authenticated, and the state of the pull request for a branch.
  class GhPullRequests
    # @param runner [#call] called with a command's arguments, answers
    #   `[stdout, stderr, status]` as `Open3.capture3` does; specs inject a fake so nothing spawns
    def initialize(runner: ->(*argv) { Open3.capture3(*argv) })
      @runner = runner
    end

    # Checks whether the `gh` CLI is authenticated and available.
    #
    # @return [Boolean] true if `gh auth status` succeeds
    def usable?
      _, _, status = @runner.call("gh", "auth", "status")
      status.success?
    end

    # Looks up the PR for a branch in a given repo directory.
    #
    # @param branch [String] the branch name
    # @param repo_path [String] path to the worktree directory
    # @return [Hash, nil] hash with :number, :url, :state keys, or nil on failure
    def status_for(branch, repo_path)
      remote_url, _, status = @runner.call("git", "-C", repo_path, "remote", "get-url", "origin")
      return nil unless status.success?

      slug = github_repo_slug(remote_url.strip)
      return nil unless slug

      stdout, _, gh_status = @runner.call(
        "gh", "pr", "view", branch,
        "--repo", slug,
        "--json", "number,url,state"
      )
      return nil unless gh_status.success?

      data = JSON.parse(stdout)
      {number: data["number"], url: data["url"], state: data["state"]}
    rescue JSON::ParserError
      nil
    end

    private

    def github_repo_slug(remote_url)
      m = remote_url.match(%r{github\.com[:/](.+?)(?:\.git)?\z})
      m ? m[1] : nil
    end
  end
end
