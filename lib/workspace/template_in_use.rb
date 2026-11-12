module Workspace
  # Finds the config layers whose `tmuxinator.template` or `tmuxinator.worktree_template` select a
  # tmuxinator template set, so removing or replacing the set is refused while something selects it.
  # `template import` over an existing set and `library remove --kind template` ask it.
  class TemplateInUse
    # How many selecting layers are listed in an error's details.
    LIMIT = 20

    # @param template_config [Workspace::TmuxinatorTemplateConfig] reads the keys through the layers
    # @param project_config [Workspace::ProjectConfig] lists the workspaces
    def initialize(template_config:, project_config:)
      @template_config = template_config
      @project_config = project_config
    end

    # @param name [String] a set's name
    # @param store [Workspace::LibraryStore] the library store the set is in (`global` also checks the global file)
    # @return [Array<Hash>] one row per workspace (or the global file, `workspace` nil) and kind whose layered config selects +name+
    #   by a key: `workspace`, `kind`, `layer`; a config file that can't be read is left out
    def users(name, store)
      workspaces = @project_config.available_projects
      workspaces = workspaces.select { |workspace| WorkspaceName.project_of(workspace) == store.project } if store.scope == "project"
      targets = (store.scope == "global") ? [nil] + workspaces : workspaces
      targets.flat_map do |workspace|
        %i[project worktree].filter_map do |kind|
          hit = @template_config.name(kind, workspace: workspace)
          next unless hit["name"] == name && hit["source"] != "default"
          {"workspace" => workspace, "kind" => kind.to_s, "layer" => hit["source"]}
        rescue ConfigParseError
          nil
        end
      end
    end

    # A set called `default` in a user store hides the built-in one, which every config with no key renders from, so it counts as in use.
    #
    # @param name [String] a set's name
    # @param store [Workspace::LibraryStore]
    # @return [void]
    # @raise [Workspace::Error] `template_in_use` (details `template`, `scope`, `users` empty, `count` 0, `hides` `default`)
    def check_default!(name, store)
      return unless name == TmuxinatorTemplateConfig::DEFAULT_TEMPLATE && store.scope != "builtin"
      raise Error.new("Won't write a tmuxinator template called '#{name}' in the #{store.scope} library: it would hide the built-in one that every config with no tmuxinator.template key renders from. Use another name, or pass --force.",
        code: "template_in_use", details: {"template" => name, "scope" => store.scope, "users" => [], "count" => 0, "hides" => "default"},
        retry_with: {"flags" => ["--force"], "destructive" => true})
    end

    # @param name [String] a set's name
    # @param store [Workspace::LibraryStore]
    # @return [Hash, nil] a `template_in_use` warning (`code`, `message` naming the keys that still select the set, `keys`: the {#users} rows), nil when none do
    def warning(name, store)
      found = users(name, store)
      return if found.empty?
      message = "#{found.size} setting#{"s" unless found.size == 1} still name the tmuxinator template '#{name}' (#{found.first(3).map { |u| "#{u["workspace"] || "global"} #{u["kind"]} via #{u["layer"]}" }.join(", ")}#{", ..." if found.size > 3}); new configs of that kind will fail to find it until you select another with `workspace template use`."
      {"severity" => "warning", "code" => "template_in_use", "message" => message, "keys" => found.first(LIMIT)}
    end

    # @param name [String] a set's name
    # @param store [Workspace::LibraryStore] see {#users}
    # @param verb [String] what is being refused, for the message (`replace`, `remove`)
    # @return [void]
    # @raise [Workspace::Error] `template_in_use` (details `template`, `scope`, `users`) when a key selects the set
    def check!(name, store, verb:)
      found = users(name, store)
      return if found.empty?
      raise Error.new("Won't #{verb} the tmuxinator template '#{name}': #{found.size} setting#{"s" unless found.size == 1} select it (#{found.first(3).map { |u| "#{u["workspace"] || "global"} #{u["kind"]} via #{u["layer"]}" }.join(", ")}#{", ..." if found.size > 3}). Select another with `workspace template use`, or pass --force.",
        code: "template_in_use", details: {"template" => name, "scope" => store.scope, "users" => found.first(LIMIT), "count" => found.size},
        retry_with: {"flags" => ["--force"], "destructive" => true})
    end
  end
end
