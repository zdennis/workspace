module Workspace
  # The checks `workflow validate` makes against the person's own setup, which a definition's
  # text alone can't answer: whether its packs (and the default packs every step gets) exist in
  # the library, and whether the project has the `commands.test` / `commands.lint` its steps run.
  # Read-only, never an error.
  #
  # Outside a git checkout there is no project, so a project library or a project's commands
  # can't be searched; what that leaves unchecked comes back under +not_checked+, not as a warning.
  class WorkflowLint
    # @param library [Workspace::Library] finds packs
    # @param commands_config [Workspace::CommandsConfig]
    # @param lineage [Workspace::WorkspaceLineage] names the project of a directory
    # @param workflow_config [Workspace::WorkflowConfig] reads `workflows.defaults.include`
    # @param project_config [Workspace::ProjectConfig] says whether a project is a workspace
    # @param main_agent [Workspace::MainAgent, nil] says which coding agent the project's main pane runs; nil skips that check
    def initialize(library:, commands_config:, lineage:, workflow_config:, project_config:, main_agent: nil)
      @library = library
      @commands_config = commands_config
      @lineage = lineage
      @workflow_config = workflow_config
      @project_config = project_config
      @main_agent = main_agent
    end

    # @param definition [Workspace::WorkflowDefinition]
    # @param cwd [String] the directory the project is read from
    # @return [Hash{String=>Array<Hash>}] "warnings" and "not_checked", each entry
    #   `{"code", "step", "message"}` ("step" nil for the workflow's own `include:` and the default packs)
    def call(definition, cwd:)
      lineage = @lineage.resolve(cwd: cwd)
      project = lineage.git_common_dir ? lineage : nil
      warnings = []
      not_checked = []
      packs(definition, cwd, project, lineage, warnings, not_checked)
      commands(definition, project, warnings, not_checked)
      execs(definition, project, warnings, not_checked)
      agent(definition, project, warnings, not_checked)
      {"warnings" => warnings, "not_checked" => not_checked}
    end

    private

    # Every pack a step's instructions are built from: the default packs (every step), the
    # workflow's `include:` (every step) and each reviewer's and the step's own. +where+ says what `start` does about it.
    def packs(definition, cwd, project, lineage, warnings, not_checked)
      data = definition.to_h
      total = data["steps"].size
      named = defaults(project, lineage).map { |name| [nil, "workflows.defaults.include (added to every step)", name, true] }
      named += data["include"].map { |name| [nil, "the workflow", name, true] }
      (data["reviewers"] || {}).each do |reviewer, spec|
        spec["include"].each { |name| named << [nil, "reviewer #{reviewer}", name, false, "`start` passes, but the run would stop when a review round starts."] }
      end
      data["steps"].each_with_index do |step, index|
        step["include"].each { |name| named << [step["id"], "step #{step["id"]}", name, index.zero?] }
      end
      # `start` composes the default packs, the workflow's and the first step's, so one of those names the pack for every step.
      refused = named.select { |entry| entry[3] }.map { |entry| entry[2] }
      named.each do |step, where, name, first, reviewer_effect|
        next if !first && refused.include?(name)
        @library.pack(name, cwd: project ? cwd : nil)
      rescue Workspace::UsageError => e
        warnings << unknown_pack(step, "#{where} names pack #{name}, which is not a valid pack name: #{e.message.lines.first.strip}")
      rescue Workspace::Error => e
        if project
          effect = reviewer_effect || (first ? "`start` would refuse it." : "`start` passes, since it reads only the first step, but the run would stop when it reaches step #{step} (step #{data["steps"].index { |each| each["id"] == step } + 1} of #{total}).")
          warnings << unknown_pack(step, "#{where} includes pack #{name}, which the library can't find from #{project.name}: #{e.message.lines.first.strip} #{effect}")
        else
          not_checked << {"code" => "pack_not_checked", "step" => step,
                          "message" => "#{where} includes pack #{name}, which is not built in or global; project packs were not searched because the current directory is not in a git checkout. Run validate from the project to check it."}
        end
      end
    end

    def defaults(project, lineage)
      @workflow_config.default_packs(workspace: project ? (lineage.worktree || lineage.name) : nil)
    end

    def unknown_pack(step, message) = {"code" => "unknown_pack", "step" => step, "message" => message}

    def commands(definition, project, warnings, not_checked)
      needs = WorkflowDefinition.command_needs(definition.to_h)
      return if needs.empty?
      unless project
        roles = needs.map { |each| each["command"] }.uniq.join(" and ")
        not_checked << {"code" => "commands_not_checked", "step" => nil,
                        "message" => "the steps use the project's #{roles} command, which was not checked because the current directory is not in a git checkout. Run validate from the project to check it."}
        return
      end
      named = project.worktree || project.name
      set = @commands_config.for_project(named)
      workspace = @project_config.existing_name(named)
      project_known = @project_config.existing_name(project.name)
      needs.reject { |each| set[each["command"].to_sym] }.each do |each|
        project_scope = CommandsConfig.project_scope_command(each["command"], project.name, workspace: named, known: !!project_known)
        hint = if workspace
          "workspace config set commands.#{each["command"]} \"COMMAND\" --name #{workspace}#{"; or once for the whole project: #{project_scope}" if project_scope}"
        else
          "#{named} is not a workspace yet: run `workspace add .` in it, then `workspace config set commands.#{each["command"]} \"COMMAND\"`"
        end
        warnings << {"code" => "command_unset", "step" => each["step"],
                     "message" => "step #{each["step"]} uses the #{each["command"]} command (#{each["via"]}: command: #{each["command"]}), and #{named} has none, so `start` there would refuse it. Set it: #{hint}"}
      end
    rescue Workspace::ConfigParseError => e
      not_checked << {"code" => "commands_not_checked", "step" => nil, "message" => "the commands could not be read: #{e.message.lines.first.strip}"}
    end

    # A run whose main agent is not Claude Code loses what only Claude Code gives: the status line read
    # from the transcript, token measuring for `budget:`, and resuming. A project whose agent is unknown
    # (`none`) is not warned about. Review panes always run Claude Code, so reviews are not part of this.
    def agent(definition, project, warnings, not_checked)
      return if @main_agent.nil?
      unless project
        not_checked << {"code" => "agent_not_checked", "step" => nil,
                        "message" => "the project's main agent was not checked because the current directory is not in a git checkout. Run validate from the project to check it."}
        return
      end
      kind = @main_agent.kind(project.name)
      return if %w[claude none].include?(kind)
      budget = WorkflowDefinition.budget(definition.to_h)
      effects = ["workspace does not read the step's `WORKFLOW_STATUS:` line from the transcript (the agent must run `workspace step done --status`)"]
      effects << "the run's token use is not measured, so `budget:` never stops it" if budget
      effects << "restore, recover and infra retry do not resume it"
      warnings << {"code" => "agent_not_claude", "step" => nil,
                   "message" => "the main agent of #{project.name} is #{kind}, and for it #{effects.join("; ")}."}
    end

    # The `require: exec:` entries: the program (argument 1) by the rule `preflight` refuses by, a
    # `{{changed.tests}}` with no `commands.test_files`, and a list placeholder with no `--` before it.
    # Outside a checkout there is no project to read `test_files` from and no checkout for a relative
    # program (`script/check`) to resolve against, so those come back as not checked; a bare or
    # absolute program is still judged against this process's PATH and HOME.
    def execs(definition, project, warnings, not_checked)
      entries = definition.to_h["steps"].flat_map do |step|
        Array(step["require"]).select { |entry| entry.is_a?(Hash) && entry.key?("exec") }.map { |entry| [step["id"], entry["exec"]] }
      end
      return if entries.empty?
      inputs = definition.to_h["inputs"].keys
      tests_step = nil
      entries.each do |step, argv|
        program = argv.first.to_s
        if project.nil? && program.include?("/") && !program.start_with?("/", "~/")
          not_checked << {"code" => "exec_program_not_checked", "step" => step,
                          "message" => "step #{step} runs #{program}, a program inside the checkout, which was not checked because the current directory is not in a git checkout. Run validate from the project to check it."}
        elsif (why = WorkflowExecProgram.problem(program, checkout: project&.path))
          warnings << {"code" => "exec_program_missing", "step" => step,
                       "message" => "step #{step} runs #{program}, which #{why}, so `start` there would refuse it.#{" A run looks a bare name up on the daemon's PATH, which may differ." if !program.include?("/") && why.include?("PATH")}"}
        end
        WorkflowArgv.problems(argv, inputs: inputs).last.each do |text|
          warnings << {"code" => "exec_list_without_dashes", "step" => step, "message" => "step #{step} exec #{program}: #{text}. Put `--` before the list."}
        end
        tests_step ||= step if WorkflowArgv.list_names(argv).include?("changed.tests")
      end
      return unless tests_step
      unless project
        not_checked << {"code" => "test_files_not_checked", "step" => tests_step,
                        "message" => "step #{tests_step} uses {{changed.tests}}, which needs the workspace's commands.test_files, not checked because the current directory is not in a git checkout. Run validate from the project to check it."}
        return
      end
      named = project.worktree || project.name
      return unless @commands_config.test_files(named).empty?
      workspace = @project_config.existing_name(named)
      hint = if workspace
        "workspace config set commands.test_files \"GLOB ...\" --name #{workspace}"
      else
        "#{named} is not a workspace yet: run `workspace add .` in it, then `workspace config set commands.test_files \"GLOB ...\"`"
      end
      warnings << {"code" => "test_files_unset", "step" => tests_step,
                   "message" => "step #{tests_step} uses {{changed.tests}}, and #{named} has no commands.test_files, so `start` there would refuse it. Set it: #{hint}"}
    rescue Workspace::ConfigParseError => e
      not_checked << {"code" => "test_files_not_checked", "step" => nil, "message" => "the workspace's commands.test_files could not be read: #{e.message.lines.first.strip}"}
    end
  end
end
