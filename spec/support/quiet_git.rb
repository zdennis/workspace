require "open3"

# Keeps git's background maintenance out of a fixture repository. Git starts
# detached maintenance after commit, fetch, rebase and push; it writes
# `objects/maintenance.lock` while mktmpdir deletes the tree, and the cleanup
# raises ENOENT. The setting lives in the repository's own config, so the
# specs' git calls and the ones the code under test makes both see it, with
# no change to the process environment.
module QuietGit
  SETTINGS = {"gc.auto" => "0", "maintenance.auto" => "false", "gc.autoDetach" => "false"}.freeze

  def self.configure(*repos)
    repos.each do |repo|
      SETTINGS.each do |key, value|
        out, status = Open3.capture2e("git", "-C", repo, "config", key, value)
        raise "git config #{key} in #{repo}: #{out}" unless status.success?
      end
    end
  end
end
