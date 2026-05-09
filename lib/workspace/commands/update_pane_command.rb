require "yaml"

module Workspace
  module Commands
    # Updates a pane's shell command in a project's tmuxinator config file.
    # Supports replacing an existing pane or appending a new one.
    class UpdatePaneCommand
      # @param config [Workspace::Config] configuration for path lookups
      # @param project_config [Workspace::ProjectConfig] project config management
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      def initialize(config:, project_config:, output: $stdout, input: $stdin)
        @config = config
        @project_config = project_config
        @output = output
        @input = input
      end

      # Updates the command for a specific pane in the project's tmuxinator config.
      #
      # @param project [String] project name
      # @param command [String] shell command to set for the pane
      # @param pane_index [Integer] 1-based pane index
      # @return [void]
      # @raise [Workspace::UsageError] on invalid input
      # @raise [Workspace::Error] on missing or unreadable config
      def call(project:, command:, pane_index:)
        validate!(project, pane_index)

        config_path = @config.config_path_for(project)
        raise Workspace::Error, "Tmuxinator config not found: #{config_path}" unless File.exist?(config_path)

        raw = File.read(config_path)
        doc = YAML.safe_load(raw)
        panes = extract_panes(doc, config_path)

        pane_count = panes.size
        adjusted_index = pane_index - 1

        if adjusted_index >= pane_count
          @output.print "\nPane #{pane_index} does not exist (project has #{pane_count} pane(s)). " \
            "Add a new pane with command #{command.inspect}? [y/N] "
          answer = @input.gets&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            @output.puts "Cancelled."
            return
          end
          adjusted_index = pane_count
        end

        updated_raw = update_pane_in_raw(raw, adjusted_index, command)
        File.write(config_path, updated_raw)

        updated_doc = YAML.safe_load(updated_raw)
        updated_panes = extract_panes(updated_doc, config_path)
        print_pane_summary(project, updated_panes)
      end

      private

      def validate!(project, pane_index)
        raise Workspace::UsageError, "No project name provided. Usage: workspace set-command <project> <command> --pane <N>" unless project
        raise Workspace::UsageError, "Project '#{project}' not found. Run 'workspace list --all' to see available projects." unless @project_config.exists?(project)
        raise Workspace::UsageError, "No pane index provided. Use --pane <N> (e.g. --pane 2)." if pane_index.nil?
        raise Workspace::UsageError, "Pane index must be 1 or greater (got #{pane_index})." if pane_index < 1
      end

      def extract_panes(doc, config_path)
        windows = doc&.dig("windows")
        raise Workspace::Error, "Could not parse tmuxinator config: #{config_path}" unless windows.is_a?(Array) && !windows.empty?

        window = windows.first
        panes = window.is_a?(Hash) ? window.values.first&.dig("panes") : nil
        raise Workspace::Error, "Could not find panes in tmuxinator config: #{config_path}" unless panes.is_a?(Array)

        panes
      end

      # Rewrites a single pane entry in the raw YAML text to preserve all other
      # formatting and comments. For appending, adds a new pane line after the last.
      def update_pane_in_raw(raw, adjusted_index, command)
        lines = raw.lines
        pane_starts = find_pane_line_indices(lines)

        raise Workspace::Error, "Could not locate pane entries in config file." if pane_starts.empty?

        if adjusted_index < pane_starts.size
          replace_pane(lines, pane_starts, adjusted_index, command)
        else
          append_pane(lines, pane_starts, command)
        end
      end

      # Returns array of line indices where each pane begins (the "- " list item under panes:).
      # Assumes a single panes: block, indented under a window definition.
      def find_pane_line_indices(lines)
        in_panes = false
        pane_indent = nil
        pane_starts = []

        lines.each_with_index do |line, i|
          if !in_panes && line.match?(/^\s+panes:\s*$/)
            in_panes = true
            next
          end

          next unless in_panes

          stripped = line.lstrip
          indent = line.length - stripped.length

          if pane_indent.nil? && stripped.start_with?("- ")
            pane_indent = indent
          end

          next unless pane_indent

          if indent == pane_indent && stripped.start_with?("- ")
            pane_starts << i
          elsif indent < pane_indent && !stripped.empty?
            break
          end
        end

        pane_starts
      end

      def replace_pane(lines, pane_starts, adjusted_index, command)
        start_line = pane_starts[adjusted_index]
        end_line = pane_starts[adjusted_index + 1] || find_panes_end(lines, pane_starts.last)

        indent = " " * (lines[start_line].length - lines[start_line].lstrip.length)
        new_pane_lines = build_pane_lines(command, indent)

        lines[start_line...end_line] = new_pane_lines
        lines.join
      end

      def append_pane(lines, pane_starts, command)
        last_start = pane_starts.last
        end_line = find_panes_end(lines, last_start)
        indent = " " * (lines[last_start].length - lines[last_start].lstrip.length)
        new_pane_lines = build_pane_lines(command, indent)

        lines.insert(end_line, *new_pane_lines)
        lines.join
      end

      # Returns the line index just after the last pane block ends.
      def find_panes_end(lines, last_pane_start)
        pane_indent = lines[last_pane_start].length - lines[last_pane_start].lstrip.length
        i = last_pane_start + 1
        while i < lines.size
          line = lines[i]
          stripped = line.lstrip
          indent = line.length - stripped.length
          break if !stripped.empty? && indent <= pane_indent && !stripped.start_with?("- ")
          i += 1
        end
        i
      end

      # Emits a properly-escaped YAML pane entry. Multi-line commands use a block
      # scalar; single-line commands use the YAML library to quote only when needed
      # (handles shell metacharacters like &&, ||, quotes, colons safely).
      def build_pane_lines(command, indent)
        if command.include?("\n")
          ["#{indent}- |\n"] + command.lines.map { |l| "#{indent}  #{l.chomp}\n" }
        else
          # YAML.dump(["cmd"]) produces "---\n- cmd\n"; extract just the scalar.
          scalar = YAML.dump([command]).lines.drop(1).first.sub(/^- /, "").rstrip
          ["#{indent}- #{scalar}\n"]
        end
      end

      def print_pane_summary(project, panes)
        @output.puts "\nProject: #{project}"
        @output.puts "Pane configuration:"
        panes.each_with_index do |pane, i|
          display = pane.is_a?(String) ? pane.strip.lines.first&.strip : pane.inspect
          @output.puts "  [#{i + 1}] #{display}"
        end
      end
    end
  end
end
