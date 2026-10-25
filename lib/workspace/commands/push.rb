require "json"

module Workspace
  module Commands
    # `push`: pushes a workspace's branch to origin. A branch with no upstream is
    # pushed with `-u`. A branch whose upstream has commits it lacks is pushed
    # with `--force-with-lease` only when its own history once held every one of
    # those commits (a rebase replaced them); otherwise the push is refused.
    class Push
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # @param git [Workspace::Git]
      # @param checkout [Workspace::WorkspaceCheckout]
      # @param output [IO]
      def initialize(git:, checkout:, output: $stdout)
        @git = git
        @checkout = checkout
        @output = output
      end

      # @param name [String, nil] the workspace; nil means the one the working directory is in
      # @param json [Boolean] print the document documented in docs/README.rebase.md
      # @param working_dir [String]
      # @return [void]
      # @raise [Workspace::Error] `not_in_workspace`, `unknown_workspace`, `fetch_failed`, `push_rejected`,
      #   a {PushFailure} code (`no_remote`, `push_auth_failed`, `protected_branch`, `push_network`, `push_timeout`, `push_failed`),
      #   or an uncoded error for a detached HEAD or git not answering
      def call(name: nil, json: false, working_dir: Dir.pwd)
        target = @checkout.resolve(name, working_dir: working_dir)
        outcome, forced = push_branch(target["path"], target["branch"])
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => target["workspace"],
            "branch" => target["branch"], "outcome" => outcome, "forced" => forced})
        else
          @output.puts message(outcome, forced, target["branch"])
        end
      end

      private

      def push_branch(path, branch)
        upstream = @git.upstream_branch(path)
        unless upstream
          push!(path, branch, set_upstream: true)
          return ["pushed", false]
        end

        unless upstream == "origin/#{branch}"
          raise rejected(branch, upstream, "its upstream is #{upstream}; push only handles origin/#{branch}.", "upstream_mismatch")
        end

        fetched, stderr = @git.fetch(path)
        unless fetched
          raise Workspace::Error.new("Could not fetch from origin: #{first_line(stderr)}",
            code: "fetch_failed", details: {"remote" => "origin", "detail" => first_line(stderr)})
        end
        behind, ahead = @git.behind_ahead(path, upstream)
        raise Workspace::Error, "git could not compare '#{branch}' with #{upstream}." if behind.nil?
        return ["up_to_date", false] if behind == 0 && ahead == 0
        if behind == 0
          push!(path, branch)
          return ["pushed", false]
        end

        if ahead == 0
          raise rejected(branch, upstream, "the branch is #{behind} commit(s) behind #{upstream}; pushing would delete them.", "would_delete_commits")
        end
        unless @git.upstream_commits_replaced?(path, branch, upstream)
          raise rejected(branch, upstream, "#{upstream} has #{behind} commit(s) this branch never had; push was not forced.", "upstream_has_other_commits")
        end
        push!(path, branch, force_with_lease: true)
        ["pushed", true]
      end

      def push!(path, branch, set_upstream: false, force_with_lease: false)
        success, stderr = @git.push(path, branch, set_upstream: set_upstream, force_with_lease: force_with_lease)
        return true if success
        raise PushFailure.error(branch, stderr)
      end

      def rejected(branch, upstream, detail, reason)
        Workspace::Error.new("Push of '#{branch}' was rejected: #{detail}",
          code: "push_rejected", details: {"branch" => branch, "upstream" => upstream, "detail" => detail, "reason" => reason, "permanent" => true})
      end

      def message(outcome, forced, branch)
        return "#{branch} is already up to date on its upstream." if outcome == "up_to_date"

        forced ? "Force-pushed #{branch} (with lease) after a rebase." : "Pushed #{branch}."
      end

      def first_line(text)
        text.to_s.scrub.lines.first.to_s.strip[0, 300]
      end
    end
  end
end
