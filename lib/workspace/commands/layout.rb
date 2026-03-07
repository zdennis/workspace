module Workspace
  module Commands
    # Saves, restores, and lists tmux pane layouts for workspace projects.
    # Layouts are stored as tmux layout strings in the state file.
    class Layout
      DEFAULT_NAME = "default"

      # @param state [Workspace::State] state persistence
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, tmux:, output: $stdout)
        @state = state
        @tmux = tmux
        @output = output
      end

      # Saves the current tmux layout for the given project.
      #
      # @param project [String] project/config name
      # @param name [String] layout name
      # @return [void]
      # @raise [Workspace::Error] if no active session or capture fails
      def save(project, name = DEFAULT_NAME)
        session_name = resolve_session(project)
        layout = @tmux.capture_layout(session_name)
        unless layout
          raise Workspace::Error, "Could not capture layout for '#{project}'."
        end

        @state.load
        ensure_project_state(project)
        @state[project]["layouts"] ||= {}
        @state[project]["layouts"][name] = layout
        @state.save

        @output.puts "Saved layout '#{name}' for #{project}."
      end

      # Restores a saved tmux layout for the given project.
      #
      # @param project [String] project/config name
      # @param name [String] layout name
      # @return [void]
      # @raise [Workspace::Error] if no saved layout or no active session
      def restore(project, name = DEFAULT_NAME)
        session_name = resolve_session(project)

        @state.load
        layout = @state.dig(project, "layouts", name)
        unless layout
          raise Workspace::Error, "No saved layout '#{name}' for '#{project}'.\nRun 'workspace layout save #{project} #{name}' first."
        end

        unless @tmux.apply_layout(session_name, layout)
          raise Workspace::Error, "Failed to apply layout '#{name}' for '#{project}'."
        end

        @output.puts "Restored layout '#{name}' for #{project}."
      end

      # Lists saved layouts for the given project.
      #
      # @param project [String] project/config name
      # @return [void]
      def list(project)
        @state.load
        layouts = @state.dig(project, "layouts") || {}

        if layouts.empty?
          @output.puts "No saved layouts for '#{project}'."
          return
        end

        layouts.each do |name, _layout|
          @output.puts "  #{name}"
        end
      end

      # Saves the current layout under a given name without user-facing output.
      # Used internally (e.g., by resize) to auto-snapshot before changes.
      #
      # @param project [String] project/config name
      # @param name [String] layout name
      # @return [void]
      def auto_save(project, name)
        session_name = @tmux.session_name_for(project)
        return unless @tmux.sessions.include?(session_name)

        layout = @tmux.capture_layout(session_name)
        return unless layout

        @state.load
        ensure_project_state(project)
        @state[project]["layouts"] ||= {}
        @state[project]["layouts"][name] = layout
        @state.save
      end

      private

      def resolve_session(project)
        session_name = @tmux.session_name_for(project)
        unless @tmux.sessions.include?(session_name)
          raise Workspace::Error, "No active tmux session for '#{project}'.\nRun 'workspace launch #{project}' to start it."
        end
        session_name
      end

      def ensure_project_state(project)
        @state[project] ||= {}
      end
    end
  end
end
