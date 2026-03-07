module Workspace
  module Commands
    # Resizes tmux panes for a running workspace project.
    # Accepts a comma-separated spec of sizes (rows or percentages).
    class Resize
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] output stream for user-facing messages
      def initialize(tmux:, layout_command: nil, output: $stdout, error_output: $stderr)
        @tmux = tmux
        @layout_command = layout_command
        @output = output
        @error_output = error_output
      end

      # Resizes panes for the given project according to the size spec.
      #
      # @param project [String] project/config name
      # @param spec [String] comma-separated pane sizes (e.g. "15%,,35%" or "10,80%,20%")
      # @return [void]
      # @raise [Workspace::Error] if project has no active tmux session
      def call(project, spec)
        session_name = @tmux.session_name_for(project)
        unless @tmux.sessions.include?(session_name)
          raise Workspace::Error, "No active tmux session for '#{project}'.\nRun 'workspace launch #{project}' to start it."
        end

        @layout_command&.auto_save(project, "_before_resize")

        sizes = parse_spec(spec)
        if sizes.empty?
          raise Workspace::Error, "No pane sizes specified."
        end

        sizes.each do |pane_index, size|
          pane_target = "0.#{pane_index}"
          if @tmux.resize_pane(session_name, pane_target, size)
            @output.puts "  Pane #{pane_index} → #{size}"
          else
            @error_output.puts "Warning: Failed to resize pane #{pane_index}"
          end
        end
      end

      private

      # Parses a comma-separated spec into a hash of {pane_index => size_string}.
      # Empty entries are skipped (auto/remainder).
      # Entries like "10" or "10h" become row counts; "50%" stays as-is.
      def parse_spec(spec)
        parts = spec.split(",", -1)
        result = {}
        parts.each_with_index do |part, i|
          part = part.strip
          next if part.empty?

          size = if part.end_with?("%")
            part
          elsif part.end_with?("h")
            part.chomp("h")
          else
            part
          end

          unless size.match?(/\A\d+%?\z/)
            raise Workspace::Error, "Invalid pane size: '#{part}'. Use a number (rows) or percentage (e.g. 50%)."
          end

          result[i] = size
        end
        result
      end
    end
  end
end
