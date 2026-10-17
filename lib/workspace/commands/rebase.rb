require "json"

module Workspace
  module Commands
    # `rebase`: rebases a workspace's branch onto the repository's default branch.
    #
    # +onto+ says which default branch: `local` (the local branch, nothing
    # fetched), `update` (fetch origin, move the local default branch up to
    # origin's, then rebase onto it) or `remote` (fetch origin, rebase onto
    # `origin/<default>`). It refuses a workspace with changes to tracked files
    # and never stashes them. A rebase that stops on a conflict is aborted by
    # this command, so the workspace is left as it was.
    #
    # `upstream` is the odd one out: it fetches the branch's own upstream and
    # rebases onto it, so it also works on the default branch itself.
    class Rebase
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The accepted values of +onto+.
      TARGETS = %w[local update remote upstream].freeze

      # @param git [Workspace::Git]
      # @param checkout [Workspace::WorkspaceCheckout]
      # @param output [IO]
      def initialize(git:, checkout:, output: $stdout)
        @git = git
        @checkout = checkout
        @output = output
      end

      # @param name [String, nil] the workspace; nil means the one the working directory is in
      # @param onto [String] one of {TARGETS}
      # @param json [Boolean] print the document documented in docs/README.rebase.md
      # @param working_dir [String]
      # @return [void]
      # @raise [Workspace::Error] `not_in_workspace`, `unknown_workspace`, `dirty_worktree`,
      #   `no_upstream` and `upstream_gone` (with `upstream`), `rebase_in_progress` (also when a timed-out rebase could not be aborted), `fetch_failed`, or an uncoded error (`details.aborted` true when a timed-out rebase was aborted) for a detached HEAD, a missing default
      #   branch, a rebase that failed without stopping, or git not answering
      def call(name: nil, onto: nil, json: false, working_dir: Dir.pwd)
        raise UsageError, "--onto must be one of #{TARGETS.join(", ")}." unless TARGETS.include?(onto)

        target = @checkout.resolve(name, working_dir: working_dir, allow_detached: true)
        result = rebase(target["workspace"], target["path"], target["branch"], onto)
        document = {"workspace" => target["workspace"], "branch" => target["branch"], "onto" => onto,
                    "outcome" => nil, "reason" => nil, "aborted" => nil, "conflicted" => [], "detail" => nil}.merge(result)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true}.merge(document))
        else
          @output.puts message(document)
        end
      end

      private

      def rebase(name, path, branch, onto)
        if @git.rebase_in_progress?(path)
          raise Workspace::Error.new("A rebase is already stopped in '#{path}'. Finish it with git rebase --continue or --abort.",
            code: "rebase_in_progress", details: {"path" => path})
        end
        raise Workspace::Error, "'#{name}' is on a detached HEAD at #{path}. Check out a branch first." if branch.nil?

        dirty = @git.dirty_tracked_files(path)
        raise Workspace::Error, "git could not read the state of #{path}." if dirty.nil?
        unless dirty.empty?
          raise Workspace::Error.new("'#{branch}' has changes to tracked files; commit or stash them first.",
            code: "dirty_worktree", details: {"path" => path, "files" => dirty.first(50)})
        end
        return rebase_onto_upstream(path, branch) if onto == "upstream"

        default = @git.default_branch_name(path)
        raise Workspace::Error, "No default branch (main or master) found in #{path}." unless default
        raise Workspace::Error, "'#{branch}' is the default branch; there is nothing to rebase it onto." if branch == default

        fetch(path) unless onto == "local"
        if onto == "update"
          stopped = update_default(path, default)
          return stopped if stopped
        end
        ref = (onto == "remote") ? "origin/#{default}" : default
        raise Workspace::Error, "'#{ref}' does not exist in #{path}." unless @git.commit_exists?(path, ref)

        run_rebase(path, branch, ref)
      end

      def rebase_onto_upstream(path, branch)
        remote, merge = @git.upstream_config(path, branch)
        if remote.nil?
          raise Workspace::Error.new("'#{branch}' has no upstream; push it first or use --onto local.",
            code: "no_upstream", details: {"branch" => branch})
        end
        run_rebase(path, branch, fetch_upstream(path, branch, remote, merge))
      end

      # Fetches just the upstream branch and returns the ref to rebase onto.
      def fetch_upstream(path, branch, remote, merge)
        short = merge.delete_prefix("refs/heads/")
        if remote == "."
          raise upstream_gone(branch, short) unless @git.commit_exists?(path, "refs/heads/#{short}")

          return short
        end

        success, stderr = @git.fetch(path, merge, remote: remote)
        raise upstream_gone(branch, "#{remote}/#{short}") if !success && stderr.to_s.include?("couldn't find remote ref")
        unless success
          raise Workspace::Error.new("Could not fetch from #{remote}: #{first_line(stderr)}",
            code: "fetch_failed", details: {"remote" => remote, "detail" => first_line(stderr)})
        end
        ref = @git.upstream_branch(path) || "#{remote}/#{short}"
        raise upstream_gone(branch, ref) unless @git.commit_exists?(path, ref)

        ref
      end

      def upstream_gone(branch, upstream)
        Workspace::Error.new("The upstream of '#{branch}' (#{upstream}) no longer exists; push the branch again or use --onto local.",
          code: "upstream_gone", details: {"branch" => branch, "upstream" => upstream})
      end

      def fetch(path)
        success, stderr = @git.fetch(path)
        return if success

        raise Workspace::Error.new("Could not fetch from origin: #{first_line(stderr)}",
          code: "fetch_failed", details: {"remote" => "origin", "detail" => first_line(stderr)})
      end

      # Brings the local default branch up to origin's. Returns nil when it is
      # current (or ahead of origin's), else the document fields that say why not.
      def update_default(path, default)
        remote = "origin/#{default}"
        return nil unless @git.commit_exists?(path, remote)
        unless @git.commit_exists?(path, default)
          raise Workspace::Error, "No local branch '#{default}' to update. Create it or use --onto remote."
        end
        return nil if @git.ancestor?(path, remote, default)
        unless @git.ancestor?(path, default, remote)
          return {"outcome" => "default_not_updated", "reason" => "diverged",
                  "detail" => "Local '#{default}' and #{remote} each have commits the other lacks."}
        end

        holder = @git.find_worktree_by_branch(default, repo: path)
        return nil if holder.nil? && @git.advance_branch(path, default, remote)
        raise Workspace::Error, "Could not move '#{default}' to #{remote}." if holder.nil?

        move_checked_out(holder, default, remote)
      end

      def move_checked_out(holder, default, remote)
        dirty = @git.dirty_tracked_files(holder)
        raise Workspace::Error, "git could not read the state of #{holder}." if dirty.nil?
        stashed = !dirty.empty? && @git.stash_push(holder, "workspace rebase: #{default}")
        raise Workspace::Error, "Could not stash the changes in #{holder}." if !dirty.empty? && !stashed

        moved = @git.fast_forward(holder, remote)
        if stashed
          popped, stderr = @git.stash_pop(holder)
          unless popped
            return {"outcome" => "default_not_updated", "reason" => "stash_pop",
                    "detail" => "'#{default}' #{moved ? "was moved" : "was not moved"}, but the changes stashed in #{holder} did not apply back (kept in the stash): #{first_line(stderr)}"}
          end
        end
        return nil if moved

        {"outcome" => "default_not_updated", "reason" => "diverged",
         "detail" => "'#{default}' in #{holder} could not be fast-forwarded to #{remote} (a local file may be in the way)."}
      end

      def run_rebase(path, branch, ref)
        if @git.ancestor?(path, ref, "HEAD")
          return {"outcome" => "up_to_date"}
        end

        begin
          success, stderr = @git.rebase(path, ref)
        rescue Workspace::Error => e
          raise e unless @git.rebase_in_progress?(path)

          raise stopped_by(e, path, branch)
        end
        return {"outcome" => "rebased"} if success
        unless @git.rebase_in_progress?(path)
          raise Workspace::Error, "git rebase onto #{ref} failed: #{first_line(stderr)}"
        end

        conflicted = @git.conflicted_files(path)
        aborted = @git.rebase_abort(path)
        detail = first_line(stderr)
        detail = "#{detail} (git rebase --abort failed; the rebase is still stopped)".strip unless aborted
        {"outcome" => "conflict", "reason" => "conflict", "aborted" => aborted, "conflicted" => conflicted, "detail" => detail}
      end

      # A git call failed while a rebase was running: abort it, and say what
      # became of the checkout.
      def stopped_by(error, path, branch)
        if @git.rebase_abort(path)
          Workspace::Error.new("#{error.message} The rebase was aborted and '#{branch}' is unchanged.", details: {"aborted" => true})
        else
          Workspace::Error.new("#{error.message} git rebase --abort failed, so #{path} is still in the middle of a rebase. Run 'git rebase --abort' there.",
            code: "rebase_in_progress", details: {"path" => path, "aborted" => false})
        end
      end

      def message(document)
        branch = document["branch"]
        case document["outcome"]
        when "rebased" then "Rebased #{branch} onto #{document["onto"]}."
        when "up_to_date" then "#{branch} is already up to date with #{document["onto"]}."
        when "conflict"
          lines = ["Rebase of #{branch} stopped on a conflict#{" and was aborted" if document["aborted"]}."]
          lines.concat(document["conflicted"].map { |file| "  #{file}" })
          lines.join("\n")
        else
          "Default branch not updated (#{document["reason"]}): #{document["detail"]}"
        end
      end

      def first_line(text)
        text.to_s.scrub.lines.first.to_s.strip[0, 300]
      end
    end
  end
end
