module Workspace
  module Commands
    # Saves, restores, and lists tmux pane layouts for workspace projects.
    # Named layouts are stored in per-project config YAML; ephemeral snapshots
    # (like _before_resize) are stored in state.json.
    class Layout
      DEFAULT_NAME = "default"

      # @param state [Workspace::State] state persistence for ephemeral snapshots
      # @param tmux [Workspace::Tmux] tmux session operations
      # @param project_settings [Workspace::ProjectSettings] per-project config
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, tmux:, project_settings: nil, output: $stdout)
        @state = state
        @tmux = tmux
        @project_settings = project_settings
        @output = output
      end

      # Saves the current tmux layout for the given project.
      # Named layouts are stored in project config YAML.
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

        if @project_settings
          save_to_config(project, name, layout)
        else
          save_to_state(project, name, layout)
        end

        @output.puts "Saved layout '#{name}' for #{project}."
      end

      # Restores a saved tmux layout for the given project.
      # Looks up: project config → global config → state.json snapshots.
      #
      # @param project [String] project/config name
      # @param name [String] layout name
      # @return [void]
      # @raise [Workspace::Error] if no saved layout or no active session
      def restore(project, name = DEFAULT_NAME)
        session_name = resolve_session(project)

        layout = find_layout(project, name)
        unless layout
          raise Workspace::Error, "No saved layout '#{name}' for '#{project}'.\nRun 'workspace layout save #{project} #{name}' first."
        end

        unless @tmux.apply_layout(session_name, layout)
          raise Workspace::Error, "Failed to apply layout '#{name}' for '#{project}'."
        end

        @output.puts "Restored layout '#{name}' for #{project}."
      end

      # Lists saved layouts for the given project.
      # Shows merged view: config layouts + state.json snapshots.
      #
      # @param project [String] project/config name
      # @return [void]
      def list(project)
        layouts = merged_layouts(project)

        if layouts.empty?
          @output.puts "No saved layouts for '#{project}'."
          return
        end

        layouts.each_key do |name|
          @output.puts "  #{name}"
        end
      end

      # Saves the current layout under a given name without user-facing output.
      # Used internally (e.g., by resize) to auto-snapshot before changes.
      # Always saves to state.json (ephemeral).
      #
      # @param project [String] project/config name
      # @param name [String] layout name
      # @return [void]
      def auto_save(project, name)
        session_name = @tmux.session_name_for(project)
        return unless @tmux.sessions.include?(session_name)

        layout = @tmux.capture_layout(session_name)
        return unless layout

        save_to_state(project, name, layout)
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

      def save_to_config(project, name, layout)
        data = @project_settings.load(project)
        data["layouts"] ||= {}
        data["layouts"][name] = layout
        @project_settings.save(project, data)
      end

      def save_to_state(project, name, layout)
        @state.load
        ensure_project_state(project)
        @state[project]["layouts"] ||= {}
        @state[project]["layouts"][name] = layout
        @state.save
      end

      def find_layout(project, name)
        # 1. Project config layouts
        if @project_settings
          config_layouts = @project_settings.layouts_for(project)
          return config_layouts[name] if config_layouts[name]
        end

        # 2. State.json snapshots (for _before_resize and legacy)
        @state.load
        @state.dig(project, "layouts", name)
      end

      def merged_layouts(project)
        state_layouts = begin
          @state.load
          @state.dig(project, "layouts") || {}
        end

        if @project_settings
          config_layouts = @project_settings.layouts_for(project)
          state_layouts.merge(config_layouts)
        else
          state_layouts
        end
      end
    end
  end
end
