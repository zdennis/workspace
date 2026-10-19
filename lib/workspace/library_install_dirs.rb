module Workspace
  # Where `library install` and `start --skill/--agent` put a library agent or
  # skill: the `library.install.*` keys, read when asked, so a change takes
  # effect on the next command. A project's value beats the global one, which
  # beats the default (`.claude/skills`, `.claude/agents`, and `~/.claude/...`
  # for `--user`).
  class LibraryInstallDirs
    KEYS = {
      "skill" => "library.install.skills_dir",
      "agent" => "library.install.agents_dir"
    }.freeze
    USER_KEYS = {
      "skill" => "library.install.user_skills_dir",
      "agent" => "library.install.user_agents_dir"
    }.freeze

    # @param config_resolver [Workspace::ConfigResolver, nil] nil reads no config: every answer is the default
    # @param home [String] what `~/` expands to
    def initialize(config_resolver: nil, home: Dir.home)
      @config_resolver = config_resolver
      @home = home
    end

    # @param kind [String] "skill" or "agent"
    # @param project [String, nil] the workspace or project whose layers apply; nil reads the global layer and the default
    # @return [String] the directory relative to the checkout, without a trailing slash
    # @raise [Workspace::Error] code `invalid_library_install_dir` when the stored value is not valid
    def relative(kind, project: nil)
      read(KEYS.fetch(kind), project)
    end

    # @param kind [String] "skill" or "agent"
    # @return [String] the absolute directory `install --user` copies into
    # @raise [Workspace::Error] code `invalid_library_install_dir`
    def user(kind)
      path = read(USER_KEYS.fetch(kind), nil)
      path.start_with?("~/") ? File.expand_path(path.delete_prefix("~/"), @home) : path
    end

    private

    def read(name, project)
      default = ConfigSchema.default(name)
      return default unless @config_resolver
      view = project ? @config_resolver.view(workspace: project) : @config_resolver.view(workspace: "global", upto: "global")
      winner = view.resolve(name).winner
      return default unless winner
      ConfigSchema.parse(name, winner.value)
    rescue ArgumentError => e
      raise Error.new("#{name} is not valid (#{e.message}). Fix it with: workspace config set #{name} VALUE",
        code: "invalid_library_install_dir", details: {"key" => name})
    end
  end
end
