require "shellwords"
require "yaml"

module Workspace
  # Manages tmuxinator config file generation for projects and worktrees.
  class ProjectConfig
    # @param config [Workspace::Config] configuration for path lookups
    # @param git [Workspace::Git] git operations for sanitize_for_filesystem
    # @param output [IO] output stream for user-facing messages
    # @param agent_commands [Workspace::AgentCommands, nil] the configured agent kind and commands; nil
    #   writes each agent's bare executable
    def initialize(config:, git:, output: $stdout, agent_commands: nil)
      @config = config
      @agent_commands = agent_commands
      @output = output
      @git = git
      @root_cache = {}
    end

    # @param arg [String] a project name or path
    # @return [Array(String, String), Array(String, nil)] [project_name, project_root] or [name, nil];
    #   a name taken from a path is settled by {#settle_new_name}
    # @raise [Workspace::Error] code `workspace_name_case_conflict` (see {#settle_new_name})
    def resolve_project_arg(arg)
      if arg == "." || arg.include?("/") || File.directory?(arg)
        root = File.expand_path(arg)
        [settle_new_name(WorkspaceLineage.name_from_path(root), root), root]
      else
        [arg, nil]
      end
    end

    # @param name [String] project name
    # @param root [String] project root directory
    # @return [String] the project name
    # @raise [Workspace::Error] if the template is missing
    # @raise [Workspace::Error] code `workspace_name_case_conflict` (see {#settle_new_name})
    def create(name, root)
      name = settle_new_name(name, root)
      config_path = @config.config_path_for(name)
      if File.exist?(config_path)
        @output.puts "Config already exists: #{config_path}"
        return name
      end

      unless File.exist?(@config.project_template_path)
        raise Workspace::Error, "Template not found: #{@config.project_template_path}"
      end

      template = File.read(@config.project_template_path)
      content = template
        .gsub("{{PROJECT_NAME}}", name)
        .gsub("{{WORKSPACE_NAME}}", name)
        .gsub("{{PROJECT_ROOT}}", root)
        .gsub("{{CONFIG_PATH}}", config_path)

      content = with_agent_kind(content, default_kind(name), name, strict: false)
      File.write(config_path, content)
      @output.puts "Created config: #{config_path}"
      name
    end

    # @param project_name [String] parent project name
    # @param worktree_name [String] worktree directory name
    # @return [String] the config name {#create_worktree} gives that worktree (lowercase)
    def worktree_config_name(project_name, worktree_name)
      WorkspaceName.normalize("#{project_name}.worktree-#{@git.sanitize_for_filesystem(worktree_name)}")
    end

    # @param project_name [String] parent project name
    # @param worktree_name [String] worktree directory name
    # @param worktree_path [String] full path to the worktree
    # @param branch_name [String] git branch name
    # @param task_id [String, nil] the workspace's task id; exported as `WORKSPACE_TASK`
    #   in every pane through the template's `{{PRE_WINDOW}}` line, which is dropped without one
    # @param agent_kind [String, nil] an {AgentProvider} key; nil uses `agent.kind` (resolved for the new
    #   worktree workspace, so the project and global layers apply)
    # @return [String] the config name
    # @raise [Workspace::Error] if the worktree template is missing
    def create_worktree(project_name, worktree_name, worktree_path, branch_name, quiet: false, task_id: nil, agent_kind: nil)
      project_name = WorkspaceName.normalize(project_name)
      tmux_session_name = "#{project_name}.wt-#{@git.sanitize_for_filesystem(worktree_name)}"
        .tr(".", "-").downcase
      config_name = settle_worktree_name(project_name, worktree_name, worktree_path)
      config_path = @config.config_path_for(config_name)

      if File.exist?(config_path)
        @output.puts "Config already exists: #{config_path}" unless quiet
        return config_name
      end

      unless File.exist?(@config.worktree_template_path)
        raise Workspace::Error, "Worktree template not found: #{@config.worktree_template_path}"
      end

      template = File.read(@config.worktree_template_path)
      content = template
        .gsub("{{TMUX_SESSION_NAME}}", tmux_session_name)
        .gsub("{{WORKSPACE_NAME}}", config_name)
        .gsub("{{WORKTREE_PATH}}", worktree_path)
        .gsub("{{PROJECT_NAME}}", project_name)
        .gsub("{{WORKTREE_BRANCH}}", branch_name)
        .gsub("{{DISPLAY_NAME}}", "#{project_name}/#{worktree_name}")
        .gsub("{{CONFIG_PATH}}", config_path)
        .sub(/^\{\{PRE_WINDOW\}\}\n/, task_id ? "pre_window: export WORKSPACE_TASK=#{task_id}\n" : "")

      content = with_agent_kind(content, agent_kind || default_kind(config_name), config_name)
      File.write(config_path, content)
      @output.puts "Created config: #{config_path}" unless quiet
      config_name
    end

    # @param name [String] project or config name
    # @param quiet [Boolean] print nothing to the output stream
    # @return [void]
    def remove(name, quiet: false)
      path = config_path_for(name)
      if File.exist?(path)
        File.delete(path)
        @output.puts "Removed config: #{path}" unless quiet
      end
    end

    # @param name [String] project name
    # @return [String] path to the tmuxinator config file for the given project
    def config_path_for(name)
      @config.config_path_for(name)
    end

    # @param name [String] project name
    # @return [Boolean] whether a config exists for this project
    def exists?(name)
      File.exist?(config_path_for(name))
    end

    # Returns the root directory for a project by reading its tmuxinator config.
    # Results are cached for the lifetime of this instance.
    #
    # @param name [String] project name
    # @return [String, nil] the project root path, or nil if config doesn't exist
    def project_root_for(name)
      return @root_cache[name] if @root_cache.key?(name)

      @root_cache[name] = read_project_root(name)
    end

    # @return [Array<String>] sorted list of available project names
    def available_projects
      Dir.glob(File.join(@config.tmuxinator_dir, "workspace.*.yml"))
        .map { |f| File.basename(f, ".yml").delete_prefix("workspace.") }
        .reject { |n| n.match?(/^project-.*template$/) }
        .sort
    end

    # The name a new config is written under: lowercase. A config already on disk
    # whose name differs only in case (found by comparing the real file names, as
    # the file system itself ignores case) decides it:
    # - the same workspace (same root directory), written earlier with mixed
    #   case: its own name, so the config is reused and keeps working until its
    #   agentd start migrates it;
    # - another workspace (different root): refused, as the two would share one
    #   set of files and one socket on a case-insensitive file system.
    #
    # @param name [String] the name wanted
    # @param root [String, nil] the directory the workspace is for
    # @return [String]
    # @raise [Workspace::Error] code `workspace_name_case_conflict`, details `name`, `existing`, `existing_root`
    def settle_new_name(name, root)
      wanted = WorkspaceName.normalize(name)
      variants = available_projects.select { |other| other != wanted && WorkspaceName.same?(other, wanted) }
      return wanted if variants.empty?

      same = variants.find { |other| root && same_directory?(project_root_for(other), root) }
      return same if same

      existing = variants.first
      existing_root = project_root_for(existing)
      raise Workspace::Error.new(
        "Can't create workspace '#{wanted}': workspace '#{existing}' (#{existing_root || "root unknown"}) already exists and differs only in case. " \
        "'#{existing}' will be renamed to lowercase the next time its agentd starts; " \
        "until then, use '#{existing}' (see `workspace list`) or use a different directory name.",
        code: "workspace_name_case_conflict",
        details: {"name" => wanted, "existing" => existing, "existing_root" => existing_root}
      )
    end

    # @param project_name [String] parent project name
    # @param worktree_name [String] worktree directory name
    # @param worktree_path [String] full path to the worktree
    # @return [String] the config name a worktree gets: {#worktree_config_name} settled by {#settle_new_name}
    # @raise [Workspace::Error] code `workspace_name_case_conflict`
    def settle_worktree_name(project_name, worktree_name, worktree_path)
      settle_new_name(worktree_config_name(project_name, worktree_name), worktree_path)
    end

    # @return [String, nil] the config name that matches +name+ ignoring case, the exact spelling first
    def existing_name(name)
      projects = available_projects
      projects.find { |other| other == name } || projects.find { |other| WorkspaceName.same?(other, name) }
    end

    # Refuses an agent kind the installed worktree template cannot take, so `start` fails before it
    # creates anything.
    #
    # @param kind [String] an {AgentProvider} key
    # @param workspace [String, nil] the workspace whose configured Claude Code command the template may run
    # @raise [Workspace::Error] code `template_outdated` when the template has no Claude Code pane to swap
    def check_agent_kind!(kind, workspace = nil)
      return if kind == "claude" || !File.exist?(@config.worktree_template_path)
      return if template_claude_line(workspace)
      raise Workspace::Error.new("The worktree template has no Claude Code pane to swap for #{kind}; run `workspace init --force` to refresh it.",
        code: "template_outdated", details: {"kind" => kind})
    end

    # The pane command a new config runs for an agent kind: for `claude` the installed worktree
    # template's Claude Code pane with `claude` swapped for the configured command in each half of its
    # `||` chain, else the configured command (the agent's executable when none is set).
    #
    # @param kind [String] an {AgentProvider} key
    # @param workspace [String, nil] the workspace whose config layers pick the command; nil, or no
    #   {AgentCommands} wired, means the agent's executable
    # @return [String, nil] nil for `claude` when the template has no Claude Code pane, or for an unknown kind
    def agent_pane_command(kind, workspace = nil)
      return unless AgentProvider.find(kind)
      command = configured_command(kind, workspace)
      return command unless kind == "claude"
      return unless File.exist?(@config.worktree_template_path)
      line = template_claude_line(workspace)
      line && claude_line(line, command, claude_names(workspace))
    end

    # +text+ with the program of each `||` half that runs a Claude Code program swapped for the configured
    # command, flags kept: the same half rewrite as {#agent_pane_command} and {#rewrite_agent_pane}. A half
    # that already starts with the configured command is left as written, so a command with extra words
    # (`mycl --flag`) is applied once however many times a line is passed through. Only `claude` has a
    # program to swap; any other kind returns +text+.
    #
    # @param text [String] a pane command, or one part of it
    # @param kind [String] an {AgentProvider} key
    # @param workspace [String, nil] the workspace whose config layers pick the command
    # @return [String]
    def with_configured_program(text, kind, workspace = nil)
      return text unless kind == "claude"
      command = configured_command(kind, workspace)
      return text unless command
      wanted = command.split
      names = claude_names(workspace)
      text.split(" || ").map do |half|
        words = half.split
        (words.first(wanted.size) == wanted) ? half : claude_line(half, command, names)
      end.join(" || ")
    end

    # Points the agent pane line of a tmuxinator config at the configured command for a kind. The line is
    # found whether it runs the template's `claude --dangerously-skip-permissions ...` or a command already
    # written for any kind (a program of {AgentCommands#names_for}). For `claude` a line that already runs a
    # Claude Code program keeps its flags (none are added) and only the program changes in each half of a
    # `||` chain that runs one; a line of another agent takes the template's Claude Code line; for another
    # kind the line becomes the command.
    #
    # @param content [String] a tmuxinator config
    # @param kind [String] an {AgentProvider} key
    # @param workspace [String, nil] the workspace whose config layers pick the command
    # @return [String, nil] the new content; nil when no agent pane line is found (or, for `claude` over a
    #   line of another agent, the template has no Claude Code pane to take the flags from)
    def rewrite_agent_pane(content, kind, workspace = nil)
      return unless AgentProvider.find(kind)
      command = configured_command(kind, workspace)
      names = agent_program_names(workspace)
      lines = content.lines
      index = lines.index { |line| (item = pane_item(line)) && agent_pane_text?(item[1], names) }
      return unless index
      indent, text = pane_item(lines[index])
      pane = if kind == "claude"
        claude = claude_names(workspace)
        base = runs_program?(text.split(" || ").first, claude) ? text : template_claude_line(workspace)
        return unless base
        claude_line(base, command, claude)
      else
        command
      end
      lines[index] = "#{indent}#{yaml_item(pane)}#{lines[index][/\r?\n\z/]}"
      lines.join
    end

    # Whether a workspace's tmuxinator config has an agent pane that runs another program than the
    # configured command for +kind+, with the config as {#rewrite_agent_pane} would write it.
    #
    # @param workspace [String]
    # @param kind [String] an {AgentProvider} key; "none" is never stale
    # @return [Hash, nil] `path`, `running` and `wanted` (programs) and `content`; nil when the pane is
    #   current, none is found, or the config can't be read
    def stale_agent_pane(workspace, kind)
      return if kind == "none"
      path = config_path_for(workspace)
      content = File.read(path)
      rewritten = rewrite_agent_pane(content, kind, workspace)
      return unless rewritten && rewritten != content
      running, wanted = changed_pane_programs(content, rewritten)
      return if running.nil? || wanted.nil? || running == wanted
      {path: path, running: running, wanted: wanted, content: rewritten}
    rescue SystemCallError, IOError, Psych::Exception
      nil
    end

    # Writes a config through a temp file and rename.
    #
    # @param path [String]
    # @param content [String]
    def write_config(path, content)
      tmp = "#{path}.tmp#{Process.pid}"
      File.write(tmp, content)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    private

    # @return [Array<String, nil>] the programs of the one pane line that differs between two contents:
    #   the first `||` half whose program changed, else the first half
    def changed_pane_programs(before, after)
      old_line, new_line = before.lines.zip(after.lines).find { |old, new| old != new }
      pairs = pane_programs(old_line).zip(pane_programs(new_line))
      first = pairs.first || [nil, nil]
      return first if first.any?(&:nil?)
      pairs.find { |old, new| old && new && old != new } || first
    end

    def pane_programs(line)
      item = YAML.safe_load(line.to_s.strip)&.first
      item.is_a?(String) ? item.split(" || ").map { |half| AgentCommands.program_for(half) } : [nil]
    rescue Psych::Exception
      [nil]
    end

    # @return [Array(String, String), nil] the indent and the text of a YAML list item line, a quoted
    #   scalar read back to its value
    def pane_item(line)
      match = line.match(/\A(\s*- )(\S.*?)\r?\n?\z/)
      return unless match
      text = match[2]
      value = begin
        YAML.safe_load("- #{text}")&.first
      rescue Psych::Exception
        nil
      end
      [match[1], value.is_a?(String) ? value : text]
    end

    def flagged_pane?(text)
      text.start_with?("claude --dangerously-skip-permissions")
    end

    def agent_pane_text?(text, names)
      return true if flagged_pane?(text)
      program = AgentCommands.program_for(text.split(" || ").first)
      !program.nil? && names.include?(program)
    end

    def agent_program_names(workspace)
      AgentProvider.all.flat_map do |provider|
        (workspace && @agent_commands) ? @agent_commands.names_for(workspace, provider.key) : [provider.executable]
      end.uniq
    end

    # The text of the worktree template's Claude Code pane, looking only at pane items from the first
    # `panes:` line on: the item with the skip-permissions flag anywhere in the file, else the first item
    # whose `||` chain runs a program of {#claude_names} in any half (unlike {#agent_pane_text?}, which
    # reads the first half only). With no workspace (or no {AgentCommands}) those names are the bare
    # executable, so `claude-dev --continue || claude` is found through its second half.
    def template_claude_line(workspace)
      return unless File.exist?(@config.worktree_template_path)
      lines = File.readlines(@config.worktree_template_path)
      start = lines.index { |line| line.match?(/\A\s*(- )?panes:/) }
      return unless start
      texts = lines[start..].filter_map { |line| pane_item(line)&.at(1)&.strip }
      names = claude_names(workspace)
      texts.find { |text| flagged_pane?(text) } || texts.find { |text| runs_program?(text, names) }
    end

    # +line+ with the program of each `||` half that runs one of +names+ swapped for +command+; flags and
    # halves that run another program (a fallback `echo failed`) stay as written.
    def claude_line(line, command, names)
      line.split(" || ").map do |half|
        next half unless runs_program?(half, names)
        words = raw_words(half)
        words[words.size - AgentCommands.program_words(half).size] = command
        words.join(" ")
      end.join(" || ")
    end

    def runs_program?(text, names)
      text.split(" || ").any? { |half| (program = AgentCommands.program_for(half)) && names.include?(program) }
    end

    def claude_names(workspace)
      (workspace && @agent_commands) ? @agent_commands.names_for(workspace, "claude") : [AgentProvider.find("claude").executable]
    end

    # The words of +text+ as written (quotes and escapes kept), counted the way {AgentCommands.program_words} does.
    def raw_words(text)
      raw = text.scan(/(?:[^\s\\'"]|\\.|'[^']*'|"(?:[^"\\]|\\.)*")+/)
      (raw.size == Shellwords.split(text).size) ? raw : text.split
    rescue ArgumentError
      text.split
    end

    # A YAML list item's text: plain when that reads back as the same string, else a double-quoted
    # scalar, so any command (`#`, `: `, quotes) keeps the config valid.
    def yaml_item(text)
      (YAML.safe_load("- #{text}") == [text]) ? text : text.to_json
    rescue Psych::Exception
      text.to_json
    end

    # Points the config's agent pane at the configured command. A config with no agent pane line is
    # left as is: `strict` raises for a kind other than claude, else a warning says so when something
    # was configured.
    def with_agent_kind(content, kind, workspace, strict: true)
      command = configured_command(kind, workspace)
      default = command == AgentProvider.find(kind)&.executable
      return content if kind == "claude" && default
      rewritten = rewrite_agent_pane(content, kind, workspace)
      return rewritten if rewritten
      if strict && kind != "claude"
        raise Workspace::Error, "The worktree template has no Claude Code pane to swap for #{kind}; run `workspace init --force` to refresh it."
      end
      unless default && kind == "claude"
        key = default ? "agent.kind" : "agent.commands.#{kind}"
        @output.puts "Warning: #{key} is set, but the template has no agent pane line to rewrite; the pane was left as is."
      end
      content
    end

    def default_kind(workspace)
      @agent_commands ? @agent_commands.kind(workspace) : ConfigSchema.default("agent.kind")
    end

    def configured_command(kind, workspace)
      (workspace && @agent_commands) ? @agent_commands.command_for(workspace, kind) : AgentProvider.find(kind)&.executable
    end

    def same_directory?(first, second)
      return false if first.nil? || second.nil?

      File.realpath(first) == File.realpath(second)
    rescue SystemCallError
      File.expand_path(first) == File.expand_path(second)
    end

    def read_project_root(name)
      path = config_path_for(name)
      return nil unless File.exist?(path)

      require "yaml"
      config = YAML.safe_load_file(path)
      config&.dig("root")
    rescue Psych::Exception
      nil
    end
  end
end
