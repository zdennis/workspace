require "digest"
require "shellwords"
require "yaml"

module Workspace
  # Manages tmuxinator config file generation for projects and worktrees.
  class ProjectConfig
    # The Claude Code pane line a new config runs: what the shipped templates held before they took
    # `{{AGENT_COMMAND}}`, and the base {#agent_pane_value} swaps the configured program into.
    DEFAULT_CLAUDE_PANE = "claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions".freeze

    # @param config [Workspace::Config] configuration for path lookups
    # @param git [Workspace::Git] git operations for sanitize_for_filesystem
    # @param output [IO] output stream for user-facing messages
    # @param agent_commands [Workspace::AgentCommands, nil] the configured agent kind and commands; nil
    #   writes each agent's bare executable
    # @param writer [Workspace::TmuxinatorConfigWriter, nil] writes each new config and its render record;
    #   nil builds one over +config+
    # @param library [#call, nil] answers the {Workspace::Library} that resolves each tmuxinator
    #   template ({Library#tmuxinator_template}); a callable, since the Library reads this object to
    #   know which workspaces exist. nil builds a Library over +config+ and this object, with no
    #   template set configured
    def initialize(config:, git:, output: $stdout, agent_commands: nil, writer: nil, library: nil)
      @config = config
      @writer = writer || TmuxinatorConfigWriter.new(config: config)
      @library = library
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
    # @raise [Workspace::Error] code `unknown_template` or `library_source_missing` when the
    #   tmuxinator template can't be resolved (see {Library#tmuxinator_template})
    # @raise [Workspace::Error] code `workspace_name_case_conflict` (see {#settle_new_name})
    def create(name, root)
      name = settle_new_name(name, root)
      config_path = @config.config_path_for(name)
      if File.exist?(config_path)
        @output.puts "Config already exists: #{config_path}"
        return name
      end

      write_new(name, :project, {
        project_name: name, workspace_name: name, project_root: root,
        display_name: banner_text(name), config_path: config_path,
        agent_kind: default_kind(name)
      }, tmuxinator_template(:project, name))
      @output.puts "Created config: #{config_path}"
      name
    end

    # Fills a tmuxinator template: no file is read or written (a warning may go to the output stream).
    #
    # @param kind [Symbol] `:project` or `:worktree`; a worktree is strict about the agent pane
    # @param inputs [Hash] the placeholder values by lowercase symbol (`project_name`, `workspace_name`,
    #   `project_root`, `display_name`, `config_path`, `tmux_session_name`, `worktree_path`,
    #   `worktree_branch`), plus `task_id` (nil drops the `{{PRE_WINDOW}}` line) and `agent_kind`
    #   (an {AgentProvider} key; the workspace its config layers read is `workspace_name`)
    # @param template_text [String]
    # @return [String] the config text
    # @raise [Workspace::Error] for a worktree and an agent kind the template has no pane to swap for, or a
    #   input that is nil while the template holds its placeholder (the whole-line `{{PRE_WINDOW}}` is dropped instead)
    def render(kind, inputs, template_text)
      content = template_text.dup
      has_agent_placeholder = content.include?("{{AGENT_COMMAND}}")
      inputs = with_agent_command(kind, inputs) if has_agent_placeholder
      TemplateVariables::ROWS.each do |row|
        next unless row.fill == :value
        value = inputs[row.input]
        if value
          content = content.gsub("{{#{row.name}}}") { value }
        elsif content.include?("{{#{row.name}}}")
          raise Workspace::Error, "Cannot render the #{kind} template: no value for #{row.name}"
        end
      end
      if kind == :worktree
        task_id = inputs[:task_id]
        content = content.sub(/^\{\{PRE_WINDOW\}\}\n/) { task_id ? "pre_window: export WORKSPACE_TASK=#{task_id}\n" : "" }
      end
      return content if has_agent_placeholder # the placeholder already holds the configured pane, which replaces with_agent_kind
      with_agent_kind(content, inputs[:agent_kind], inputs[:workspace_name], strict: kind == :worktree)
    end

    # The agent pane text {#render} writes for `{{AGENT_COMMAND}}`: for `claude` {DEFAULT_CLAUDE_PANE} with
    # the configured program swapped in (flags kept), for another kind the bare configured command.
    #
    # @param kind [String] an {AgentProvider} key
    # @param workspace [String, nil] the workspace whose config layers pick the command
    # @return [String, nil] nil for an unknown kind
    def agent_pane_value(kind, workspace = nil)
      pane_value(kind, workspace, DEFAULT_CLAUDE_PANE)
    end

    # @param project_name [String] parent project name
    # @param worktree_name [String] worktree directory name
    # @return [String] the tmux session name {#create_worktree} gives that worktree
    def worktree_session_name(project_name, worktree_name)
      "#{project_name}.wt-#{@git.sanitize_for_filesystem(worktree_name)}".tr(".", "-").downcase
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
    # @raise [Workspace::Error] code `unknown_template` or `library_source_missing` when the
    #   tmuxinator template can't be resolved (see {Library#tmuxinator_template})
    def create_worktree(project_name, worktree_name, worktree_path, branch_name, quiet: false, task_id: nil, agent_kind: nil)
      project_name = WorkspaceName.normalize(project_name)
      tmux_session_name = worktree_session_name(project_name, worktree_name)
      config_name = settle_worktree_name(project_name, worktree_name, worktree_path)
      config_path = @config.config_path_for(config_name)

      if File.exist?(config_path)
        @output.puts "Config already exists: #{config_path}" unless quiet
        return config_name
      end

      write_new(config_name, :worktree, {
        tmux_session_name: tmux_session_name, workspace_name: config_name, worktree_path: worktree_path,
        project_name: project_name, worktree_branch: branch_name,
        display_name: banner_text("#{project_name}/#{worktree_name}"), config_path: config_path,
        task_id: task_id, agent_kind: agent_kind || default_kind(config_name)
      }, tmuxinator_template(:worktree, config_name))
      @output.puts "Created config: #{config_path}" unless quiet
      config_name
    end

    # Deletes the config and its render record (with no config, a record left behind goes too). A record
    # that can't be deleted is left behind rather than failing a remove whose config is already gone.
    #
    # @param name [String] project or config name
    # @param quiet [Boolean] print nothing to the output stream
    # @return [void]
    def remove(name, quiet: false)
      path = config_path_for(name)
      if File.exist?(path)
        File.delete(path)
        @output.puts "Removed config: #{path}" unless quiet
      end
      begin
        @writer.remove_record(name)
      rescue SystemCallError
        nil
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
        "Can't create workspace '#{wanted}': workspace '#{existing}' (#{existing_root || "root unknown"}) already exists and differs only in case, " \
        "and the two would share config and state files on a disk that ignores case. " \
        "If you meant that workspace, use '#{existing}' (see `workspace list`); otherwise use a directory with a different name.",
        code: "workspace_name_case_conflict",
        details: {"name" => wanted, "existing" => existing, "existing_root" => existing_root}
      )
    end

    # @param project_name [String] parent project name
    # @param worktree_name [String] worktree directory name
    # @param worktree_path [String] full path to the worktree
    # @return [String] the config name a worktree gets: {WorkspaceName.join} of the project and the sanitized directory name, settled by {#settle_new_name}
    # @raise [Workspace::Error] code `workspace_name_case_conflict`
    def settle_worktree_name(project_name, worktree_name, worktree_path)
      settle_new_name(WorkspaceName.join(project_name, @git.sanitize_for_filesystem(worktree_name)), worktree_path)
    end

    # @return [String, nil] the config name that matches +name+ ignoring case, the exact spelling first
    def existing_name(name)
      projects = available_projects
      projects.find { |other| other == name } || projects.find { |other| WorkspaceName.same?(other, name) }
    end

    # Refuses an agent kind the resolved worktree template cannot take, so `start` fails before it
    # creates anything.
    #
    # @param kind [String] an {AgentProvider} key
    # @param workspace [String, nil] the workspace whose configured Claude Code command the template may
    #   run, and whose layers pick the template
    # @raise [Workspace::Error] code `template_outdated` when the template has no Claude Code pane to swap,
    #   or `unknown_template`/`library_source_missing` when it can't be resolved
    def check_agent_kind!(kind, workspace = nil)
      return if kind == "claude"
      return if template_claude_line(workspace, tmuxinator_template(:worktree, workspace))
      raise Workspace::Error.new("The worktree tmuxinator template has no Claude Code pane to swap for #{kind}; check it with `workspace template validate`, or replace it with `workspace template import`.",
        code: "template_outdated", details: {"kind" => kind})
    end

    # The pane command a new config runs for an agent kind: for `claude` the resolved worktree
    # template's Claude Code pane with `claude` swapped for the configured command in each half of its
    # `||` chain, else the configured command (the agent's executable when none is set).
    #
    # @param kind [String] an {AgentProvider} key
    # @param workspace [String, nil] the workspace whose config layers pick the command; nil, or no
    #   {AgentCommands} wired, means the agent's executable
    # @return [String, nil] nil for `claude` when the template has no Claude Code pane or can't be
    #   resolved, or for an unknown kind
    def agent_pane_command(kind, workspace = nil)
      return unless AgentProvider.find(kind)
      return configured_command(kind, workspace) unless kind == "claude"
      line = template_claude_line(workspace)
      line && pane_value(kind, workspace, line)
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
      lines[index] = "#{indent}#{self.class.yaml_item(pane)}#{lines[index][/\r?\n\z/]}"
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

    # The agent pane's text in a config: the first pane item that runs an agent program.
    #
    # @param content [String] a tmuxinator config
    # @param workspace [String, nil] the workspace whose config layers name the agent programs
    # @return [String, nil] nil when no agent pane is found
    def agent_pane_text(content, workspace)
      names = agent_program_names(workspace)
      content.lines.each do |line|
        item = pane_item(line)
        return item[1] if item && agent_pane_text?(item[1], names)
      end
      nil
    end

    # ascii-banner wraps only at whitespace, so an unspaced name shrinks to tiny type.
    #
    # @param text [String]
    # @return [String] the text the templates' banner line shows
    def banner_text(text)
      text.gsub(/[^[:word:]]/, " ")
    end

    # Whether the template file at +path+ has an agent pane the renderer can find: `{{AGENT_COMMAND}}` or a
    # literal Claude Code line.
    #
    # @param path [String] a template file
    # @return [Boolean]
    def agent_pane_in_template?(path)
      !template_claude_line(nil, {"path" => path}).nil?
    end

    # +text+ as a YAML list item's text: as is when it reads back unchanged, else a JSON (double-quoted) string.
    #
    # @param text [String]
    # @return [String]
    def self.yaml_item(text)
      (YAML.safe_load("- #{text}") == [text]) ? text : text.to_json
    rescue Psych::Exception
      text.to_json
    end

    private

    # Renders and writes a new config with its render record. Beside the render inputs the record keeps
    # `agent_command`, the agent pane text the render wrote (nil when it found no agent pane), since the
    # render reads the configured command from the config layers rather than from +inputs+.
    # The record's `template` is the resolved set's name (`legacy` for an edited installed copy).
    def write_new(name, kind, inputs, template)
      template_text = File.read(template["path"])
      content = render(kind, inputs, template_text)
      @writer.write(name, content, kind: kind, template: template["name"], template_sha: Digest::SHA256.hexdigest(template_text),
        inputs: inputs.merge(agent_command: agent_pane_text(content, name)))
    end

    # @return [Hash] see {Library#tmuxinator_template}
    def tmuxinator_template(kind, workspace)
      library.tmuxinator_template(kind, workspace: workspace)
    end

    # The fallback Library has no lineage: the tmuxinator template lookup never reads it.
    def library
      @library ? @library.call : (@own_library ||= Library.new(config: @config, lineage: nil, project_config: self))
    end

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

    # +inputs+ with `agent_command` filled for the template's `{{AGENT_COMMAND}}` (one a caller gave stays);
    # an unknown kind leaves it nil, so a worktree raises the swap error as {#with_agent_kind} does, and a
    # project gets the default pane with that method's warning.
    def with_agent_command(kind, inputs)
      return inputs if inputs[:agent_command]
      configured_command(inputs[:agent_kind], inputs[:workspace_name]) # raises for an unknown kind where {AgentCommands} is wired, as {#with_agent_kind} does
      value = agent_pane_value(inputs[:agent_kind], inputs[:workspace_name])
      if value.nil?
        if kind == :worktree
          raise Workspace::Error, "The worktree tmuxinator template has no Claude Code pane to swap for #{inputs[:agent_kind]}; check it with `workspace template validate`, or replace it with `workspace template import`."
        end
        @output.puts "Warning: agent.kind is set, but the template has no agent pane line to rewrite; the pane was left as is."
        value = DEFAULT_CLAUDE_PANE
      end
      inputs.merge(agent_command: self.class.yaml_item(value))
    end

    def pane_value(kind, workspace, base)
      return unless AgentProvider.find(kind)
      command = configured_command(kind, workspace)
      (kind == "claude") ? claude_line(base, command, claude_names(workspace)) : command
    end

    # The text of the worktree template's Claude Code pane, looking only at pane items from the first
    # `panes:` line on: the item with the skip-permissions flag anywhere in the file, else the first item
    # whose `||` chain runs a program of {#claude_names} in any half (unlike {#agent_pane_text?}, which
    # reads the first half only). With no workspace (or no {AgentCommands}) those names are the bare
    # executable, so `claude-dev --continue || claude` is found through its second half.
    # A template whose pane items include `{{AGENT_COMMAND}}` answers {DEFAULT_CLAUDE_PANE}. The template
    # is +template+, else the worktree template resolved for +workspace+; nil when that can't be
    # resolved or read.
    def template_claude_line(workspace, template = nil)
      lines = begin
        File.readlines((template || tmuxinator_template(:worktree, workspace))["path"])
      rescue Workspace::Error, SystemCallError
        return
      end
      start = lines.index { |line| line.match?(/\A\s*(- )?panes:/) }
      return unless start
      texts = lines[start..].filter_map { |line| pane_item(line)&.at(1)&.strip }
      return DEFAULT_CLAUDE_PANE if texts.include?("{{AGENT_COMMAND}}")
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
        raise Workspace::Error, "The worktree tmuxinator template has no Claude Code pane to swap for #{kind}; check it with `workspace template validate`, or replace it with `workspace template import`."
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
