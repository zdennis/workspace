require "fileutils"
require "shellwords"

module Workspace
  module Commands
    # `workflow start`: makes a workspace from a ref or a prompt, then runs a workflow in it.
    # This part reads the ref and the ticket, derives the branch, seeds the definition's
    # inputs and runs every check `workflow run` would make against the project's main
    # checkout, so a refusal leaves nothing behind. `dry_run` stops there. The creating
    # half is {#start_workspace}.
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
      Plan = Struct.new(:definition, :ref, :branch, :project, :path, :would_create, :inputs, :ticket, :spec_path, :checked, :warnings, :prompt, keyword_init: true)

      # @param catalog [Workspace::WorkflowCatalog]
      # @param engine [Workspace::WorkflowEngine] checks the run would pass, through #preflight
      # @param start_ref [Workspace::StartRef]
      # @param ticket_source [Workspace::TicketSource]
      # @param git [Workspace::Git]
      # @param start [Workspace::Commands::Start] makes the workspace, through #payload
      # @param workflow [Workspace::Commands::Workflow] starts the run
      # @param readiness [Workspace::AgentReadiness] waits for the new workspace's agent
      # @param tmux [Workspace::Tmux] names the workspace's session
      # @param agent_commands [Workspace::AgentCommands] finds the agent in a pane
      # @param excludes [Workspace::GitExclude] keeps `.workflow/` out of `git status`
      # @param output [IO]
      def initialize(catalog:, engine:, start_ref:, ticket_source:, git:, start:, workflow:, readiness:, tmux:, agent_commands:, excludes:, output: $stdout)
        @catalog = catalog
        @engine = engine
        @start_ref = start_ref
        @ticket_source = ticket_source
        @git = git
        @start = start
        @workflow = workflow
        @readiness = readiness
        @tmux = tmux
        @agent_commands = agent_commands
        @excludes = excludes
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
      # @raise [Workspace::Error] code `unknown_workflow`, `ticket_not_found`, `ticket_source_unavailable`,
      #   `branch_exists`, or {Workspace::WorkflowEngine#preflight}'s (`input_required`, `workflow_command_unset`)
      def call(id:, ref: nil, prompt: nil, branch: nil, slug: false, inputs: {}, note: nil, base: nil, headless: false,
        agent_kind: nil, prompt_timeout: nil, dry_run: false)
        definition = @catalog.find(id)
        plan = plan(definition, ref: ref, prompt: prompt, branch: branch, slug: slug, inputs: inputs)
        return dry_run_row(id, plan) if dry_run

        start_workspace(plan, note: note, base: base, headless: headless, agent_kind: agent_kind, prompt_timeout: prompt_timeout, slug: slug)
      end

      private

      def plan(definition, ref:, prompt:, branch:, slug:, inputs:)
        prompt = prompt.to_s.strip
        prompt = nil if prompt.empty?
        raise Workspace::UsageError, "workflow start needs a REF or --prompt." unless ref || prompt
        raise Workspace::UsageError, "--branch names the branch for a --prompt; with a REF the branch comes from the ref." if ref && branch

        root = @git.root or raise Workspace::Error, "workflow start must run inside a git repository."
        project = @start_ref.project(root)
        warnings = []
        resolved = ref && @start_ref.call(ref)
        ticket = read_ticket(resolved, root, definition, inputs: inputs, prompt: prompt, slug: slug, warnings: warnings)
        name = branch_for(resolved, ticket, root, prompt: prompt, branch: branch, slug: slug)
        path = File.join(project.root, ".worktrees", @git.sanitize_for_filesystem(name))
        derived = resolved.nil? && branch.nil?
        exists = @git.worktree_exists?(path)
        refuse_existing(name, path, exists) if derived && (exists || @git.local_branch_exists?(name))

        spec_path = spec_file(definition, resolved, ticket, path, inputs)
        seeded = seed(definition, ticket, prompt, inputs, spec_path)
        checked = @engine.preflight(definition: definition, workspace: project.name, worktree: project.root, inputs: seeded, pane: nil)
        Plan.new(definition: definition, ref: resolved, branch: name, project: project, path: path, would_create: !exists, inputs: checked["inputs"],
          ticket: ticket, spec_path: spec_path, checked: checked, warnings: warnings, prompt: prompt)
      end

      # The ticket's fields, nil for a prompt or a plain branch. A failed read is refused when
      # the ticket was the only source of the declared +task+, else it is a warning.
      def read_ticket(resolved, root, definition, inputs:, prompt:, slug:, warnings:)
        return nil unless resolved && %w[jira github_pr github_issue].include?(resolved.kind)

        fetched = @ticket_source.fetch(resolved, chdir: root)
        {"key" => resolved.key, "title" => fetched["title"], "url" => fetched["url"], "body" => fetched["body"]}
      rescue Workspace::Error => e
        raise unless %w[ticket_not_found ticket_source_unavailable].include?(e.code)
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

      # Only declared inputs, and never one --input set.
      def seed(definition, ticket, prompt, inputs, spec_path)
        seeded = inputs.dup
        task = task_text(ticket, prompt)
        seeded["task"] = task if task && declared?(definition, "task") && !inputs.key?("task")
        seeded["spec"] = spec_path if spec_path
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
        options = {yes: true, base: base, headless: headless, spine: false}
        options[:agent_kind] = agent_kind if agent_kind
        options[:slug] = slug if slug
        title = plan.ticket&.fetch("title") || plan.prompt
        options[:title] = title if title
        # The ref as given, not the branch: `start` resolves it again to check out a pull request or an issue.
        started = @start.payload(plan.ref ? plan.ref.input : plan.branch, **options).fetch(:json)
        if started["ok"] == false
          raise Workspace::Error.new(started["error"] || "start failed", code: started["code"], details: started["details"])
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
          write_ticket(plan, spec_file, path)
          pane_id = wait_for_agent(workspace, prompt_timeout)
          row = @workflow.run(id: plan.definition.to_h["id"], workspace: workspace, worktree: path, inputs: inputs, note: note, pane: pane_id)
        rescue => e
          raise with_next(e, plan, inputs, workspace, path, warnings)
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
      def with_next(error, plan, inputs, workspace, path, warnings)
        command = ["workspace workflow run", Shellwords.escape(plan.definition.to_h["id"]), "--name", Shellwords.escape(workspace)]
        inputs.each { |name, value| command.push("--input", "#{name}=#{Shellwords.escape(value)}") }
        details = ((error.respond_to?(:details) && error.details) || {}).merge("workspace" => workspace, "path" => path, "next" => [command.join(" ")])
        details["warnings"] = warnings if warnings.any?
        klass = error.is_a?(Workspace::UsageError) ? Workspace::UsageError : Workspace::Error
        klass.new("#{error.message} The workspace #{workspace} was made at #{path}; run `#{details["next"].first}` to start the workflow in it.",
          code: (error.respond_to?(:code) && error.code) || "error", details: details, retry_with: (error.retry if error.respond_to?(:retry)))
      end
    end
  end
end
