module Workspace
  # The coding-agent harnesses `workspace skills install` knows, each with the
  # directory it reads user skills from. Only harnesses whose skill directory
  # has been run and checked are listed.
  class SkillHarnesses
    # One harness: `key` names it on the command line, `dir` is its skills
    # directory, `config_dir` is the directory whose existence says it is set up,
    # `program` is the command found on PATH.
    Harness = Struct.new(:key, :name, :dir, :config_dir, :program)

    # @param home [String] the home directory the paths hang off
    # @param env [#[]] read for `CODEX_HOME`
    # @param which [#call] PATH lookup, given a program name
    def initialize(home:, env: ENV, which: Which)
      @home = home
      @env = env
      @which = which
    end

    # @return [Array<Harness>] every known harness, found or not
    def all
      codex_home = @env["CODEX_HOME"].to_s.empty? ? File.join(@home, ".codex") : File.expand_path(@env["CODEX_HOME"])
      [
        Harness.new("claude", "Claude Code", File.join(@home, ".claude", "skills"), File.join(@home, ".claude"), "claude"),
        Harness.new("codex", "Codex", File.join(codex_home, "skills"), codex_home, "codex"),
        Harness.new("pi", "Pi", File.join(@home, ".pi", "agent", "skills"), File.join(@home, ".pi"), "pi"),
        Harness.new("opencode", "OpenCode", File.join(@home, ".config", "opencode", "skills"), File.join(@home, ".config", "opencode"), "opencode")
      ]
    end

    # @return [Array<Harness>] the harnesses whose program is on PATH or whose config directory exists
    def found
      all.select { |harness| @which.call(harness.program) || File.directory?(harness.config_dir) }
    end

    # @return [String] the shared `~/.agents/skills`, which is never created
    def agents_dir
      File.join(@home, ".agents", "skills")
    end

    # @return [Boolean] whether {#agents_dir} exists
    def agents_dir?
      File.directory?(agents_dir)
    end

    # @return [Array<String>] every skills directory that exists, for uninstall: the harnesses', found or not, and the shared one
    def known_dirs
      (all.map(&:dir) + [agents_dir]).select { |dir| File.directory?(dir) }.uniq
    end
  end
end
