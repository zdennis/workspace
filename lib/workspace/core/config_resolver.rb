module Workspace
  # Reads config keys through the layering rule ({ConfigLayering}) for the
  # readers that act on config. A {View} fixes the workspace and loads only the
  # layer files its keys need, once each, so a global-only key never touches a
  # project file.
  #
  # Project and worktree files are read strictly ({ProjectSettings#load} raises
  # {ConfigParseError}); the global file leniently ({ProjectSettings#load_global}).
  class ConfigResolver
    # What one key resolved to.
    #
    # @!attribute key [ConfigSchema::Key]
    # @!attribute winner [ConfigLayering::Hit, nil] the highest layer holding a value
    # @!attribute hits [Array<ConfigLayering::Hit>] every layer holding a value, highest first
    Resolution = Struct.new(:key, :winner, :hits, keyword_init: true)

    # @param project_settings [Workspace::ProjectSettings] where each layer's file is read from
    def initialize(project_settings:)
      @project_settings = project_settings
    end

    # @param workspace [String] the workspace name; a worktree's own file is the "worktree" layer
    # @param project [String, nil] the parent project; defaults to the part of a worktree name before
    #   ".worktree-", else the workspace itself
    # @param upto [String, nil] "global" or "project" to drop the layers above it; nil keeps all
    # @return [View]
    # @raise [ArgumentError] if `upto` is anything else
    def view(workspace:, project: nil, upto: nil)
      ConfigLayering.check_upto(upto)
      project ||= WorkspaceLineage.split_worktree_name(workspace)&.first || workspace
      View.new(project_settings: @project_settings, workspace: workspace, project: project, upto: upto)
    end

    # One workspace's resolved config, with each layer file loaded at most once.
    class View
      def initialize(project_settings:, workspace:, project:, upto:)
        @project_settings = project_settings
        @workspace = workspace
        @project = project
        @upto = upto
        @loaded = {}
      end

      # @param name [String] a declared key
      # @return [Resolution]
      # @raise [Workspace::ConfigParseError] if a project or worktree file the key reads can't be parsed
      def resolve(name)
        key = ConfigSchema.key(name) or raise KeyError, "undeclared config key #{name.inspect}"
        layers = ConfigLayering.read_order(key, worktree: worktree?, upto: @upto)
        data = layers.to_h { |layer| [layer, layer_data(layer)] }
        hits = ConfigLayering.hits(key, data, worktree: worktree?, upto: @upto)
        Resolution.new(key: key, winner: hits.first, hits: hits)
      end

      # @param name [String] a declared key
      # @return [Object, nil] the winning layer's stored value, nil when no layer sets the key
      def raw(name) = resolve(name).winner&.value

      # @param name [String] a declared key
      # @return [Boolean] whether some layer sets the key
      def set?(name) = !resolve(name).winner.nil?

      private

      def worktree? = @project != @workspace

      def layer_data(layer)
        @loaded.fetch(layer) do
          @loaded[layer] = case layer
          when "worktree" then @project_settings.load(@workspace)
          when "project" then @project_settings.load(@project)
          else @project_settings.load_global
          end
        end
      end
    end
  end
end
