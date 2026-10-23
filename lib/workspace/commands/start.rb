require "json"
require "fileutils"

module Workspace
  module Commands
    # Creates a git worktree and launches it as a workspace project.
    # Accepts JIRA keys, GitHub PR/issue URLs, PR refs (`#n`, `owner/repo#n`), or
    # branch names as input. A PR is checked out with `gh pr checkout --worktree`
    # as branch `pr-<n>`, which is safe for PRs from forks.
    class Start
      JSON_SCHEMA_VERSION = 1

      # @param git [Workspace::Git] git operations
      # @param project_config [Workspace::ProjectConfig] config generation
      # @param project_settings [Workspace::ProjectSettings] per-project settings
      # @param launch_command [#call] launch command (Commands::Launch or similar)
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      # @param lineage [Workspace::WorkspaceLineage] writes the `.workspace-project` marker,
      #   and resolves the parent repo when start is run from inside a linked
      #   worktree, so the new worktree targets the parent project
      # @param hook_installer [Workspace::HookInstaller, nil] installs agent hooks
      #   (edit lock enforcement, session monitoring) into the new worktree; nil skips it
      # @param hooks_config [Workspace::HooksConfig, nil] reads `codex.hooks.install`; nil installs every agent's hooks
      # @param which [#call] returns true when an executable is on PATH
      # @param task_store [Workspace::TaskStore, nil] records the workspace's task and
      #   exports its id as `WORKSPACE_TASK` in the panes; nil starts without a task
      # @param event_log [Workspace::EventLog, nil] records `worktree_started` once the
      #   worktree's config is written; nil records nothing
      # @param library [Workspace::Library, nil] resolves `plays:`, `agents:` and `skills:`; nil refuses them
      # @param library_installer [Workspace::LibraryInstaller, nil] copies `agents:` and `skills:` into the worktree
      # @param notes_setup [Workspace::NotesSetup, nil] fixes the worktree's notes directory (its own `notes.dir`,
      #   the directory, its exclude line); nil sets nothing up
      # @param instruction_composer [Workspace::InstructionComposer, nil] composes the packs sent with the first
      #   prompt (the automatic `notes` pack, and `packs:`); nil sends none
      # @param start_ref [Workspace::StartRef, nil] reads the input and finds the project; nil builds one from +git+ and +lineage+
      # @param main_agent [Workspace::MainAgent, nil] reads which agent the new workspace's main pane runs, for the
      #   `agent_kind` the JSON reports; nil leaves it out
      # @param agent_commands [Workspace::AgentCommands, nil] reads `agent.kind` (the kind when no `--agent-kind` is given, resolved
      #   for the parent project) and the configured command checked on PATH; nil keeps the template's Claude Code
      # @param spine_init [Workspace::Commands::SpineInit, nil] makes the workspace's `spine/` for `--spine` and `spine.auto`; nil refuses `--spine`
      # @param spine_config [Workspace::SpineConfig, nil] reads `spine.auto`; nil never runs init unasked
      # @param ticket_source [Workspace::TicketSource, nil] reads the ticket's title for +title_from_ticket+ and +slug+; nil reads none
      # @param plan_command [Workspace::Commands::Plan, nil] writes the new plan for `--plan` (`plan init`); nil refuses `--plan`
      def initialize(git:, project_config:, project_settings:, launch_command:, lineage: WorkspaceLineage.new,
        hook_installer: nil, hooks_config: nil, which: nil, task_store: nil, event_log: nil, library: nil, library_installer: nil,
        notes_setup: nil, instruction_composer: nil, start_ref: nil, main_agent: nil, agent_commands: nil, ticket_source: nil, spine_init: nil, spine_config: nil, plan_command: nil, output: $stdout, input: $stdin, error_output: $stderr)
        @git = git
        @project_config = project_config
        @project_settings = project_settings
        @launch_command = launch_command
        @lineage = lineage
        @start_ref = start_ref || StartRef.new(git: git, lineage: lineage)
        @hook_installer = hook_installer
        @hooks_config = hooks_config
        @which = which || Workspace::Which
        @task_store = task_store
        @event_log = event_log
        @library = library
        @library_installer = library_installer
        @notes_setup = notes_setup
        @instruction_composer = instruction_composer
        @main_agent = main_agent
        @agent_commands = agent_commands
        @ticket_source = ticket_source
        @spine_init = spine_init
        @spine_config = spine_config
        @plan_command = plan_command
        @output = output
        @input = input
        @error_output = error_output
      end

      # Creates a worktree from the given input and launches it.
      #
      # @param input_string [String] JIRA key, PR URL, PR ref (`#n`, `owner/repo#n`), or branch name
      # @param prompt [String, nil] optional prompt to send to the coding agent after launching
      # @param prompt_timeout [Numeric, nil] seconds to wait for the agent to be
      #   ready before giving up on the prompt; nil uses the launch command's default
      # @param base [String, nil] branch/ref to create a new branch from, skipping the
      #   base-branch prompt
      # @param yes [Boolean] accept every default instead of prompting
      # @param title [String, nil] a human title for the workspace's task
      # @param plays [Array<String>] library plays (`name` or `play/name`) to send ahead of
      #   +prompt+, one line each in order, resolved from the parent project's library, then
      #   global, before anything is created; the JSON payload reports the first as `play`
      #   and all of them as `plays`
      # @param agents [Array<String>] library agents to copy into the worktree's `.claude/agents/`
      # @param skills [Array<String>] library skills to copy into the worktree's `.claude/skills/`; both are
      #   resolved like +plays+ before anything is created, and reported as `agents` and `skills`
      # @param headless [Boolean] launch the session in the background with plain
      #   tmux instead of in iTerm2 (see Commands::Launch#call)
      # @param no_launch [Boolean] create the worktree, config and task and start nothing; refused with
      #   +prompt+, +prompt_timeout+, +plays+, +packs+ or +handoff: true+, which all need an agent to send to.
      #   The automatic packs are not sent (+packs+ reports +[]+); `workspace launch` sends them later
      # @param agent_kind [String, nil] an {AgentProvider} key for the main agent pane of a config this run writes
      #   (`codex`); nil uses `agent.kind`. Checked before anything is created
      # @param title_from_ticket [Boolean] fill +title+ from the ticket (JIRA key, issue or pull request) when none is
      #   given; a ticket that cannot be read is a warning and the title stays empty
      # @param slug [Boolean] add the title's words to the branch of a JIRA or issue ref (`issue-42-fix-login`);
      #   implies +title_from_ticket+, and is ignored with a warning when no title is found
      # @param spine [String, Boolean, nil] `--spine[=NAME]` (a name, or true for the resolved `spine.template`) runs
      #   `spine init` once the worktree exists; false (`--no-spine`) never does; nil follows `spine.auto`. Run before the
      #   first prompt is composed, so the automatic `spine` pack goes to the new agent. A failure is a warning
      # @param plan [String, Boolean, nil] `--plan[=TITLE]` runs `plan init` in the new worktree (a title, or true for the task's
      #   title) and sends the implementation-plan play with the first prompt, bound to the pane like `plan start`. A new or
      #   empty plan also gets the draft request ({PlanDispatch::DRAFT_PROMPT}) ahead of +prompt+, which becomes the goal. Refused
      #   with +play+; with +no_launch+ the plan is made and nothing is sent. A plan that exists is kept; a failed init is a warning
      #   and sends no play. The JSON payload reports it as `plan`
      # @param recipe [String, nil] a library recipe (`name` or `recipe/name`) whose plays, packs, agents, skills,
      #   agent kind and prompt fill in whichever of +plays+, +packs+, +agents+, +skills+, +agent_kind+ and
      #   +prompt+ were not given (a given list replaces the recipe's, it is not added to it). With +no_launch+ its
      #   plays, packs and prompt are left out with a warning. An unknown or invalid recipe fails before anything
      #   is created; the JSON payload reports it as `recipe`
      # @param promoted [Boolean] the worktree at `.worktrees/<branch>` was just made by `promote`: the `worktree_started` event
      #   says `created: true, promoted: true` and the "already exists" line is not printed
      # @param root [String, nil] the main checkout to start in, in place of the working directory's repository
      # @param json [Boolean] emit the documented JSON schema instead of plain text; on
      #   an error, prints `{"schema_version":1,"ok":false,"error":"..."}` to stdout and returns
      #   +{exit_code: 1}+ instead of raising
      # @return [Hash, nil] the launch result (+{exit_code:, prompt_failures:}+) merged
      #   with the JSON payload when +json+ is true, or nil if branch selection was
      #   cancelled (only possible when not +json+ and not +yes+)
      # @raise [Workspace::Error] if not in a git repository (unless +json+ is true)
      # @raise [Workspace::UsageError] if a prompt would block on a non-TTY stdin and
      #   neither +base+ nor +yes+ resolves it (unless +json+ is true)
      def call(input_string, prompt: nil, prompt_timeout: nil, base: nil, yes: false, headless: false, json: false, title: nil, plays: [],
        agents: [], skills: [], packs: [], no_packs: false, handoff: nil, no_launch: false, agent_kind: nil, title_from_ticket: false, slug: false, spine: nil, plan: nil, promoted: false, root: nil, recipe: nil)
        options = {prompt: prompt, prompt_timeout: prompt_timeout, base: base, yes: yes, headless: headless, title: title, plays: plays,
                   agents: agents, skills: skills, packs: packs, no_packs: no_packs, handoff: handoff, no_launch: no_launch, agent_kind: agent_kind,
                   title_from_ticket: title_from_ticket, slug: slug, spine: spine, plan: plan, promoted: promoted, root: root, recipe: recipe}
        return call_json(input_string, **options) if json

        start!(input_string, quiet: false, **options)
      end

      # What {#call} prints with +json: true+, returned instead of printed, with a failure raised rather than
      # printed; nothing goes to the output stream. `promote` runs `start` through it.
      #
      # @param input_string [String] as for {#call}
      # @param options [Hash] the keywords of {#call} but +json+
      # @return [Hash] `{exit_code:, json:}`
      # @raise [Workspace::Error] what {#call} would report
      def payload(input_string, prompt: nil, prompt_timeout: nil, base: nil, yes: false, headless: false, **options)
        start!(input_string, quiet: true, prompt: prompt, prompt_timeout: prompt_timeout, base: base, yes: yes, headless: headless, **options)
      end

      private

      def call_json(input_string, **options)
        payload = start!(input_string, quiet: true, **options)
        @output.puts JSON.generate(payload[:json])
        {exit_code: payload[:exit_code]}
      rescue Workspace::Error, SystemCallError => e
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e))
        {exit_code: 1}
      end

      # @return [Hash] when quiet is true, +{exit_code:, json:}+; otherwise the
      #   launch result, or nil if branch selection was cancelled
      def start!(input_string, prompt:, prompt_timeout:, base:, yes:, headless:, quiet:, title: nil, plays: [], agents: [], skills: [], packs: [], no_packs: false, handoff: nil, no_launch: false, agent_kind: nil, title_from_ticket: false, slug: false, spine: nil, plan: nil, promoted: false, root: nil, recipe: nil)
        root ||= @git.root
        raise Workspace::Error, "Not inside a git repository." unless root
        @recipe = nil
        recipe_warnings = []
        if recipe
          @recipe = resolve_recipe(recipe, root)
          fields = @recipe["fields"]
          reasons = {}
          %w[plays packs prompt].each { |key| reasons[key] = "--no-launch sends nothing" } if no_launch
          reasons["plays"] = [reasons["plays"], "--plan sends its own play"].compact.join("; ") if plan
          reasons["packs"] = [reasons["packs"], "--no-packs was given"].compact.join("; ") if no_packs
          skipped = reasons.keys.select { |key| fields.key?(key) }
          if skipped.any?
            recipe_warnings << "Recipe #{@recipe["ref"]}: left out #{skipped.join(", ")} (#{reasons.values_at(*skipped).flat_map { |r| r.split("; ") }.uniq.join("; ")})."
          end
          plays = fields["plays"] if plays.empty? && fields.key?("plays") && !reasons.key?("plays")
          packs = fields["packs"] if packs.empty? && fields.key?("packs") && !reasons.key?("packs")
          prompt = fields["prompt"] if prompt.nil? && fields.key?("prompt") && !reasons.key?("prompt")
          agents = fields["agents"] if agents.empty? && fields.key?("agents")
          skills = fields["skills"] if skills.empty? && fields.key?("skills")
          agent_kind = fields["agent_kind"] if agent_kind.nil? && fields.key?("agent_kind")
        end
        check_no_launch!(no_launch, prompt: prompt, prompt_timeout: prompt_timeout, plays: plays, packs: packs, handoff: handoff)
        @agent_kind = check_agent_kind!(agent_kind)
        @no_launch = no_launch
        raise Workspace::Error, "--spine is not available: no spine init command was wired." if spine && !@spine_init
        @spine_flag = spine
        check_plan!(plan, plays: plays, ref: input_string)
        @plan_flag = plan
        @plan_result = nil
        @spine_result = nil
        @pack_args = {packs: packs, none: no_packs, handoff: handoff}

        interactive = !quiet && !yes && stdin_tty?
        @warnings = []
        recipe_warnings.each { |message| quiet ? @warnings << message : @error_output.puts("Warning: #{message}") }
        @task_title = title&.strip&.then { |t| t unless t.empty? }
        @task_ref = input_string

        project = @start_ref.project(root)
        # Running from inside a linked worktree: resolve to the parent repo so
        # worktree creation, adoption, config naming, and session reuse all
        # target the parent project.
        note_parent_repo(project.root, quiet: quiet) if project.from_worktree
        root = project.root
        project_name = @project_config.existing_name(project.name) || WorkspaceName.normalize(project.name)
        @effective_kind = effective_kind(project_name)
        @project_config.check_agent_kind!(@effective_kind) if @effective_kind
        @plays = resolve_plays(plays, root)
        @plays = [resolve_plan_play(root)] if @plays.empty? && plan && !no_launch
        @packs = no_launch ? nil : resolve_packs(root, packs, no_packs, handoff, quiet: quiet, agent_kind: @effective_kind)
        @copies = resolve_copies({"agent" => agents, "skill" => skills}, root, project_name)
        ref = @start_ref.call(input_string)
        ref = apply_ticket_title(ref, root, quiet: quiet, title_from_ticket: title_from_ticket || slug, slug: slug)

        # A PR is checked out by `gh pr checkout` under its own number, never by
        # its head branch name, which for a fork PR can name an unrelated branch
        # of this repo (`main`).
        pr = ref.pr
        branch_name = ref.branch
        note_pr_base_ignored(branch_name, quiet: quiet) if pr && base
        worktree_dir_name = @git.sanitize_for_filesystem(branch_name)
        worktree_path = File.join(root, ".worktrees", worktree_dir_name)

        if @git.worktree_exists?(worktree_path)
          note_base_ignored(branch_name, quiet: quiet) if base && !pr
          return finish_worktree(project_name, worktree_dir_name, worktree_path, branch_name,
            base: nil, created: promoted, prompt: prompt, prompt_timeout: prompt_timeout, headless: headless, quiet: quiet, already_exists: !promoted, promoted: promoted)
        end

        if pr
          result = {branch_name: branch_name, base_branch: nil}
        else
          result = resolve_or_create_branch(branch_name, base: base, yes: yes, interactive: interactive, quiet: quiet)
          return if result == :cancelled

          branch_name = result[:branch_name]
          worktree_dir_name = @git.sanitize_for_filesystem(branch_name)
          worktree_path = File.join(root, ".worktrees", worktree_dir_name)
        end

        # Check if a worktree for this branch exists at a non-standard location
        existing_path = @git.find_worktree_by_branch(branch_name, repo: root)
        if existing_path
          return finish_worktree(project_name, File.basename(existing_path), existing_path, branch_name,
            base: nil, created: false, prompt: prompt, prompt_timeout: prompt_timeout, headless: headless, quiet: quiet, adopted: true)
        end

        # gh would otherwise reuse or reset a stale pr-<n> branch (left by a
        # removed worktree) in ways that can drop local commits.
        if pr && @git.local_branch_exists?(branch_name)
          raise Workspace::Error,
            "Branch '#{branch_name}' already exists but has no worktree here.\n" \
            "Delete it with `git branch -D #{branch_name}` and rerun, or check it out yourself " \
            "with `git worktree add #{worktree_path} #{branch_name}`."
        end

        @project_config.settle_worktree_name(project_name, worktree_dir_name, worktree_path)
        create_worktree_directory(root)
        begin
          if pr
            log(quiet, "Checking out PR ##{pr[:number]}...")
            @git.checkout_pr_worktree(worktree_path, number: pr[:number], repo: pr[:repo], branch: branch_name, chdir: root, quiet: quiet)
          else
            @git.create_worktree(worktree_path, branch_name, base: result[:base_branch], quiet: quiet)
          end
        rescue Errno::EEXIST
          # A concurrent `start` finished creating .worktrees/ at the same moment; harmless.
        end
        log(quiet, "Worktree created at: #{worktree_path}")

        ensure_gitignore(root, quiet: quiet)

        finish_worktree(project_name, worktree_dir_name, worktree_path, branch_name,
          base: result[:base_branch], created: true, prompt: prompt, prompt_timeout: prompt_timeout, headless: headless, quiet: quiet)
      end

      # Shared tail of every branch: config generation, hook seeding/installation,
      # marker, launch, and (when quiet) the JSON payload.
      def finish_worktree(project_name, worktree_dir_name, worktree_path, branch_name, base:, created:,
        prompt:, prompt_timeout:, headless:, quiet:, already_exists: false, adopted: false, promoted: false)
        log(quiet, "Worktree already exists at: #{worktree_path}") if already_exists
        log(quiet, "Adopting existing worktree at: #{worktree_path}") if adopted

        task = start_task(project_name, worktree_dir_name, worktree_path, branch_name)
        worktree_options = {quiet: quiet}
        worktree_options[:task_id] = task["id"] if task
        worktree_options[:agent_kind] = @agent_kind if @agent_kind
        config_name = @project_config.create_worktree(project_name, worktree_dir_name, worktree_path, branch_name, **worktree_options)
        @effective_kind = effective_kind(config_name)
        @project_settings.ensure_exists(project_name)
        seed_worktree_hooks(project_name, config_name)
        notes_dir = setup_notes(config_name, quiet: quiet)
        install_agent_hooks(worktree_path, config_name, quiet: quiet)
        copied = copy_library_entries(worktree_path, project_name, quiet: quiet)
        write_project_marker(worktree_path, config_name)
        setup_plan(config_name, quiet: quiet)
        setup_spine(config_name, worktree_path, quiet: quiet)
        record_started(config_name, project_name, branch_name, created: created, task: task, promoted: promoted)
        agent_kind = report_agent_kind(config_name, quiet: quiet)
        if @no_launch
          log(quiet, "Not launching #{config_name}; start it with `workspace launch #{config_name}`.")
          @project_settings.ensure_exists(config_name)
          return unless quiet
          return {exit_code: 0, json: start_json(project_name, config_name, worktree_path, branch_name, base, created, headless,
            notes_dir, task, copied, agent_kind, launched: false)}
        end
        log(quiet, "Launching #{config_name}...")
        first_prompt = drafting? ? [PlanDispatch::DRAFT_PROMPT, ("The goal: #{prompt}" if prompt)].compact.join("\n\n") : prompt
        text = (@plays.any? || @packs) ? @library.play_prompt(@plays, first_prompt, packs: @packs&.fetch("text")) : first_prompt
        prompts = text ? {config_name => text} : {}
        bindings = pane_bindings_for(config_name)
        @prompt = prompt
        result = launch(config_name, prompts, prompt_timeout, headless: headless, quiet: quiet, bindings: bindings)
        @project_settings.ensure_exists(config_name)

        return result unless quiet

        exit_code = result ? result[:exit_code] : 0
        started = !(result && result[:start_failures] && result[:start_failures][config_name])
        json = start_json(project_name, config_name, worktree_path, branch_name, base, created, headless,
          notes_dir, task, copied, agent_kind, launched: started)
        if @plays.any?
          rows = @plays.map { |play| play.merge("delivered" => delivered?(result, config_name), "pane" => result&.dig(:bound_panes, config_name)) }
          json["play"] = rows.first
          json["plays"] = rows
        end
        skipped = result&.dig(:skipped_prompts, config_name)
        @warnings << skipped if skipped
        json["packs"] = InstructionComposer.delivery_rows(@packs ? @packs["packs"] : [], delivered: delivered?(result, config_name) && !skipped, pane: result&.dig(:delivered_panes, config_name), skipped: @skipped_packs || [])
        json["session_reused"] = result[:reused].include?(config_name) if result && result[:reused]
        if exit_code != 0
          prompt_failures = result && result[:prompt_failures]
          start_failure = result && result[:start_failures] && result[:start_failures][config_name]
          if start_failure
            json["error"] = "Could not start the workspace session: #{start_failure}"
          else
            json["error"] = "Prompt was not sent to every workspace."
            json["prompt_failures"] = prompt_failures || {}
          end
        end
        json["warnings"] = @warnings if @warnings&.any?

        {exit_code: exit_code, json: json}
      end

      def start_json(project_name, config_name, worktree_path, branch_name, base, created, headless, notes_dir, task, copied, agent_kind, launched:)
        json = {
          "schema_version" => JSON_SCHEMA_VERSION, "ok" => true,
          "project" => project_name,
          "workspace" => config_name,
          "path" => worktree_path,
          "branch" => branch_name,
          "base" => base,
          "created" => created,
          "headless" => headless,
          "launched" => launched,
          "agent_kind" => agent_kind
        }
        json["notes_dir"] = notes_dir if notes_dir
        json["spine"] = @spine_result if @spine_result
        json["plan"] = @plan_result if @plan_result
        json["task"] = {"id" => task["id"], "title" => task["title"]} if task
        json["recipe"] = @recipe.slice("ref", "scope") if @recipe
        %w[agent skill].each { |kind| json["#{kind}s"] = copied[kind] if copied.key?(kind) }
        if @no_launch
          json["packs"] = []
          json["warnings"] = @warnings if @warnings&.any?
        end
        json
      end

      # `--plan` sends the implementation-plan play, which is the one play a first prompt carries.
      def check_plan!(plan, plays:, ref:)
        return unless plan
        if ref.to_s.match?(/\s/)
          raise Workspace::UsageError, "--plan was given a title after a space, so #{ref.inspect} was read as the ref. Give the title with an '=': --plan=#{ref.inspect}."
        end
        raise Workspace::Error, "--plan is not available: no plan command was wired." unless @plan_command && @library
        raise Workspace::UsageError, "--plan sends the implementation-plan play, so it cannot be combined with --play. Drop --play, or add the other text with --prompt or --pack." if plays.any?
      end

      # The built-in play, found like `plan start` finds it: a project's own play of that name never takes its place.
      def resolve_plan_play(root)
        @library.pack(PlanDispatch::PLAY, cwd: root).first
      end

      # Whether the first prompt carries the draft request: the plan is new or has no tasks, and an agent is launched.
      def drafting?
        @plan_result && @plan_result["drafting"]
      end

      # Runs `plan init` for `--plan`. A plan already there is kept (outcome `exists`); a failed init is a warning, and the
      # plan play is not sent. Run before the first prompt is composed.
      def setup_plan(config_name, quiet:)
        return unless @plan_flag
        title = @plan_flag if @plan_flag.is_a?(String)
        begin
          path = @plan_command.init(name: config_name, title: title, print: false)["path"]
          outcome = "created"
        rescue Workspace::Error => e
          raise unless e.code == "plan_exists"
          path = e.details["path"]
          outcome = "exists"
        end
        plan = PlanFile.read(path)
        drafting = !@no_launch && (plan.nil? || plan.tasks.empty?)
        note = if @no_launch
          " (nothing sent: run `workspace plan start` to have the agent draft the tasks)"
        elsif !drafting
          " (it has tasks, so the agent is not asked to redraft)"
        end
        log(quiet, "Plan #{outcome}: #{path}#{note}")
        @plan_result = {"path" => path, "outcome" => outcome, "title" => plan&.title,
                        "drafting" => drafting}.compact
      rescue Workspace::Error, SystemCallError => e
        message = "Could not make the plan: #{e.message} The agent starts without it; run `workspace plan init`, then `workspace plan start`."
        quiet ? @warnings << message : @error_output.puts("Warning: #{message}")
        @plays = []
        @plan_result = {"path" => nil, "outcome" => "failed", "drafting" => false}
        @plan_result["error"] = e.code if e.respond_to?(:code) && e.code
      end

      # What a launch would send or wait for has nowhere to go, so each is refused rather than dropped.
      def check_no_launch!(no_launch, prompt:, prompt_timeout:, plays:, packs:, handoff:)
        return unless no_launch
        flags = []
        flags << "--prompt" if prompt
        flags << "--prompt-timeout" if prompt_timeout
        flags << "--play" if plays.any?
        flags << "--pack" if packs.any?
        flags << "--handoff" if handoff == true
        return if flags.empty?
        raise Workspace::UsageError, "--no-launch starts no agent, so it cannot be combined with #{flags.join(", ")}. " \
          "Drop the flag, or send the text with `workspace launch` afterwards."
      end

      # @return [String, nil] the kind, lowercase
      def check_agent_kind!(kind)
        return if kind.nil?
        known = AgentProvider.all.map(&:key)
        return kind.downcase if known.include?(kind.downcase)
        raise Workspace::Error.new("Unknown --agent-kind '#{kind}'. Known: #{known.join(", ")}.",
          code: "unknown_agent_kind", details: {"kind" => kind, "known" => known})
      end

      # The kind the config ended up running. A config that already existed keeps its panes, so a
      # different --agent-kind is noted, not applied.
      #
      # @return [String, nil] nil when no MainAgent was wired
      def report_agent_kind(config_name, quiet:)
        actual = @main_agent&.kind(config_name)
        message =
          if @agent_kind && actual && actual != @agent_kind
            "Note: --agent-kind #{@agent_kind} was not applied; #{config_name}'s existing config runs #{actual}."
          elsif @effective_kind && (actual.nil? || actual == @effective_kind) && (program = configured_program(config_name)) && !@which.call(program)
            "Note: #{program} is not on your PATH, so its pane will not start an agent."
          end
        return actual unless message
        quiet ? @warnings << message : @error_output.puts(message)
        actual
      end

      # The flag, else `agent.kind` read for +workspace+: the project before the worktree's config name is known
      # (a new worktree's own layer is empty then, so the answer is the same), the config name after.
      def effective_kind(workspace)
        @agent_kind || @agent_commands&.kind(workspace)
      end

      # @return [String] the program of +provider+'s configured command for +config_name+; its own executable without one
      def agent_executable(provider, config_name)
        @agent_commands ? @agent_commands.executable_for(config_name, provider.key) : provider.executable
      end

      # @return [String, nil] the program of the effective kind's configured command; the provider's executable without one
      def configured_program(config_name)
        command = @agent_commands&.command_for(config_name, @effective_kind)
        (command && AgentCommands.program_for(command)) || AgentProvider.find(@effective_kind)&.executable
      end

      # The recipe is looked up from the parent project, like plays, and checked
      # before anything is created.
      def resolve_recipe(ref, root)
        raise Workspace::Error, "--recipe is not available: no library was wired." unless @library
        @library.recipe(ref, cwd: @start_ref.project(root).root)
      end

      # The play is checked before anything is created, so an unknown name or an
      # unreadable file changes nothing.
      def resolve_plays(plays, root)
        return [] if plays.empty?
        Workspace::Library.check_play_count!(plays.uniq)
        raise Workspace::Error, "--play is not available: no library was wired." unless @library
        plays.map { |play| @library.play(play, cwd: root) }.uniq { |play| play["ref"] }
      end

      # What to bind the prompt's pane to once it is delivered: the play with its packs, or the packs alone.
      def pane_bindings_for(config_name)
        names = @packs ? InstructionComposer.pack_names(@packs["packs"]) : []
        return {config_name => @library.play_binding(@plays, packs: names)} if @plays.any?
        names.any? ? {config_name => @library.packs_binding(names)} : {}
      end

      # Whether the prompt is automatic packs alone, which warns instead of failing.
      def optional_packs?
        InstructionComposer.optional_prompt?(@packs, prompt: @prompt, play: @plays.first)
      end

      # The packs sent with the prompt, composed before anything is created so an
      # unknown name or an unreadable pack changes nothing.
      #
      # @return [Hash, nil] from {Workspace::InstructionComposer#compose_start}; nil when none applies
      def resolve_packs(root, packs, none, handoff, quiet:, agent_kind: nil)
        @skipped_packs = []
        unless @instruction_composer
          raise Workspace::Error, "--pack is not available: no library was wired." if packs.any?
          raise Workspace::Error, "--handoff is not available: no library was wired." if handoff == true
          return nil
        end
        composed = @instruction_composer.compose_start(cwd: root, packs: packs, none: none, handoff: handoff, agent_kind: agent_kind)
        @skipped_packs = composed["skipped"] || []
        @skipped_packs.each { |pack| quiet ? @warnings << pack["message"] : @error_output.puts("Warning: #{pack["message"]}") }
        composed["packs"].empty? ? nil : composed
      end

      # Agents and skills are checked before anything is created, like the
      # play. A name given twice is copied once.
      def resolve_copies(refs_by_kind, root, project_name)
        refs_by_kind.reject { |_, refs| refs.nil? || refs.empty? }.to_h do |kind, refs|
          raise Workspace::Error, "--#{kind} is not available: no library was wired." unless @library && @library_installer
          @library_installer.relative_path(kind, "x", project: project_name) # a bad library.install.*_dir fails before anything is created
          [kind, refs.map { |ref| @library.copyable(kind, ref, cwd: root) }.uniq { |e| e["ref"] }]
        end
      end

      # @return [Hash{String=>Array<Hash>}] each kind asked for, to the copy results
      def copy_library_entries(worktree_path, project_name, quiet:)
        @copies.transform_values do |entries|
          entries.map do |entry|
            @library_installer.copy(entry, worktree: worktree_path, project: project_name).tap { |result| report_copy(result, quiet: quiet) }
          end
        end
      end

      def report_copy(result, quiet:)
        notes = {
          "skipped_tracked" => "kept the repo's tracked #{result["path"]}",
          "skipped_linked" => "#{result["path"]} is under a symlinked directory, where git can't tell what it tracks"
        }
        if (note = notes[result["outcome"]])
          message = "Note: #{note}; #{result["ref"]} was not copied."
          quiet ? @warnings << message : @error_output.puts(message)
        else
          verb = {"copied" => "Copied", "replaced" => "Replaced", "unchanged" => "Unchanged"}.fetch(result["outcome"])
          log(quiet, "#{verb} #{result["ref"]} #{(verb == "Unchanged") ? "at" : "to"} #{result["path"]}")
        end
      end

      # Whether launch sent the prompt carrying the play.
      def delivered?(result, config_name)
        return false unless result
        !(result[:prompt_failures] || {}).key?(config_name) && !(result[:start_failures] || {}).key?(config_name)
      end

      # Branch, parent project and task id only: no path, title or prompt.
      # EventLog#record never raises.
      def record_started(config_name, project_name, branch_name, created:, task:, promoted: false)
        data = {"workspace" => config_name, "parent" => project_name, "branch" => branch_name, "created" => created}
        data["promoted"] = true if promoted
        data["task"] = task["id"] if task
        @event_log&.record(type: "worktree_started", project: config_name, data: data)
      end

      def note_base_ignored(branch_name, quiet:)
        message = "Note: --base ignored; branch '#{branch_name}' already exists."
        if quiet
          @warnings << message
        else
          @error_output.puts message
        end
      end

      def note_pr_base_ignored(branch_name, quiet:)
        message = "Note: --base ignored; a pull request is checked out as its own branch '#{branch_name}'."
        if quiet
          @warnings << message
        else
          @error_output.puts message
        end
      end

      # Notes that start was run from inside a linked worktree and resolved the
      # parent repo instead, since the worktree landing under a different repo
      # root than cwd is otherwise surprising.
      #
      # @param parent_root [String] the parent repo's root directory
      # @param quiet [Boolean] whether output is JSON-only
      # @return [void]
      def note_parent_repo(parent_root, quiet:)
        message = "Note: run from inside a linked worktree; using parent repo #{parent_root}."
        if quiet
          @warnings << message
        else
          @error_output.puts message
        end
      end

      # @return [Boolean] false (never blocks on a prompt) for a non-TTY, or a
      #   closed, stdin -- rather than raising IOError from a closed stream.
      def stdin_tty?
        @input.respond_to?(:tty?) && @input.tty?
      rescue IOError
        false
      end

      # Fills the task title from the ticket when none was given, and with +slug+
      # adds the title's words to the branch. A ticket that cannot be read, or a
      # ref with no title, is a warning: the plain branch and no title are used.
      def apply_ticket_title(ref, root, quiet:, title_from_ticket:, slug:)
        return ref unless title_from_ticket

        warn_user = ->(message) { quiet ? @warnings << message : @error_output.puts("Warning: #{message}") }
        if @task_title.nil? && @ticket_source
          begin
            @task_title = @ticket_source.fetch(ref, chdir: root)["title"]&.scrub&.gsub(/[[:space:][:cntrl:]]+/, " ")&.strip&.then { |t| t unless t.empty? }
          rescue Workspace::Error => e
            warn_user.call("Could not read the ticket's title (#{e.code}): #{e.message}")
          end
        end
        return ref unless slug

        slugged = @start_ref.slugged(ref, @task_title)
        # A worktree already made for this ticket (plain or slugged, even under an
        # older title) is reused, not duplicated under a new name.
        if %w[jira github_issue].include?(ref.kind)
          existing = @git.worktree_branches(repo: root)
          reuse = [slugged.branch, ref.branch].find { |branch| existing.include?(branch) } ||
            existing.find { |branch| branch.start_with?("#{ref.branch}-") }
          return ref.dup.tap { |copy| copy.branch = reuse } if reuse
        end
        if slugged.branch == ref.branch
          warn_user.call("--slug left the branch as '#{ref.branch}': it applies to JIRA and issue refs whose ticket has a title with letters or digits.")
          return ref
        end

        slugged
      end

      def log(quiet, message)
        @output.puts message unless quiet
      end

      # Records the workspace's task (or finds the one it already has) before
      # its config is written, so the id can go into the panes' environment.
      def start_task(project_name, worktree_dir_name, worktree_path, branch_name)
        return unless @task_store

        workspace = @project_config.settle_worktree_name(project_name, worktree_dir_name, worktree_path)
        @task_store.start(workspace: workspace, title: @task_title, ref: @task_ref, branch: branch_name, path: worktree_path)
      end

      # @param prompt_timeout [Numeric, nil] nil defers to the launch command's own default
      def launch(config_name, prompts, prompt_timeout, headless:, quiet:, bindings:)
        kwargs = {prompts: prompts}
        kwargs[:report_panes] = true if @packs
        kwargs[:optional] = {config_name => InstructionComposer.pack_names(@packs["packs"])} if optional_packs?
        kwargs[:bindings] = bindings if bindings.any?
        kwargs[:headless] = true if headless
        kwargs[:prompt_timeout] = prompt_timeout unless prompt_timeout.nil?
        kwargs[:quiet] = true if quiet
        @launch_command.call([config_name], **kwargs)
      end

      def resolve_or_create_branch(branch_name, base:, yes:, interactive:, quiet:)
        if @git.branch_exists?(branch_name)
          note_base_ignored(branch_name, quiet: quiet) if base
          return {branch_name: branch_name, base_branch: nil}
        end

        matches = @git.find_matching_branches(branch_name)
        if matches.any?
          if matches.size == 1 && matches.first == branch_name
            return {branch_name: branch_name, base_branch: nil}
          end

          if interactive
            selected = @git.prompt_branch_selection(matches, branch_name)
            return {branch_name: selected, base_branch: nil} if selected
          elsif !base && !yes
            raise Workspace::UsageError,
              "Multiple remote branches match '#{branch_name}': #{matches.join(", ")}.\n" \
              "Pass --base <ref> or --yes to create '#{branch_name}' as a new branch instead, " \
              "or rerun with an unambiguous branch name."
          end
          # Non-interactive with --base or --yes, or interactive selection of
          # "none", both fall through to creating branch_name from a base below.
        end

        base_branch = resolve_base_branch(base: base, yes: yes, interactive: interactive)
        return :cancelled if base_branch == :cancelled

        {branch_name: branch_name, base_branch: base_branch}
      end

      def resolve_base_branch(base:, yes:, interactive:)
        return base if base
        return @git.default_branch if yes

        unless interactive
          raise Workspace::UsageError,
            "Branch does not exist and needs a base to create it from.\n" \
            "Pass --base <ref> or --yes to use the default branch."
        end

        @git.prompt_base_branch || :cancelled
      end

      # Fixes the workspace's notes directory. A problem is a warning (stderr, or
      # `warnings` under --json), never a failed start.
      #
      # @return [String, nil] the notes directory, nil when none was set up
      def setup_notes(config_name, quiet:)
        return unless @notes_setup

        result = @notes_setup.call(config_name)
        result["warnings"].each { |message| quiet ? @warnings << message : @error_output.puts(message) }
        result["dir"]
      end

      # Runs `spine init` when asked (`--spine`) or configured (`spine.auto`), unless `--no-spine`. A failure is a
      # warning and `start` goes on. The packs are composed again afterwards, from the new worktree, because the
      # automatic `spine` pack follows the `spine/` folder, which did not exist when they were first checked.
      def setup_spine(config_name, worktree_path, quiet:)
        # (`spine.auto` runs init on a reused or adopted worktree too; an existing spine/ is never overwritten.)
        @spine_result = run_spine_init(config_name, quiet: quiet) unless @spine_flag == false
        return if @no_launch || !@instruction_composer
        composed = @instruction_composer.compose_start(cwd: worktree_path, agent_kind: @effective_kind, **@pack_args)
        @skipped_packs = composed["skipped"] || []
        @packs = composed["packs"].empty? ? nil : composed
      rescue Workspace::Error => e
        message = "Could not compose the packs again after the spine step, so the ones found before the worktree existed are sent: #{e.message}"
        quiet ? @warnings << message : @error_output.puts("Warning: #{message}")
      end

      # @return [Hash, nil] `{"outcome", "template"}`, or nil when init was not wanted
      def run_spine_init(config_name, quiet:)
        return unless @spine_init
        template = @spine_flag if @spine_flag.is_a?(String)
        return unless @spine_flag || @spine_config&.auto?(config_name)
        answer = @spine_init.call(name: config_name, template: template, print: false)
        log(quiet, "Spine #{answer["outcome"]}: #{answer["dir"]} (template #{answer.dig("template", "name")})")
        {"outcome" => answer["outcome"], "template" => answer["template"]}
      rescue Workspace::Error, SystemCallError => e
        message = "Could not set up the spine: #{e.message}"
        quiet ? @warnings << message : @error_output.puts("Warning: #{message}")
        {"outcome" => "failed", "template" => (template && {"name" => template, "source" => "flag"}) || safe_template(config_name), "error" => (e.respond_to?(:code) ? e.code : nil)}.compact
      end

      def safe_template(config_name)
        @spine_config&.template(config_name)
      rescue Workspace::Error
        nil
      end

      def seed_worktree_hooks(parent_project, worktree_config_name)
        seed_worktree_hooks!(parent_project, worktree_config_name)
      rescue Workspace::ConfigParseError => e
        @error_output.puts "Warning: #{e.message} Worktree hooks were not seeded."
      end

      def seed_worktree_hooks!(parent_project, worktree_config_name)
        parent_data = @project_settings.load(parent_project)
        worktree_hooks = parent_data["worktree_hooks"]
        return unless worktree_hooks&.any?

        worktree_data = @project_settings.load(worktree_config_name)
        return if worktree_data["hooks"]&.any?

        worktree_data["hooks"] = worktree_hooks.dup
        @project_settings.save(worktree_config_name, worktree_data)
      end

      # Installs each detected, hook-capable agent's hooks (session monitoring
      # and edit lock enforcement) into a new or adopted worktree, the same way
      # `workspace init` does for the parent project, and routes
      # statusLine-capable agents' status lines through `workspace statusline`
      # (the way `workspace doctor --fix` does for a parent project), so
      # `workspace handoff check` can read the agent's context usage from the
      # worktree right away. Silent, no prompt: a worktree an agent will
      # immediately be launched into should already be enforcing the edit lock.
      def install_agent_hooks(worktree_path, config_name, quiet:)
        return unless @hook_installer

        AgentProvider.all.select { |p| p.supports_hooks? && @which.call(agent_executable(p, config_name)) }.each do |provider|
          if @hooks_config && !@hooks_config.install_user_hooks?(provider)
            message = "#{provider.label} hooks not installed: codex.hooks.install is false (workspace config set codex.hooks.install true to change)"
            quiet ? @warnings << "Note: #{message}" : @output.puts("Note: #{message}")
            next
          end
          install_provider_hooks(provider, worktree_path, quiet: quiet)
        end

        AgentProvider.all.select { |p| p.supports_statusline? && @which.call(agent_executable(p, config_name)) }.each do |provider|
          notices = @hook_installer.install_statusline(provider, worktree_path,
            command: Commands::Init::STATUSLINE_COMMAND, project_settings: @project_settings, quiet: quiet)
          next unless quiet && notices.any?
          notices.each { |notice| @warnings << "Note: #{notice}." }
        end
      end

      # A user-level hook file (Codex's) is not the worktree's: one that can't
      # be read is a warning, not a failed start.
      def install_provider_hooks(provider, worktree_path, quiet:)
        changed = @hook_installer.install(provider, worktree_path, Commands::Init::HOOK_COMMAND, quiet: quiet)
        @warnings << "Note: #{provider.hook_trust_hint}." if changed && quiet && provider.hook_trust_hint
      rescue Workspace::Error => e
        raise unless provider.user_scoped?

        @warnings << "Note: #{provider.label} hooks not installed: #{e.message}"
      end

      def write_project_marker(worktree_path, config_name)
        @lineage.write_marker(worktree_path, config_name)
      end

      def create_worktree_directory(root)
        FileUtils.mkdir_p(File.join(root, ".worktrees"))
      rescue Errno::EEXIST
        # Another concurrent `start` created it between our check and mkdir; fine.
      end

      def ensure_gitignore(root, quiet:)
        gitignore = File.join(root, ".gitignore")
        if File.exist?(gitignore)
          unless File.read(gitignore).include?(".worktrees")
            File.open(gitignore, "a") { |f| f.puts ".worktrees" }
            log(quiet, "Added .worktrees to .gitignore")
          end
        end
      end
    end
  end
end
