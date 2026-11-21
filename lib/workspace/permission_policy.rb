module Workspace
  # Decides whether a coding agent's tool call is allowed, asked about or denied,
  # from ordered layers of rules. Pure: it reads the files a path rule names only
  # to resolve symlinks, and changes nothing.
  #
  # Matching:
  # - A rule's `tool` is a `File.fnmatch` glob over the tool name, with no flags.
  # - A rule with no `pattern` matches on the tool alone.
  # - For Bash the pattern is matched against each piece of the command
  #   ({BashCommandPieces}) with `File::FNM_DOTMATCH`. A command that is missing
  #   or not a String matches no pattern.
  # - For Edit, Write, MultiEdit, NotebookEdit and Read the pattern is matched
  #   against the path (`notebook_path` for NotebookEdit, else `file_path`, expanded against the
  #   working directory) with `FNM_PATHNAME | FNM_DOTMATCH`; a pattern starting
  #   with `~` is expanded first. `deny` and `ask` match when the path or its
  #   symlink-resolved form matches; `allow` needs both to match.
  # - Any other tool has no subject, so a rule with a pattern never matches it.
  #
  # Precedence: any matching `deny` wins, then any `ask`, then any `allow`. With
  # no match, the most restrictive layer `default` applies, and `ask` when none
  # is set.
  #
  # A Bash `allow` by pattern counts only when every piece, as written or without
  # its harmless wrappers (`timeout 5`, `nice`), matches an allow rule, and never for a command with a substitution, a file redirection
  # or an opaque command word (quoted, `eval`, `sh -c`, `if`, `{`...). That one
  # gets `deny` when a deny rule matches or the default is `deny`, and `ask`
  # otherwise, whatever the default says. `deny` and `ask` also match each
  # piece with its quotes and escapes removed. An allow rule with no
  # pattern on Bash still allows the whole tool.
  class PermissionPolicy
    ACTIONS = %w[allow ask deny].freeze
    PATH_TOOLS = %w[Edit Write MultiEdit NotebookEdit Read].freeze
    MAX_LINK_DEPTH = 40

    # The tools a rule's `pattern` can match against: Bash and the path tools.
    SUBJECT_TOOLS = (%w[Bash] + PATH_TOOLS).freeze

    private_constant :ACTIONS, :PATH_TOOLS, :MAX_LINK_DEPTH

    # What the policy looks at in one tool call.
    Subject = Struct.new(:kind, :command, :pieces, :raw_pieces, :unsafe, :forms, :grouped)
    private_constant :Subject

    # @param layers [Array<Hash>] in order, each `{source:, rules:, default:}`; source is
    #   `global`, `project`, `worktree` or `run`, rules are validated `{tool, pattern, action}` hashes
    # @param command_pieces [BashCommandPieces] cuts Bash commands
    def initialize(layers:, command_pieces: BashCommandPieces.new)
      @layers = layers
      @command_pieces = command_pieces
    end

    # @param tool_name [String] the tool the agent wants to call
    # @param tool_input [Hash, nil] its input
    # @param cwd [String, nil] the agent's working directory, for relative paths
    # @return [Hash] `{action:, rule:}` where action is `"allow"`, `"ask"` or `"deny"` and rule names the
    #   deciding rule such as `project:rules[2]` or `global:default`
    def decide(tool_name:, tool_input:, cwd:)
      name = tool_name.to_s
      subject = subject_for(name, tool_input.is_a?(Hash) ? tool_input : {}, cwd)
      candidates = candidate_rules(name)
      covered = covered?(candidates, subject)
      matches = candidates.filter_map do |rule, label|
        action = rule_value(rule, :action).to_s
        raise ArgumentError, "unknown action #{action.inspect}" unless ACTIONS.include?(action)
        next unless rule_matches?(rule, action, subject)
        next if action == "allow" && !rule_value(rule, :pattern).nil? && subject.kind == :bash && !covered
        [action, label]
      end
      ACTIONS.reverse_each do |action|
        found = matches.find { |matched, _| matched == action }
        return {action: action, rule: found.last} if found
      end
      fallback(subject)
    end

    private

    def candidate_rules(tool_name)
      @layers.flat_map do |layer|
        list = (layer[:rules] || []).each_with_index.to_a
        list.select { |rule, _| File.fnmatch(rule_value(rule, :tool).to_s, tool_name) }.map do |rule, index|
          [rule, "#{layer[:source]}:#{(layer[:source].to_s == "run") ? "permissions" : "rules"}[#{index}]"]
        end
      end
    end

    def literal_tilde(path)
      (path == "~" || path.start_with?("~/") || !path.start_with?("~")) ? path : "./#{path}"
    end

    def rule_value(rule, key)
      rule.key?(key) ? rule[key] : rule[key.to_s]
    end

    def subject_for(name, input, cwd)
      if name == "Bash"
        command = input["command"] || input[:command]
        return Subject.new(:bash, nil, nil, nil, true) unless command.is_a?(String)
        raw = @command_pieces.raw_pieces(command)
        Subject.new(:bash, command, (@command_pieces.pieces(command) + raw + @command_pieces.unquoted_pieces(command)).uniq, raw,
          @command_pieces.substitution?(command) || @command_pieces.redirect?(command) || @command_pieces.opaque?(command),
          nil, raw.map { |piece| [piece, @command_pieces.unwrapped(piece)].uniq })
      elsif PATH_TOOLS.include?(name)
        key = (name == "NotebookEdit") ? "notebook_path" : "file_path"
        path = input[key] || input[key.to_sym]
        return Subject.new(:path) unless path.is_a?(String) && !path.empty?
        base = cwd.is_a?(String) ? cwd : Dir.pwd
        expanded = File.expand_path(literal_tilde(path), base)
        Subject.new(:path, nil, nil, nil, nil, [expanded, resolve(expanded, 0)])
      else
        Subject.new(:none)
      end
    end

    def rule_matches?(rule, action, subject)
      pattern = rule_value(rule, :pattern)
      return true if pattern.nil?
      pattern = pattern.to_s
      case subject.kind
      when :bash
        return false unless subject.command
        if action == "allow"
          !subject.unsafe && subject.grouped.flatten.any? { |piece| File.fnmatch(pattern, piece, File::FNM_DOTMATCH) }
        else
          subject.pieces.any? { |piece| File.fnmatch(pattern, piece, File::FNM_DOTMATCH) }
        end
      when :path
        return false unless subject.forms
        expanded, resolved = subject.forms
        pattern = File.expand_path(pattern) if pattern == "~" || pattern.start_with?("~/")
        flags = File::FNM_PATHNAME | File::FNM_DOTMATCH
        if action == "allow"
          !resolved.nil? && File.fnmatch(pattern, expanded, flags) && File.fnmatch(pattern, resolved, flags)
        else
          [expanded, resolved].compact.any? { |form| File.fnmatch(pattern, form, flags) }
        end
      else
        false
      end
    end

    # A Bash allow by pattern holds only when every piece as written matches some allow pattern.
    def covered?(candidates, subject)
      return false unless subject.kind == :bash && subject.command && !subject.unsafe && subject.raw_pieces.any?
      patterns = candidates.filter_map do |rule, _|
        rule_value(rule, :pattern).to_s if rule_value(rule, :action).to_s == "allow" && !rule_value(rule, :pattern).nil?
      end
      subject.grouped.all? { |forms| forms.any? { |piece| patterns.any? { |pattern| File.fnmatch(pattern, piece, File::FNM_DOTMATCH) } } }
    end

    def fallback(subject)
      layer_default = most_restrictive_default
      return {action: "ask", rule: "default"} unless layer_default
      action, label = layer_default
      action = "ask" if action == "allow" && subject.kind == :bash && subject.unsafe
      {action: action, rule: label}
    end

    def most_restrictive_default
      defaults = @layers.filter_map do |layer|
        value = layer[:default]
        next if value.nil?
        raise ArgumentError, "unknown default #{value.inspect}" unless ACTIONS.include?(value.to_s)
        [value.to_s, "#{layer[:source]}:default"]
      end
      defaults.max_by { |action, _| ACTIONS.index(action) }
    end

    def resolve(path, depth)
      return nil if depth > MAX_LINK_DEPTH
      head = path
      tail = []
      loop do
        return File.join(File.realpath(head), *tail)
      rescue Errno::ENOENT, Errno::ENOTDIR
        if File.symlink?(head)
          target = File.expand_path(File.readlink(head), File.dirname(head))
          return resolve(File.join(target, *tail), depth + 1)
        end
        parent = File.dirname(head)
        return nil if parent == head
        tail.unshift(File.basename(head))
        head = parent
      end
    rescue SystemCallError
      nil
    end
  end
end
