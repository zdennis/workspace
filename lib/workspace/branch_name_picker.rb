require "shellwords"
require "timeout"
require "tmpdir"

module Workspace
  # Asks a headless coding agent for a short branch name for a piece of free text.
  # The call is hardened so the caller's pane, hooks and locks are untouched: the
  # agent runs in a fresh empty temp directory (no project settings load) with
  # `TMUX_PANE`, `TMUX`, `CLAUDECODE` and every `CLAUDE_*` variable unset. It never
  # prints and never raises; a failure is a {Result} with a +reason+.
  class BranchNamePicker
    # The longest name, in characters.
    NAME_MAX = 48

    # The most description characters sent to the agent.
    DESCRIPTION_MAX = 4_000

    # The most stdout bytes read from the agent.
    OUTPUT_MAX_BYTES = 64 * 1024

    # Environment keys always unset for the child.
    UNSET_ENV = %w[TMUX_PANE TMUX CLAUDECODE].freeze

    # @!attribute name [String, nil] the sanitized branch name; nil on failure
    # @!attribute reason [Symbol, nil] +:disabled+, +:no_agent+, +:timeout+, +:output_too_large+, +:failed+ or +:empty+ when +name+ is nil
    Result = Struct.new(:name, :reason, keyword_init: true) do
      # @return [Boolean] whether a name was picked
      def ok? = !name.nil?
    end

    # @param commands [Workspace::AgentCommands] answers the agent kind and its program
    # @param enabled [#call] given the project; whether `go.branch_namer.enabled` is on
    # @param timeout [#call] given the project; seconds from `go.branch_namer.timeout`
    # @param command [#call] given the project; the `go.branch_namer.command` override string, or nil
    # @param runner [#call] `(argv, chdir:, timeout:, env:, max_bytes:)` answering `[stdout, stderr, success]`
    # @param tmpdir [#mktmpdir] makes the fresh working directory
    # @param slug [#call] the fallback slugger for {#fallback}
    # @param env [Hash] the parent environment the child's is based on
    def initialize(commands:, enabled:, timeout:, command:, runner: TimedProcess.method(:run), tmpdir: Dir,
      slug: StartRef.method(:slug), env: ENV)
      @commands = commands
      @enabled = enabled
      @timeout = timeout
      @command = command
      @runner = runner
      @tmpdir = tmpdir
      @slug = slug
      @env = env
    end

    # @param text [String] the free-text description
    # @param project [String, nil] the workspace/project name the config is read for
    # @param root [String, nil] the project's root (unused by the agent call; kept for the caller's context)
    # @return [Result]
    def call(text:, project:, root:)
      return Result.new(reason: :disabled) unless @enabled.call(project)

      argv = argv_for(project, text.to_s[0, DESCRIPTION_MAX])
      return Result.new(reason: :no_agent) unless argv

      run(argv, project)
    rescue
      Result.new(reason: :failed)
    end

    # @param text [String]
    # @return [String] the plain slug of +text+, for when {#call} has no name
    def fallback(text) = @slug.call(text)

    private

    def run(argv, project)
      name = nil
      @tmpdir.mktmpdir("workspace-branch-name") do |dir|
        out, _err, success = @runner.call(argv, chdir: dir, timeout: @timeout.call(project), env: child_env,
          max_bytes: OUTPUT_MAX_BYTES)
        return Result.new(reason: :failed) unless success

        name = sanitize(out)
      end
      name.empty? ? Result.new(reason: :empty) : Result.new(name: name)
    rescue Errno::ENOENT
      Result.new(reason: :no_agent)
    rescue Timeout::Error
      Result.new(reason: :timeout)
    rescue TimedProcess::OutputTooLarge
      Result.new(reason: :output_too_large)
    end

    def argv_for(project, text)
      prompt = prompt_for(text)
      override = @command.call(project).to_s.strip
      return Shellwords.split(override) + [prompt] unless override.empty?
      return nil unless @commands.kind(project) == "claude"

      [@commands.executable_for(project, "claude"), "-p", "--setting-sources", "", prompt]
    end

    def prompt_for(text)
      "Reply with only a short, concise, kebab-case git branch name, no more than #{NAME_MAX} characters, " \
        "for this description. No quotes, no explanation.\n\nDescription:\n#{text}"
    end

    def child_env
      UNSET_ENV.to_h { |key| [key, nil] }.merge(@env.keys.grep(/\ACLAUDE_/).to_h { |key| [key, nil] })
    end

    def sanitize(output)
      text = output.to_s.scrub("").unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      return text if text.length <= NAME_MAX

      cut = text[0, NAME_MAX]
      cut = cut.sub(/-[^-]*\z/, "") unless text[NAME_MAX] == "-" || !cut.include?("-")
      cut.sub(/-\z/, "")
    end
  end
end
