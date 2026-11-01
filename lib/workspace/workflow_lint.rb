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
    def initialize(library:, commands_config:, lineage:, workflow_config:, project_config:)
      @library = library
      @commands_config = commands_config
      @lineage = lineage
      @workflow_config = workflow_config
      @project_config = project_config
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
      {"warnings" => warnings, "not_checked" => not_checked}
    end

    private

    # Every pack a step's instructions are built from: the default packs (every step), the
    # workflow's `include:` (every step) and the step's own. +where+ says what `start` does about it.
    def packs(definition, cwd, project, lineage, warnings, not_checked)
      data = definition.to_h
      total = data["steps"].size
      named = defaults(project, lineage).map { |name| [nil, "workflows.defaults.include (added to every step)", name, true] }
      named += data["include"].map { |name| [nil, "the workflow", name, true] }
      data["steps"].each_with_index do |step, index|
        step["include"].each { |name| named << [step["id"], "step #{step["id"]}", name, index.zero?] }
      end
      # `start` composes the default packs, the workflow's and the first step's, so one of those names the pack for every step.
      refused = named.select { |entry| entry[3] }.map { |entry| entry[2] }
      named.each do |step, where, name, first|
        next if !first && refused.include?(name)
        @library.pack(name, cwd: project ? cwd : nil)
      rescue Workspace::UsageError => e
        warnings << unknown_pack(step, "#{where} names pack #{name}, which is not a valid pack name: #{e.message.lines.first.strip}")
      rescue Workspace::Error => e
        if project
          effect = first ? "`start` would refuse it." : "`start` passes, since it reads only the first step, but the run would stop when it reaches step #{step} (step #{data["steps"].index { |each| each["id"] == step } + 1} of #{total})."
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
      set = @commands_config.for_project(project.name)
      workspace = @project_config.existing_name(project.name)
      needs.reject { |each| set[each["command"].to_sym] }.each do |each|
        hint = if workspace
          "workspace config set commands.#{each["command"]} \"COMMAND\" --name #{workspace}"
        else
          "#{project.name} is not a workspace yet: run `workspace add .` in it, then `workspace config set commands.#{each["command"]} \"COMMAND\"`"
        end
        warnings << {"code" => "command_unset", "step" => each["step"],
                     "message" => "step #{each["step"]} uses the project's #{each["command"]} command (#{each["via"]}: command: #{each["command"]}), and #{project.name} has none, so `start` there would refuse it. Set it: #{hint}"}
      end
    rescue Workspace::ConfigParseError => e
      not_checked << {"code" => "commands_not_checked", "step" => nil, "message" => "the project's commands could not be read: #{e.message.lines.first.strip}"}
    end
  end
end
