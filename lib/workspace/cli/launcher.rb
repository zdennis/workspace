module Workspace
  class CLI
    # What every verb that launches workspaces shares: `launch`, `relaunch`, `restore`, and the
    # launches `spine start`, `promote --launch` and `plan start` make for a workspace with no
    # session. {#launch} settles the names, resolves the plays and composes the packs before any
    # config is made, then hands the projects to the launch command; {#rows} turns what it did into
    # the `results` rows of an action document. Warnings go to the run's error output.
    class Launcher
      # @param project_config [Workspace::ProjectConfig] resolves launch arguments, finds roots, makes configs
      # @param launch_command [Workspace::Commands::Launch] opens the sessions
      # @param launch_mode [Workspace::LaunchMode] decides headless when no --[no-]headless flag is given
      # @param state [Workspace::State] what Launch recorded per project, read by {#rows}
      # @param project_settings [Workspace::ProjectSettings] each launched project's settings file, made if missing
      # @param hook_runner [Workspace::HookRunner] runs each project's `post_launch` hook
      # @param common [Workspace::CLI::Common] builds the rows
      # @param working_dir [String] the directory packs are composed from for a project with no root
      # @param library [Workspace::Library, nil] resolves `--play` per project; nil refuses `--play`
      # @param instruction_composer [Workspace::InstructionComposer, nil] composes the packs; nil sends none and refuses `--pack`/`--handoff`
      # @param name_migration [Workspace::NameMigration, nil] renames a mixed-case workspace to lowercase first; nil renames nothing
      def initialize(project_config:, launch_command:, launch_mode:, state:, project_settings:, hook_runner:, common:, working_dir:, library: nil, instruction_composer: nil, name_migration: nil)
        @project_config = project_config
        @launch_command = launch_command
        @launch_mode = launch_mode
        @state = state
        @project_settings = project_settings
        @hook_runner = hook_runner
        @common = common
        @working_dir = working_dir
        @library = library
        @instruction_composer = instruction_composer
        @name_migration = name_migration
      end

      # Launches the given project args (already parsed, no leading flags) and returns
      # `{exit_code:, projects:, result:, plays:, packs:, skipped_packs:, prompts:}` (the project
      # names, Launch's own result, each project's resolved plays (a list), each project's composed
      # packs, the packs skipped, and the prompt each was sent) without exiting, so a caller with
      # several batches (`relaunch`) can attempt every batch before deciding whether to exit.
      # The plays and the packs are resolved for every project before any config is created. Packs
      # are sent only when +with_packs+ is true, so `relaunch` and `restore` do not type them again.
      #
      # @param invocation [Invocation] its error output takes the rename and skipped-pack warnings
      # @param args [Array<String>] paths or workspace names
      # @return [Hash]
      # @raise [Workspace::Error] an unknown play or pack, or `--play`/`--pack`/`--handoff` with nothing wired
      # @raise [Workspace::UsageError] more plays than {Library::MAX_PLAYS}
      def launch(invocation, args, reattach: false, headless: nil, prompt: nil, prompt_timeout: nil, plays: [], packs: [], no_packs: false, handoff: nil, with_packs: false, arrange: false)
        # A mixed-case workspace is renamed to lowercase before anything is keyed on its name
        # (see NameMigration), as its agent daemon would rename it once started.
        resolved = args.map { |arg| @project_config.resolve_project_arg(arg) }
          .map { |name, root| [settle_name(invocation, name), root] }
        Library.check_play_count!(plays.uniq)
        by_project = plays.empty? ? {} : resolved.to_h { |name, root| [name, resolve_plays(plays, root || @project_config.project_root_for(name))] }
        composed = with_packs ? compose_packs(resolved, packs, no_packs, handoff) : {}
        skipped_packs = composed.transform_values { |c| c["skipped"] || [] }.reject { |_, skipped| skipped.empty? }
        composed = composed.reject { |_, c| c["packs"].empty? }
        skipped_packs.each_value { |skipped| skipped.each { |pack| invocation.error_output.puts "Warning: #{pack["message"]}" } }
        projects = resolved.map { |name, root| root ? @project_config.create(name, root) : name }

        prompts = projects.each_with_object({}) do |p, h|
          text = (by_project[p] || composed[p]) ? @library.play_prompt(by_project[p], prompt, packs: composed[p]&.fetch("text")) : prompt
          h[p] = text if text
        end

        call_options = {reattach: reattach, prompts: prompts}
        pane_bindings = projects.to_h do |name|
          names = composed[name] ? InstructionComposer.pack_names(composed[name]["packs"]) : []
          [name, by_project[name] ? @library.play_binding(by_project[name], packs: names) : (@library.packs_binding(names) if names.any?)]
        end.compact
        call_options[:bindings] = pane_bindings if pane_bindings.any?
        call_options[:report_panes] = true if composed.any? || prompts.any?
        optional = composed.select { |name, c| InstructionComposer.optional_prompt?(c, prompt: prompt, play: by_project[name]&.first) }
        call_options[:optional] = optional.transform_values { |c| InstructionComposer.pack_names(c["packs"]) } if optional.any?
        call_options[:prompt_timeout] = prompt_timeout if prompt_timeout
        call_options[:headless] = true if @launch_mode.resolve(headless).headless?
        call_options[:arrange] = true if arrange
        result = @launch_command.call(projects, **call_options)

        projects.each do |p|
          @project_settings.ensure_exists(p)
          @hook_runner.run(p, "post_launch")
        end
        {exit_code: result && result[:exit_code], projects: projects, result: result, plays: by_project, packs: composed, skipped_packs: skipped_packs, prompts: prompts}
      end

      # One `results` row per launched project, from the state Launch wrote. A row carries `packs`
      # only when +packs+ is given, and `prompt_sent` is nil for a project +prompts+ does not list.
      #
      # @param projects [Array<String>] the names {#launch} answered
      # @param result [Hash, nil] Launch's own result
      # @param ok_outcome [String] the outcome of a project that launched
      # @return [Array<Hash>]
      def rows(projects, result, ok_outcome: "launched", plays: {}, packs: nil, skipped_packs: {}, prompts: {})
        @state.load
        reused = result&.dig(:reused) || []
        prompt_failures = result&.dig(:prompt_failures) || {}
        start_failures = result&.dig(:start_failures) || {}
        projects.map do |project|
          entry = @state[project]
          sent = !result.nil? && !entry.nil? && !prompt_failures.key?(project) && !start_failures.key?(project)
          skipped = result&.dig(:skipped_prompts)&.key?(project)
          details = {iterm_window_id: entry.is_a?(Hash) ? entry["iterm_window_id"] : nil, headless: entry.is_a?(Hash) && entry["headless"] == true}
          prompt_sent = prompts[project] ? (sent && !skipped) : nil
          details[:position] = result&.dig(:positions, project)
          details[:prompt_sent] = prompt_sent
          details[:pane] = prompt_sent ? result&.dig(:delivered_panes, project) : nil
          if plays[project]&.any?
            play_rows = Array(plays[project]).map { |play| play.merge("delivered" => sent, "pane" => result&.dig(:bound_panes, project)) }
            details[:play] = play_rows.first
            details[:plays] = play_rows
          end
          if packs
            details[:packs] = InstructionComposer.delivery_rows(packs[project] ? packs[project]["packs"] : [], delivered: sent && !skipped,
              pane: result&.dig(:delivered_panes, project), skipped: skipped_packs[project] || [])
          end
          if start_failures[project]
            @common.action_row(project, "failed", reason: "session_not_started", message: start_failures[project].to_s, **details)
          elsif entry.nil?
            @common.action_row(project, "failed", reason: "not_launched", message: "No state was recorded for '#{project}'.", **details)
          elsif prompt_failures[project]
            @common.action_row(project, "failed", reason: "prompt_not_sent", message: prompt_failures[project].to_s, **details)
          else
            @common.action_row(project, reused.include?(project) ? "reused" : ok_outcome, **details)
          end
        end
      end

      private

      # The lowercase name once a mixed-case workspace is renamed; the name as
      # given when nothing was renamed, or its agent daemon is running.
      def settle_name(invocation, name)
        result = @name_migration&.call_locked(name)
        return name unless result

        result.warnings.each { |warning| invocation.error_output.puts "Warning: #{warning}" }
        result.from ? result.name : name
      end

      # The packs `launch` sends each project, from its root's library and config; a
      # project with none has no entry. An unknown pack fails before any config is created.
      def compose_packs(resolved, packs, no_packs, handoff)
        resolved.each_with_object({}) do |(name, root), composed|
          cwd = root || @project_config.project_root_for(name)
          next if cwd.nil? && packs.empty? && handoff != true
          if @instruction_composer.nil?
            raise Error, "--pack is not available: no library was wired." if packs.any?
            raise Error, "--handoff is not available: no library was wired." if handoff == true
            next
          end
          result = @instruction_composer.compose_start(cwd: cwd || @working_dir, packs: packs, none: no_packs, handoff: handoff)
          composed[name] = result unless result["packs"].empty? && result["skipped"].to_a.empty?
        end
      end

      # The plays `launch --play` sends one project, from its root's library, then global.
      def resolve_plays(plays, root)
        raise Error, "--play is not available: no library was wired." unless @library
        plays.map { |play| @library.play(play, cwd: root) }.uniq { |play| play["ref"] }
      end
    end
  end
end
