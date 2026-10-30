require "fileutils"
require "shellwords"

module Workspace
  module Commands
    # `workflow start`: makes a workspace from a ref or a prompt, then runs a workflow in it.
    # This part reads the ref and the ticket, derives the branch, seeds the definition's
    # inputs and runs every check `workflow run` would make against the project's main
    # checkout, so a refusal leaves nothing behind. `dry_run` stops there. The creating
    # half is {#start_workspace}.
    #
    # An agent that starts in a checkout loads that checkout's CLAUDE.md and hooks, so a
    # fork's code is refused (`fork_pull_request`) before anything is made: a pull request
    # unless `gh` says it is not from another repository, and a reused or adopted branch that
    # tracks another repository or is a `pr-N` checkout of a fork's pull request.
    class WorkflowStart
      # Where a ticket's body goes in the new checkout, under the checkout.
      TICKET_DIR = File.join(".workflow", "tickets").freeze

      # What the checks settled on, which the creating half works from.
      #
      # @!attribute definition [Workspace::WorkflowDefinition]
      # @!attribute ref [Workspace::StartRef::Ref, nil] the resolved ref; nil for a prompt
      # @!attribute branch [String] the branch the workspace works on
      # @!attribute project [Workspace::StartRef::Project] the project and its main checkout
      # @!attribute path [String] where the checkout is (or would be)
      # @!attribute would_create [Boolean] false when an existing workspace is reused
      # @!attribute inputs [Hash{String=>String}] the inputs, seeded; +spec+ names the file the creating half writes
      # @!attribute ticket [Hash, nil] +key+, +title+, +url+ and +body+ of the ticket read
      # @!attribute spec_path [String, nil] the file the ticket body is written to
      # @!attribute checked [Hash] {Workspace::WorkflowEngine#preflight}'s answer
      # @!attribute warnings [Array<String>]
      # @!attribute prompt [String, nil] the --prompt text
      # @!attribute checkout [String, nil] the ref `start` is given; a bare `#N` names the repository `gh pr view` read
      Plan = Struct.new(:definition, :ref, :branch, :project, :path, :would_create, :inputs, :ticket, :spec_path, :checked, :warnings, :prompt, :checkout, keyword_init: true)

      # @param catalog [Workspace::WorkflowCatalog]
      # @param engine [Workspace::WorkflowEngine] checks the run would pass, through #preflight
      # @param start_ref [Workspace::StartRef]
      # @param ticket_source [Workspace::TicketSource]
      # @param git [Workspace::Git]
      # @param project_config [Workspace::ProjectConfig] names the project's and its worktrees' workspaces, as `start` does
      # @param start [Workspace::Commands::Start] makes the workspace, through #payload
      # @param workflow [Workspace::Commands::Workflow] starts the run
      # @param readiness [Workspace::AgentReadiness] waits for the new workspace's agent
      # @param tmux [Workspace::Tmux] names the workspace's session
      # @param agent_commands [Workspace::AgentCommands] finds the agent in a pane
      # @param excludes [Workspace::GitExclude] keeps `.workflow/` out of `git status`
      # @param ssh_hosts [Workspace::SshHostResolver] names the real host behind an ssh remote's host alias
      # @param output [IO]
      def initialize(catalog:, engine:, start_ref:, ticket_source:, git:, project_config:, start:, workflow:, readiness:, tmux:, agent_commands:, excludes:, ssh_hosts:, output: $stdout)
        @catalog = catalog
        @engine = engine
        @start_ref = start_ref
        @ticket_source = ticket_source
        @git = git
        @project_config = project_config
        @start = start
        @workflow = workflow
        @readiness = readiness
        @tmux = tmux
        @agent_commands = agent_commands
        @excludes = excludes
        @ssh_hosts = ssh_hosts
        @output = output
      end

      # @param id [String] the workflow
      # @param ref [String, nil] a JIRA key or URL, pull request, issue or branch
      # @param prompt [String, nil] free text: the task, and the branch's name when there is no ref
      # @param branch [String, nil] the branch to use with a prompt and no ref
      # @param slug [Boolean] add the ticket title's words to a JIRA or issue branch, as `start --slug`
      # @param inputs [Hash{String=>String}] values from `--input`; they win over anything seeded
      # @param note [String, nil] added to every step's instructions
      # @param base [String, nil] the branch a new branch starts from
      # @param headless [Boolean]
      # @param agent_kind [String, nil]
      # @param prompt_timeout [Numeric, nil] seconds to wait for the agent
      # @param dry_run [Boolean] check everything and create nothing
      # @return [Hash{String=>Object}] the action row: outcome "dry_run" with "workflow", "step", "project",
      #   "branch", "path", "would_create", "inputs", "packs", "warnings" and, "ticket" (nil when none was read)
      # @raise [Workspace::UsageError] no ref and no prompt, both a ref and a branch, an empty slug, or an invalid branch name
      # @raise [Workspace::Error] code `unknown_workflow`, `ticket_not_found`, `ticket_source_unavailable` (always for a pull
      #   request), `fork_pull_request`, `branch_exists`, or {Workspace::WorkflowEngine#preflight}'s (`input_required`,
      #   `workflow_command_unset`, `invalid_input`, and `dirty_worktree` for a reused or adopted checkout)
      def call(id:, ref: nil, prompt: nil, branch: nil, slug: false, inputs: {}, note: nil, base: nil, headless: false,
        agent_kind: nil, prompt_timeout: nil, dry_run: false)
        definition = @catalog.find(id)
        plan = plan(definition, ref: ref, prompt: prompt, branch: branch, slug: slug, inputs: inputs, agent_kind: agent_kind)
        return dry_run_row(id, plan) if dry_run

        start_workspace(plan, note: note, base: base, headless: headless, agent_kind: agent_kind, prompt_timeout: prompt_timeout, slug: slug)
      end

      private

      def plan(definition, ref:, prompt:, branch:, slug:, inputs:, agent_kind:)
        prompt = prompt.to_s.strip
        prompt = nil if prompt.empty?
        raise Workspace::UsageError, "workflow start needs a REF or --prompt." unless ref || prompt
        raise Workspace::UsageError, "--branch names the branch for a --prompt; with a REF the branch comes from the ref." if ref && branch

        root = @git.root or raise Workspace::Error, "workflow start must run inside a git repository."
        project = @start_ref.project(root)
        project_workspace = @project_config.existing_name(project.name) || WorkspaceName.normalize(project.name)
        require_claude!(agent_kind || @agent_commands.kind(project_workspace))
        warnings = []
        resolved = ref && @start_ref.call(ref)
        ticket = read_ticket(resolved, root, definition, inputs: inputs, prompt: prompt, slug: slug, warnings: warnings)
        allowed = tracked_repositories(root)
        checked = check_pull_request!(definition, resolved, ticket, allowed, "'#{resolved.key}'") if resolved&.kind == "github_pr"
        name = branch_for(resolved, ticket, root, prompt: prompt, branch: branch, slug: slug)
        path = File.join(project.root, ".worktrees", @git.sanitize_for_filesystem(name))
        derived = resolved.nil? && branch.nil?
        exists = @git.worktree_exists?(path)
        refuse_existing(name, path, exists) if derived && (exists || File.exist?(path) || @git.branch_exists?(name))
        # `start` adopts a branch that is checked out in another worktree.
        adopted = (exists || derived) ? nil : @git.find_worktree_by_branch(name, repo: project.root)
        path = adopted if adopted
        exists ||= !adopted.nil?
        # A reused or adopted worktree can have an agent kind of its own.
        require_claude!(@agent_commands.kind(@project_config.worktree_config_name(project_workspace, File.basename(path)))) if exists && !agent_kind
        # A local branch with no worktree is the one `start` would check out.
        if exists || @git.local_branch_exists?(name)
          refuse_foreign_branch!(definition, name, exists ? path : root, root, checked, allowed)
        end

        spec_path = spec_file(definition, resolved, ticket, path, inputs)
        seeded = seed(definition, ticket, prompt, inputs, spec_path, resolved)
        # A checkout that is already there is the one the agent starts in, so its tree is checked; a new one starts clean.
        checked = @engine.preflight(definition: definition, workspace: project.name, worktree: project.root, inputs: seeded, pane: nil, tree: exists ? path : nil)
        Plan.new(definition: definition, ref: resolved, branch: name, project: project, path: path, would_create: !exists, inputs: checked["inputs"],
          ticket: ticket, spec_path: spec_path, checked: checked, warnings: warnings, prompt: prompt, checkout: checkout_ref(resolved, ticket))
      end

      # The ticket's fields, nil for a prompt or a plain branch; a pull request's also has
      # +cross_repository+. A failed read is refused for a pull request, which can't be checked
      # for a fork without it, and when the ticket was the only source of the declared +task+;
      # else it is a warning.
      def read_ticket(resolved, root, definition, inputs:, prompt:, slug:, warnings:)
        return nil unless resolved && %w[jira github_pr github_issue].include?(resolved.kind)

        fetched = @ticket_source.fetch(resolved, chdir: root)
        ticket = {"key" => resolved.key, "title" => fetched["title"], "url" => fetched["url"], "body" => fetched["body"]}
        ticket["cross_repository"] = fetched["cross_repository"] if resolved.kind == "github_pr"
        ticket
      rescue Workspace::Error => e
        raise unless %w[ticket_not_found ticket_source_unavailable].include?(e.code)
        raise if resolved.kind == "github_pr"
        raise if declared?(definition, "task") && !inputs.key?("task") && prompt.nil?

        warnings << "Could not read #{resolved.key}: #{e.message}"
        warnings << "--slug ignored: ticket unreadable" if slug
        nil
      end

      def branch_for(resolved, ticket, project_root, prompt:, branch:, slug:)
        if resolved
          resolved = @start_ref.slugged(resolved, ticket&.fetch("title")) if slug && ticket
          name = resolved.branch
        else
          name = branch || StartRef.slug(prompt)
          raise Workspace::UsageError, "The prompt has no letters or digits to name a branch from. Pass --branch NAME." if name.empty?
        end
        unless resolved&.pr || @git.valid_branch_name?(project_root, name)
          raise Workspace::UsageError, "#{name.inspect} is not a valid branch name."
        end
        name
      end

      # The run's steps go to the workspace's Claude Code pane, so another agent has nowhere to run.
      def require_claude!(kind)
        return if kind == "claude"

        raise Workspace::Error.new("workflow start needs Claude Code as the workspace's agent, and the agent kind is #{kind}. " \
          "Use --agent-kind claude, or run the workflow in a workspace with `workflow run`.",
          code: "workflow_needs_claude", details: {"agent_kind" => kind})
      end

      # The remotes a pull request may belong to: origin's and upstream's repository, as
      # `host/owner/repo`. Read from the project's git config, no network.
      def tracked_repositories(root)
        %w[origin upstream].filter_map { |remote| repository_id(@git.remote_effective_url(root, remote)) }
      end

      # Passes only a pull request whose base is a repository the project tracks and that `gh`
      # says is not from another repository (nil, a missing or odd field, is refused too).
      #
      # @return [String] the pull request as `host/owner/repo#N`
      def check_pull_request!(definition, ref, ticket, allowed, start_arg, details = {})
        number = ref.pr[:number].to_i
        base = pull_request_base(ticket["url"], number)
        reason, what =
          if ticket["cross_repository"].nil?
            ["unknown_cross_repository", "Could not tell whether the pull request #{ref.key} comes from a fork"]
          elsif ticket["cross_repository"]
            ["cross_repository", "The pull request #{ref.key} comes from a fork"]
          elsif !base || !allowed.include?(base)
            ["other_base_repository", "The pull request #{ref.key} belongs to #{base || "a repository it can't name"}, not this project's origin or upstream"]
          end
        return "#{base}##{number}" unless reason

        refuse_fork("#{what}; workflow start does not check out its code or start an agent in it.", definition, start_arg,
          {"pr" => number, "url" => ticket["url"], "cross_repository" => ticket["cross_repository"], "reason" => reason}.merge(details))
      end

      # A reused or adopted checkout, or a local branch `start` would check out, runs another
      # repository's code when it tracks a pull request ref, a URL, or a remote of a repository
      # the project doesn't track (git config, no network; a proxy, not proof of what the branch
      # holds). A `pr-N` branch, or one tracking a local `pr-N`, must hold the pull request being
      # started, by the `workspace-pr` that `start` recorded; with none it is looked up as pull
      # request #N (`start '#N'` drops a fork's upstream, so git config can't tell), as `push` does.
      def refuse_foreign_branch!(definition, name, path, root, checked, allowed)
        tracking = @git.branch_tracking(path, name)
        details = {"branch" => name, "path" => path}
        reason = foreign_tracking(path, tracking, allowed)
        if reason
          refuse_fork("The branch #{name} at #{path} tracks another repository (#{reason.tr("_", " ")}); workflow start does not start an agent in another repository's code.",
            definition, Shellwords.escape(name), details.merge("reason" => reason))
        end

        local = tracking["merge"].to_s[%r{\Arefs/heads/(pr-\d+)\z}, 1] if tracking["remote"] == "."
        number = (Push::PR_BRANCH.match(name) || (local && Push::PR_BRANCH.match(local)))&.[](1)
        return unless number

        recorded = tracking["pr"] if tracking["pr"].to_s.match?(/\A[\w.-]+\/[\w.-]+##{number}\z/)
        if checked && recorded
          return if checked.split("/", 2).last.casecmp?(recorded)
          refuse_other_pull_request(definition, name, recorded, checked, details)
        end
        pr_ref = @start_ref.call(recorded || "##{number}")
        begin
          fetched = @ticket_source.fetch(pr_ref, chdir: root)
        rescue Workspace::Error => e
          raise Workspace::Error.new("Could not read pull request #{pr_ref.key} for the branch #{name}, so workflow start can't tell whether it comes from a fork: #{e.message}",
            code: e.code, details: e.details.merge(details))
        end
        found = check_pull_request!(definition, pr_ref, fetched, allowed, Shellwords.escape(name), details)
        refuse_other_pull_request(definition, name, found, checked, details) if checked && found != checked
      end

      def refuse_other_pull_request(definition, name, held, checked, details)
        refuse_fork("The branch #{name} holds pull request #{held}, not #{checked}; workflow start does not start an agent in it.",
          definition, Shellwords.escape(name), details.merge("reason" => "other_pull_request"))
      end

      def foreign_tracking(path, tracking, allowed)
        remote, merge = tracking.values_at("remote", "merge")
        return "pull_ref" if merge.to_s.start_with?("refs/pull/")
        return nil if remote.nil? || remote == "." || remote == "origin"

        url = @git.remote_config_url(path, remote)
        return remote.match?(%r{://|\A[^/\s]+@[^/\s]+:|\A[/.~]}) ? "url_remote" : "unknown_remote" unless url

        allowed.include?(repository_id(@git.remote_effective_url(path, remote))) ? nil : "other_repository"
      end

      # `host/owner/repo`, lowercased, from a remote URL (scheme://[user@]host[:port]/owner/repo or
      # scp-like [user@]host:owner/repo, with or without `.git`); nil for a local path or anything else.
      # The host of an ssh URL other than github.com is what `ssh -G` reports for it (a `Host` alias in
      # `~/.ssh/config`); when ssh can't say, the host stays as written.
      def repository_id(url)
        text = url.to_s.strip
        match = text.match(%r{\A([a-z][a-z0-9+.-]*)://(?:[^@/]*@)?([^/:]+)(?::\d+)?/(.+)\z}i)
        scheme, host, path = match ? match.captures : [nil, *text.match(%r{\A(?:[^@/]+@)?([^/:]+):(?!/)(.+)\z})&.captures]
        return nil unless host

        path = path.sub(%r{/+\z}, "").sub(/\.git\z/, "")
        return nil unless path.match?(%r{\A[\w.-]+/[\w.-]+\z})

        host = @ssh_hosts.hostname(host) || host if (scheme.nil? || scheme.casecmp?("ssh")) && !host.casecmp?("github.com")
        "#{host}/#{path}".downcase
      end

      # `host/owner/repo` of a pull request's base, from its URL; nil unless the URL is that pull request's.
      def pull_request_base(url, number)
        match = url.to_s.match(%r{\Ahttps://([^/\s]+)/([\w.-]+/[\w.-]+)/pull/(\d+)\z})
        (match && match[3].to_i == number) ? "#{match[1]}/#{match[2]}".downcase : nil
      end

      def refuse_fork(message, definition, start_arg, details)
        start = "workspace start #{start_arg}"
        raise Workspace::Error.new("#{message} If you trust the code, run `#{start}`, then `workspace workflow run #{definition.to_h["id"]}` in that workspace; " \
          "its agent starts in that code and loads its CLAUDE.md and .claude/settings.json hooks.",
          code: "fork_pull_request", details: details.merge("next" => [start]))
      end

      # A bare `#N` is checked out from the repository whose pull request `gh pr view` read, so
      # the checkout can't resolve to another remote's pull request than the one checked for a
      # fork. `start` reads only github.com repositories, so another host keeps `#N`, which `gh`
      # resolves from the same repository config as the read.
      def checkout_ref(resolved, ticket)
        return nil unless resolved
        return resolved.input unless resolved.kind == "github_pr" && resolved.pr[:repo].nil?

        number = resolved.pr[:number]
        repo = ticket["url"].to_s[%r{\Ahttps://github\.com/([\w.-]+/[\w.-]+)/pull/#{number}\z}, 1]
        repo ? "#{repo}##{number}" : resolved.input
      end

      def refuse_existing(name, path, worktree)
        what = worktree ? "A workspace already exists at #{path}" : "The branch #{name} already exists"
        raise Workspace::Error.new("#{what}. Pass --branch #{name} to use it, or --branch NAME for another.",
          code: "branch_exists", details: {"branch" => name, "path" => path, "worktree" => worktree})
      end

      def declared?(definition, name)
        definition.to_h["inputs"].key?(name)
      end

      def spec_file(definition, resolved, ticket, path, inputs)
        return nil unless ticket && ticket["body"].to_s.strip != "" && declared?(definition, "spec") && !inputs.key?("spec")

        File.join(path, TICKET_DIR, "#{resolved.key.gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/\A-|-\z/, "")}.md")
      end

      # Only declared inputs, and never one --input set. `pr` is a pull request ref's number.
      def seed(definition, ticket, prompt, inputs, spec_path, resolved)
        seeded = inputs.dup
        task = task_text(ticket, prompt)
        seeded["task"] = task if task && declared?(definition, "task") && !inputs.key?("task")
        seeded["spec"] = spec_path if spec_path
        seeded["pr"] = resolved.pr[:number].to_s if resolved&.pr && declared?(definition, "pr") && !inputs.key?("pr")
        seeded
      end

      def task_text(ticket, prompt)
        line = ticket && [ticket["key"] + (ticket["title"] ? ": #{ticket["title"]}" : ""), ("(#{ticket["url"]})" if ticket["url"])].compact.join(" ")
        [line, prompt].compact.join("\n\n").then { |text| text.empty? ? nil : text }
      end

      def dry_run_row(id, plan)
        checked = plan.checked
        message = "Would #{plan.would_create ? "create" : "reuse"} the workspace for #{plan.branch} in #{plan.project.name} " \
          "and start #{id} at step #{checked["step"]}."
        @output.puts message
        {"workspace" => nil, "outcome" => "dry_run", "reason" => nil, "message" => message, "workflow" => id,
         "step" => checked["step"], "project" => plan.project.name, "branch" => plan.branch, "path" => plan.path,
         "would_create" => plan.would_create, "inputs" => plan.inputs, "packs" => checked["packs"], "warnings" => plan.warnings,
         "ticket" => plan.ticket&.slice("key", "title", "url")}
      end

      # Makes the workspace, writes the ticket file, waits for the agent and starts the run. Once
      # `start` has made the workspace any failure keeps it and names the command that runs the
      # workflow in it by hand.
      def start_workspace(plan, note:, base:, headless:, agent_kind:, prompt_timeout:, slug:)
        options = {yes: true, base: base, headless: headless, spine: false, no_packs: true}
        options[:agent_kind] = agent_kind if agent_kind
        options[:slug] = true if slug && plan.ticket
        title = plan.ticket&.fetch("title") || plan.prompt&.lines&.first&.strip
        options[:title] = title if title
        # The ref, not the branch: `start` resolves it again to check out a pull request or an issue.
        begin
          result = @start.payload(plan.checkout || plan.branch, **options)
        rescue => e
          raise unless plan.would_create && @git.worktree_exists?(plan.path)
          raise with_next(e, plan, plan.spec_path ? plan.inputs.except("spec") : plan.inputs, note, nil, plan.path, plan.warnings)
        end
        started = result.fetch(:json)
        if started["ok"] == false || !started["workspace"] || !started["path"]
          raise Workspace::Error.new(started["error"] || "start returned no workspace", code: started["code"] || "start_failed")
        end
        workspace = started.fetch("workspace")
        path = started.fetch("path")
        warnings = plan.warnings + Array(started["warnings"])
        inputs = plan.inputs
        spec_file = nil
        if plan.spec_path
          spec_file = File.join(path, TICKET_DIR, File.basename(plan.spec_path))
          inputs = inputs.merge("spec" => spec_file)
        end
        begin
          if result[:exit_code].to_i != 0 || started["launched"] == false
            raise Workspace::Error.new(started["error"] || "The workspace session did not start.", code: "start_failed")
          end
          write_ticket(plan, spec_file, path)
          pane_id = wait_for_agent(workspace, prompt_timeout)
          row = @workflow.run(id: plan.definition.to_h["id"], workspace: workspace, worktree: path, inputs: inputs, note: note, pane: pane_id)
        rescue => e
          raise with_next(e, plan, inputs, note, workspace, path, warnings)
        end
        row.merge("branch" => started["branch"], "path" => path, "created" => started["created"], "task" => started["task"],
          "ticket" => plan.ticket&.slice("key", "title", "url"), "warnings" => warnings)
      end

      # The ticket body goes under the new checkout, where git does not list it.
      def write_ticket(plan, file, path)
        return unless file

        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, plan.ticket["body"])
        @excludes.add(path, "/.workflow/")
      end

      def wait_for_agent(workspace, prompt_timeout)
        seconds = prompt_timeout || AgentReadiness::DEFAULT_TIMEOUT
        ready = @readiness.wait(@tmux.session_name_for(workspace), deadline: @readiness.deadline_in(seconds), detector: @agent_commands.detector(workspace))
        return ready.pane_id if ready.ready?

        raise Workspace::Error.new("The coding agent in #{workspace} was not ready: #{ready.reason} (waited up to #{seconds}s).", code: "agent_not_ready")
      end

      # A UsageError stays one; any other class becomes a plain Workspace::Error, as in promote, because
      # the subclasses do not share a constructor.
      def with_next(error, plan, inputs, note, workspace, path, warnings)
        run = ["workspace workflow run", Shellwords.escape(plan.definition.to_h["id"])]
        run.push("--name", Shellwords.escape(workspace)) if workspace
        inputs.each { |name, value| run.push("--input", "#{name}=#{Shellwords.escape(value)}") unless value.to_s.empty? }
        run.push("--note", Shellwords.escape(note)) if note
        command = workspace ? run.join(" ") : "cd #{Shellwords.escape(path)} && #{run.join(" ")}"
        details = ((error.respond_to?(:details) && error.details) || {}).merge("path" => path, "next" => [command])
        details["workspace"] = workspace if workspace
        details["warnings"] = warnings if warnings.any?
        klass = error.is_a?(Workspace::UsageError) ? Workspace::UsageError : Workspace::Error
        klass.new("#{error.message} The workspace #{workspace || "checkout"} #{plan.would_create ? "was made" : "is"} at #{path}; run `#{command}` to start the workflow in it.",
          code: (error.respond_to?(:code) && error.code) || "error", details: details, retry_with: (error.retry if error.respond_to?(:retry)))
      end
    end
  end
end
