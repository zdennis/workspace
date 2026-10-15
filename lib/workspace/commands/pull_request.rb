require "json"
require "timeout"

module Workspace
  module Commands
    # `pr create`: opens a pull request for a workspace's branch without
    # finishing the workspace. It returns the pull request the branch already
    # has, and otherwise pushes the branch when it has no upstream and runs
    # `gh pr create --fill`. {#find_or_create} is the look-up-or-create step
    # alone; {Commands::Finish} uses it for `finish --pr`.
    class PullRequest
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # Seconds `gh pr create` may take.
      CREATE_TIMEOUT = 60

      REMOTE = "origin"
      NOT_LOGGED_IN = /gh auth login|not logged in|not authenticated|authentication required|bad credentials/i
      private_constant :REMOTE, :NOT_LOGGED_IN

      # @param git [Workspace::Git]
      # @param project_config [Workspace::ProjectConfig] finds a named workspace's checkout
      # @param project_detector [Workspace::ProjectDetector] names the workspace of a directory
      # @param status [#call] reads the branch's pull request, as {Workspace::PullRequestStatus#call} does
      # @param runner [#call] `(argv, chdir:, timeout:)` returning `[stdout, stderr, success]`; runs `git push` and `gh pr create`
      # @param output [IO]
      def initialize(git:, project_config:, project_detector:, status: PullRequestStatus.new, runner: TimedProcess.method(:run), output: $stdout)
        @git = git
        @project_config = project_config
        @project_detector = project_detector
        @status = status
        @runner = runner
        @output = output
      end

      # @param name [String, nil] the workspace; nil means the one the working directory is in
      # @param draft [Boolean] open the pull request as a draft (ignored when one exists)
      # @param json [Boolean] print the document documented in docs/README.pr.md
      # @param working_dir [String] where to look for the workspace when +name+ is nil
      # @return [void]
      # @raise [Workspace::Error] `not_in_workspace`, `unknown_workspace`, `nothing_to_push`, `gh_unavailable`,
      #   or an uncoded error for a detached HEAD, a failed push or a failed create
      def create(name: nil, draft: false, json: false, working_dir: Dir.pwd)
        name ||= @project_detector.detect(working_dir)
        unless name
          raise Workspace::Error.new("No workspace found for #{working_dir}. Run from inside a workspace or pass --name.",
            code: "not_in_workspace", details: {"path" => working_dir})
        end
        path = checkout_path(name)
        branch = @git.worktree_branch(path)
        raise Workspace::Error, "'#{name}' is on a detached HEAD at #{path}. Check out a branch first." if branch.nil?

        pushed = false
        begin
          result = find_or_create(path, draft: draft, label: name) { pushed = prepare_branch(path, branch, quiet: json) }
        rescue Workspace::Error => e
          raise e unless pushed

          raise Workspace::Error.new("#{e.message} ('#{branch}' was already pushed to #{REMOTE}.)", code: e.code, details: e.details)
        end
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}.merge(result))
        else
          @output.puts "#{(result["outcome"] == "created") ? "Created pull request" : "Pull request already exists"}: #{result["url"]}"
        end
      end

      # Returns the pull request a checkout's branch has, or creates one with
      # `gh pr create --fill`. Pushes nothing and checks nothing about the
      # commits; the block is the place for that.
      #
      # @param path [String] the checkout
      # @param draft [Boolean]
      # @param label [String, nil] the workspace, named in a failure message
      # @yield runs just before a pull request is created (not when one exists)
      # @return [Hash] `{"outcome" => "existing" | "created", "url" =>, "number" =>}`
      # @raise [Workspace::Error] `gh_unavailable` (`details.reason` `missing` or `not_logged_in`), or an
      #   uncoded error when `gh pr create` fails or does not answer
      def find_or_create(path, draft: false, label: nil)
        found = @status.call(path)
        raise gh_unavailable("missing") if found["reason"] == "gh_missing"
        raise gh_unavailable("not_logged_in", found["detail"]) if found["detail"].to_s.match?(NOT_LOGGED_IN)
        return {"outcome" => "existing", "url" => found["url"], "number" => found["number"]} if found["found"]

        yield if block_given?
        submit(path, draft, label)
      end

      private

      def checkout_path(name)
        root = @project_config.project_root_for(name)
        raise Workspace::Error.new("Unknown workspace '#{name}'", code: "unknown_workspace", details: {"name" => name}) unless root

        File.expand_path(root)
      end

      def prepare_branch(path, branch, quiet:)
        base = @git.base_ref(path)
        if base && @git.commits_ahead_of(path, base) == 0
          raise Workspace::Error.new("'#{branch}' has no commits ahead of #{base}, so there is nothing to open a pull request for.",
            code: "nothing_to_push", details: {"branch" => branch, "base" => base})
        end
        return false if @git.upstream_branch(path)

        push(path, branch)
        @output.puts "Pushed #{branch} to #{REMOTE}." unless quiet
        true
      end

      def push(path, branch)
        success, stderr = @git.push(path, branch, set_upstream: true)
        return if success

        raise Workspace::Error, "Could not push '#{branch}': #{first_line(stderr)}"
      end

      def submit(path, draft, label)
        argv = ["gh", "pr", "create", "--fill"]
        argv << "--draft" if draft
        stdout, stderr, success = @runner.call(argv, chdir: path, timeout: CREATE_TIMEOUT)
        unless success
          raise gh_unavailable("not_logged_in", first_line(stderr)) if stderr.to_s.match?(NOT_LOGGED_IN)

          subject = label ? "a PR for '#{label}'" : "a pull request"
          raise Workspace::Error, "Could not open #{subject}: #{first_line(stderr)}"
        end

        url = stdout.to_s.lines.map(&:strip).reject(&:empty?).last
        raise Workspace::Error, "gh pr create printed no pull request URL." if url.nil?

        {"outcome" => "created", "url" => url, "number" => url.to_s[%r{/pull/(\d+)\z}, 1]&.to_i}
      rescue Errno::ENOENT
        raise gh_unavailable("missing")
      rescue Timeout::Error
        raise Workspace::Error, "gh pr create did not answer within #{CREATE_TIMEOUT} seconds."
      end

      def gh_unavailable(reason, detail = nil)
        message = if reason == "missing"
          "gh is not installed. Install it from https://cli.github.com, then run 'gh auth login'."
        else
          "gh is not logged in. Run 'gh auth login'."
        end
        details = {"reason" => reason}
        details["detail"] = detail if detail
        Workspace::Error.new(message, code: "gh_unavailable", details: details)
      end

      def first_line(text)
        text.to_s.scrub.lines.first.to_s.strip[0, 300]
      end
    end
  end
end
