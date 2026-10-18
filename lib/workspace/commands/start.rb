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
      # @param which [#call] returns true when an executable is on PATH
      # @param task_store [Workspace::TaskStore, nil] records the workspace's task and
      #   exports its id as `WORKSPACE_TASK` in the panes; nil starts without a task
      # @param event_log [Workspace::EventLog, nil] records `worktree_started` once the
      #   worktree's config is written; nil records nothing
      # @param library [Workspace::Library, nil] resolves `play:`, `agents:` and `skills:`; nil refuses them
      # @param library_installer [Workspace::LibraryInstaller, nil] copies `agents:` and `skills:` into the worktree
      # @param notes_setup [Workspace::NotesSetup, nil] fixes the worktree's notes directory (its own `notes.dir`,
      #   the directory, its exclude line); nil sets nothing up
      # @param instruction_composer [Workspace::InstructionComposer, nil] composes the packs sent with the first
      #   prompt (the automatic `notes` pack, and `packs:`); nil sends none
      # @param start_ref [Workspace::StartRef, nil] reads the input and finds the project; nil builds one from +git+ and +lineage+
      # @param main_agent [Workspace::MainAgent, nil] reads which agent the new workspace's main pane runs, for the
      #   `agent_kind` the JSON reports; nil leaves it out
      # @param spine_init [Workspace::Commands::SpineInit, nil] makes the workspace's `spine/` for `--spine` and `spine.auto`; nil refuses `--spine`
      # @param spine_config [Workspace::SpineConfig, nil] reads `spine.auto`; nil never runs init unasked
      # @param ticket_source [Workspace::TicketSource, nil] reads the ticket's title for +title_from_ticket+ and +slug+; nil reads none
      def initialize(git:, project_config:, project_settings:, launch_command:, lineage: WorkspaceLineage.new,
        hook_installer: nil, which: nil, task_store: nil, event_log: nil, library: nil, library_installer: nil,
        notes_setup: nil, instruction_composer: nil, start_ref: nil, main_agent: nil, ticket_source: nil, spine_init: nil, spine_config: nil, output: $stdout, input: $stdin, error_output: $stderr)
        @git = git
        @project_config = project_config
        @project_settings = project_settings
        @launch_command = launch_command
        @lineage = lineage
        @start_ref = start_ref || StartRef.new(git: git, lineage: lineage)
        @hook_installer = hook_installer
        @which = which || Workspace::Which
        @task_store = task_store
        @event_log = event_log
        @library = library
        @library_installer = library_installer
        @notes_setup = notes_setup
        @instruction_composer = instruction_composer
        @main_agent = main_agent
        @ticket_source = ticket_source
        @spine_init = spine_init
        @spine_config = spine_config
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
      # @param play [String, nil] a library play (`name` or `play/name`) to send ahead of
      #   +prompt+, resolved from the parent project's library, then global, before
      #   anything is created; the JSON payload reports it as `play`
      # @param agents [Array<String>] library agents to copy into the worktree's `.claude/agents/`
      # @param skills [Array<String>] library skills to copy into the worktree's `.claude/skills/`; both are
      #   resolved like +play+ before anything is created, and reported as `agents` and `skills`
      # @param headless [Boolean] launch the session in the background with plain
      #   tmux instead of in iTerm2 (see Commands::Launch#call)
      # @param no_launch [Boolean] create the worktree, config and task and start nothing; refused with
      #   +prompt+, +prompt_timeout+, +play+, +packs+ or +handoff: true+, which all need an agent to send to.
      #   The automatic packs are not sent (+packs+ reports +[]+); `workspace launch` sends them later
      # @param agent_kind [String, nil] an {AgentProvider} key for the main agent pane of a config this run writes
      #   (`codex`); nil keeps the template's Claude Code. Checked before anything is created
      # @param title_from_ticket [Boolean] fill +title+ from the ticket (JIRA key, issue or pull request) when none is
      #   given; a ticket that cannot be read is a warning and the title stays empty
      # @param slug [Boolean] add the title's words to the branch of a JIRA or issue ref (`issue-42-fix-login`);
      #   implies +title_from_ticket+, and is ignored with a warning when no title is found
      # @param spine [String, Boolean, nil] `--spine[=NAME]` (a name, or true for the resolved `spine.template`) runs
      #   `spine init` once the worktree exists; false (`--no-spine`) never does; nil follows `spine.auto`. Run before the
      #   first prompt is composed, so the automatic `spine` pack goes to the new agent. A failure is a warning
      # @param json [Boolean] emit the documented JSON schema instead of plain text; on
      #   an error, prints `{"schema_version":1,"ok":false,"error":"..."}` to stdout and returns
      #   +{exit_code: 1}+ instead of raising
      # @return [Hash, nil] the launch result (+{exit_code:, prompt_failures:}+) merged
      #   with the JSON payload when +json+ is true, or nil if branch selection was
      #   cancelled (only possible when not +json+ and not +yes+)
      # @raise [Workspace::Error] if not in a git repository (unless +json+ is true)
      # @raise [Workspace::UsageError] if a prompt would block on a non-TTY stdin and
      #   neither +base+ nor +yes+ resolves it (unless +json+ is true)
      def call(input_string, prompt: nil, prompt_timeout: nil, base: nil, yes: false, headless: false, json: false, title: nil, play: nil,
        agents: [], skills: [], packs: [], no_packs: false, handoff: nil, no_launch: false, agent_kind: nil, title_from_ticket: false, slug: false, spine: nil)
        options = {prompt: prompt, prompt_timeout: prompt_timeout, base: base, yes: yes, headless: headless, title: title, play: play,
                   agents: agents, skills: skills, packs: packs, no_packs: no_packs, handoff: handoff, no_launch: no_launch, agent_kind: agent_kind,
                   title_from_ticket: title_from_ticket, slug: slug, spine: spine}
        return call_json(input_string, **options) if json

        start!(input_string, quiet: false, **options)
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
      def start!(input_string, prompt:, prompt_timeout:, base:, yes:, headless:, quiet:, title: nil, play: nil, agents: [], skills: [], packs: [], no_packs: false, handoff: nil, no_launch: false, agent_kind: nil, title_from_ticket: false, slug: false, spine: nil)
        root = @git.root
        raise Workspace::Error, "Not inside a git repository." unless root
        check_no_launch!(no_launch, prompt: prompt, prompt_timeout: prompt_timeout, play: play, packs: packs, handoff: handoff)
        @agent_kind = check_agent_kind!(agent_kind)
        @project_config.check_agent_kind!(@agent_kind) if @agent_kind
        @no_launch = no_launch
        raise Workspace::Error, "--spine is not available: no spine init command was wired." if spine && !@spine_init
        @spine_flag = spine
        @spine_result = nil
        @pack_args = {packs: packs, none: no_packs, handoff: handoff}

        interactive = !quiet && !yes && stdin_tty?
        @warnings = []
        @task_title = title&.strip&.then { |t| t unless t.empty? }
        @task_ref = input_string

        project = @start_ref.project(root)
        # Running from inside a linked worktree: resolve to the parent repo so
        # worktree creation, adoption, config naming, and session reuse all
        # target the parent project.
        note_parent_repo(project.root, quiet: quiet) if project.from_worktree
        root = project.root
        project_name = @project_config.existing_name(project.name) || WorkspaceName.normalize(project.name)
        @play = play && resolve_play(play, root)
        @packs = no_launch ? nil : resolve_packs(root, packs, no_packs, handoff, quiet: quiet, agent_kind: @agent_kind)
        @copies = resolve_copies({"agent" => agents, "skill" => skills}, root)
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
            base: nil, created: false, prompt: prompt, prompt_timeout: prompt_timeout, headless: headless, quiet: quiet, already_exists: true)
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
        prompt:, prompt_timeout:, headless:, quiet:, already_exists: false, adopted: false)
        log(quiet, "Worktree already exists at: #{worktree_path}") if already_exists
        log(quiet, "Adopting existing worktree at: #{worktree_path}") if adopted

        task = start_task(project_name, worktree_dir_name, worktree_path, branch_name)
        worktree_options = {quiet: quiet}
        worktree_options[:task_id] = task["id"] if task
        worktree_options[:agent_kind] = @agent_kind if @agent_kind
        config_name = @project_config.create_worktree(project_name, worktree_dir_name, worktree_path, branch_name, **worktree_options)
        @project_settings.ensure_exists(project_name)
        seed_worktree_hooks(project_name, config_name)
        notes_dir = setup_notes(config_name, quiet: quiet)
        install_agent_hooks(worktree_path, quiet: quiet)
        copied = copy_library_entries(worktree_path, quiet: quiet)
        write_project_marker(worktree_path, config_name)
        setup_spine(config_name, worktree_path, quiet: quiet)
        record_started(config_name, project_name, branch_name, created: created, task: task)
        agent_kind = report_agent_kind(config_name, quiet: quiet)
        if @no_launch
          log(quiet, "Not launching #{config_name}; start it with `workspace launch #{config_name}`.")
          @project_settings.ensure_exists(config_name)
          return unless quiet
          return {exit_code: 0, json: start_json(project_name, config_name, worktree_path, branch_name, base, created, headless,
            notes_dir, task, copied, agent_kind, launched: false)}
        end
        log(quiet, "Launching #{config_name}...")
        text = (@play || @packs) ? @library.play_prompt(@play, prompt, packs: @packs&.fetch("text")) : prompt
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
        json["play"] = @play.merge("delivered" => delivered?(result, config_name), "pane" => result&.dig(:bound_panes, config_name)) if @play
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
        json["task"] = {"id" => task["id"], "title" => task["title"]} if task
        %w[agent skill].each { |kind| json["#{kind}s"] = copied[kind] if copied.key?(kind) }
        if @no_launch
          json["packs"] = []
          json["warnings"] = @warnings if @warnings&.any?
        end
        json
      end

      # What a launch would send or wait for has nowhere to go, so each is refused rather than dropped.
      def check_no_launch!(no_launch, prompt:, prompt_timeout:, play:, packs:, handoff:)
        return unless no_launch
        flags = []
        flags << "--prompt" if prompt
        flags << "--prompt-timeout" if prompt_timeout
        flags << "--play" if play
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
          elsif @agent_kind && !@which.call(AgentProvider.all.find { |p| p.key == @agent_kind }.executable)
            "Note: #{@agent_kind} is not on your PATH, so its pane will not start an agent."
          end
        return actual unless message
        quiet ? @warnings << message : @error_output.puts(message)
        actual
      end

      # The play is checked before anything is created, so an unknown name or an
      # unreadable file changes nothing.
      def resolve_play(play, root)
        raise Workspace::Error, "--play is not available: no library was wired." unless @library
        @library.play(play, cwd: root)
      end

      # What to bind the prompt's pane to once it is delivered: the play with its packs, or the packs alone.
      def pane_bindings_for(config_name)
        names = @packs ? InstructionComposer.pack_names(@packs["packs"]) : []
        return {config_name => @library.play_binding(@play, packs: names)} if @play
        names.any? ? {config_name => @library.packs_binding(names)} : {}
      end

      # Whether the prompt is automatic packs alone, which warns instead of failing.
      def optional_packs?
        InstructionComposer.optional_prompt?(@packs, prompt: @prompt, play: @play)
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
      def resolve_copies(refs_by_kind, root)
        refs_by_kind.reject { |_, refs| refs.nil? || refs.empty? }.to_h do |kind, refs|
          raise Workspace::Error, "--#{kind} is not available: no library was wired." unless @library && @library_installer
          [kind, refs.map { |ref| @library.copyable(kind, ref, cwd: root) }.uniq { |e| e["ref"] }]
        end
      end

      # @return [Hash{String=>Array<Hash>}] each kind asked for, to the copy results
      def copy_library_entries(worktree_path, quiet:)
        @copies.transform_values do |entries|
          entries.map do |entry|
            @library_installer.copy(entry, worktree: worktree_path).tap { |result| report_copy(result, quiet: quiet) }
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
      def record_started(config_name, project_name, branch_name, created:, task:)
        data = {"workspace" => config_name, "parent" => project_name, "branch" => branch_name, "created" => created}
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
        composed = @instruction_composer.compose_start(cwd: worktree_path, agent_kind: @agent_kind, **@pack_args)
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
      def install_agent_hooks(worktree_path, quiet:)
        return unless @hook_installer

        AgentProvider.all.select { |p| p.supports_hooks? && @which.call(p.executable) }.each do |provider|
          @hook_installer.install(provider, worktree_path, Commands::Init::HOOK_COMMAND, quiet: quiet)
        end

        AgentProvider.all.select { |p| p.supports_statusline? && @which.call(p.executable) }.each do |provider|
          notices = @hook_installer.install_statusline(provider, worktree_path,
            command: Commands::Init::STATUSLINE_COMMAND, project_settings: @project_settings, quiet: quiet)
          next unless quiet && notices.any?
          notices.each { |notice| @warnings << "Note: #{notice}." }
        end
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
