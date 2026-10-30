require "json"

module Workspace
  module Commands
    # `push`: pushes a workspace's branch to origin. A branch with no upstream is
    # pushed with `-u`. A branch whose upstream has commits it lacks is pushed
    # with a lease on the upstream commit it compared, only when its own history
    # once held every one of those commits (a rebase replaced them); otherwise
    # the push is refused. A `pr-N` branch made by `gh pr checkout` whose upstream
    # is `origin/<head>` is pushed to `<head>` once `gh` confirms that pull request
    # is open, its head is that branch of origin's own repository, and its head
    # commit is the one fetched.
    class Push
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The local branch `start` makes for a pull request.
      PR_BRANCH = /\Apr-(\d+)\z/

      # `pr_check` values a person can fix or that may pass on a second try; the rest are `permanent`.
      FIXABLE_PR_CHECKS = %w[gh_missing not_logged_in gh_failed].freeze

      # @param git [Workspace::Git]
      # @param checkout [Workspace::WorkspaceCheckout]
      # @param pr_status [Workspace::PullRequestStatus] reads a pull request's head for a `pr-N` branch
      # @param output [IO]
      def initialize(git:, checkout:, pr_status:, output: $stdout)
        @git = git
        @checkout = checkout
        @pr_status = pr_status
        @output = output
      end

      # @param name [String, nil] the workspace; nil means the one the working directory is in
      # @param json [Boolean] print the document documented in docs/README.rebase.md
      # @param working_dir [String]
      # @return [void]
      # @raise [Workspace::Error] `not_in_workspace`, `unknown_workspace`, `fetch_failed`, `push_rejected`
      #   (`details.pr_check` when a `pr-N` branch's pull request did not check out),
      #   a {PushFailure} code (`no_remote`, `push_auth_failed`, `protected_branch`, `push_network`, `push_timeout`, `push_failed`),
      #   or an uncoded error for a detached HEAD or git not answering
      def call(name: nil, json: false, working_dir: Dir.pwd)
        target = @checkout.resolve(name, working_dir: working_dir)
        branch = target["branch"]
        outcome, forced, remote_branch = push_branch(target["path"], branch)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => target["workspace"],
            "branch" => branch, "remote_branch" => remote_branch, "outcome" => outcome, "forced" => forced})
        else
          @output.puts message(outcome, forced, branch, remote_branch)
        end
      end

      private

      def push_branch(path, branch)
        upstream = @git.upstream_branch(path)
        unless upstream
          push!(path, branch, set_upstream: true)
          return ["pushed", false, branch]
        end

        dest = branch
        head_sha = nil
        unless upstream == "origin/#{branch}"
          dest = pr_head_branch(path, branch, upstream)
          unless dest
            raise rejected(branch, upstream, "its upstream is #{upstream}; push only handles origin/#{branch}.", "upstream_mismatch")
          end
          head_sha = verified_head(path, branch, upstream, dest)
        end

        fetch!(path)
        compared = @git.rev_parse(path, "refs/remotes/#{upstream}")
        raise Workspace::Error, "git could not compare '#{branch}' with #{upstream}." if compared.nil?
        if head_sha && compared != head_sha
          raise pr_rejected(branch, upstream, "sha_mismatch",
            "#{upstream} is at #{compared[0, 12]} but pull request ##{pr_number(branch)}'s head is #{head_sha[0, 12]}.")
        end
        behind, ahead = @git.behind_ahead(path, compared)
        raise Workspace::Error, "git could not compare '#{branch}' with #{upstream}." if behind.nil?
        return ["up_to_date", false, dest] if behind == 0 && ahead == 0
        if behind == 0
          push!(path, branch, dest: dest)
          return ["pushed", false, dest]
        end

        if ahead == 0
          raise rejected(branch, upstream, "the branch is #{behind} commit(s) behind #{upstream}; pushing would delete them.", "would_delete_commits")
        end
        unless @git.upstream_commits_replaced?(path, branch, compared)
          raise rejected(branch, upstream, "#{upstream} has #{behind} commit(s) this branch never had; push was not forced.", "upstream_has_other_commits")
        end
        push!(path, branch, dest: dest, lease: compared)
        ["pushed", true, dest]
      end

      # The branch on origin a `pr-N` branch tracks, when it tracks one under another name; nil otherwise.
      def pr_head_branch(path, branch, upstream)
        return nil unless branch.match?(PR_BRANCH)
        remote, merge = @git.upstream_config(path, branch)
        return nil unless remote == "origin" && merge.to_s.start_with?("refs/heads/")
        head = merge.delete_prefix("refs/heads/")
        (head != branch && upstream == "origin/#{head}") ? head : nil
      end

      # Checks the pull request with gh and returns its head commit; raises when any check fails.
      def verified_head(path, branch, upstream, head)
        refuse = ->(check, detail, **extra) { raise pr_rejected(branch, upstream, check, detail, **extra) }
        if head == @git.default_branch_name(path)
          refuse.call("default_branch", "#{upstream} is the default branch; push never sends a pull request checkout there.")
        end
        repo = origin_repo(path)
        refuse.call("repo_mismatch", "origin's URLs do not all name one GitHub repository.") unless repo

        number = pr_number(branch)
        facts = @pr_status.head(path, number: number, repo: repo.join("/"))
        unless facts["available"]
          case facts["reason"]
          when "gh_missing" then refuse.call("gh_missing", "gh is not installed, so pull request ##{number} could not be checked.")
          when "not_logged_in" then refuse.call("not_logged_in", facts["detail"])
          when "timeout" then refuse.call("gh_failed", "gh did not answer in time.", timed_out: true)
          else refuse.call("gh_failed", facts["detail"])
          end
        end
        refuse.call("pr_closed", "pull request ##{number} is #{facts["state"].to_s.downcase}.") unless facts["state"] == "OPEN"
        refuse.call("cross_repository", "pull request ##{number} comes from a fork.") unless facts["cross_repository"] == false
        unless facts["head_ref"] == head
          refuse.call("head_mismatch", "pull request ##{number}'s head branch is #{facts["head_ref"].inspect}, not #{head}.")
        end
        unless same_name?(facts["head_owner"], repo[1]) && same_name?(facts["head_name"], repo[2])
          refuse.call("repo_mismatch", "pull request ##{number}'s head repository is not origin (#{repo[1]}/#{repo[2]}).")
        end
        sha = facts["head_sha"].to_s
        refuse.call("gh_failed", "gh gave no usable head commit for pull request ##{number}.") unless sha.match?(/\A\h{40}(\h{24})?\z/)
        sha
      end

      # Host, owner and name of origin, when its fetch URL and every push URL name the same repository.
      def origin_repo(path)
        repo = PullRequestStatus.github_repo(@git.remote_url(path))
        push_urls = @git.push_urls(path)
        return nil unless repo && push_urls && !push_urls.empty?
        same = push_urls.all? do |url|
          other = PullRequestStatus.github_repo(url)
          other&.zip(repo)&.all? { |a, b| same_name?(a, b) }
        end
        same ? repo : nil
      end

      def same_name?(a, b)
        a.is_a?(String) && b.is_a?(String) && a.casecmp?(b)
      end

      def pr_number(branch)
        Integer(PR_BRANCH.match(branch)[1], 10)
      end

      def fetch!(path)
        fetched, stderr = @git.fetch(path)
        return if fetched
        raise Workspace::Error.new("Could not fetch from origin: #{first_line(stderr)}",
          code: "fetch_failed", details: {"remote" => "origin", "detail" => first_line(stderr)})
      end

      def push!(path, branch, set_upstream: false, dest: nil, lease: nil)
        success, stderr = @git.push(path, branch, set_upstream: set_upstream, dest: (dest unless dest == branch), lease: lease)
        return true if success
        raise PushFailure.error(branch, stderr)
      end

      def rejected(branch, upstream, detail, reason, extra = {}, permanent: true, retry_with: nil)
        Workspace::Error.new("Push of '#{branch}' was rejected: #{detail}", code: "push_rejected", retry_with: retry_with,
          details: {"branch" => branch, "upstream" => upstream, "detail" => detail, "reason" => reason, "permanent" => permanent, **extra})
      end

      # `gh_failed` carries `timed_out`; a timeout alone gets a retry hint.
      def pr_rejected(branch, upstream, check, detail, timed_out: false)
        extra = {"pr_check" => check}
        extra["timed_out"] = timed_out if check == "gh_failed"
        rejected(branch, upstream, detail.to_s, "upstream_mismatch", extra, permanent: !FIXABLE_PR_CHECKS.include?(check),
          retry_with: timed_out ? PushFailure::RETRY : nil)
      end

      def message(outcome, forced, branch, remote_branch)
        return "#{branch} is already up to date on its upstream." if outcome == "up_to_date"

        if remote_branch != branch
          where = "origin/#{remote_branch} (pull request ##{pr_number(branch)})"
          return forced ? "Force-pushed #{branch} to #{where} (with lease) after a rebase." : "Pushed #{branch} to #{where}."
        end
        forced ? "Force-pushed #{branch} (with lease) after a rebase." : "Pushed #{branch}."
      end

      def first_line(text)
        text.to_s.scrub.lines.first.to_s.strip[0, 300]
      end
    end
  end
end
