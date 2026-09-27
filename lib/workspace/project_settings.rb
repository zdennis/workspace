require "yaml"
require "fileutils"

module Workspace
  # Reads and writes per-project YAML configuration from ~/.config/workspace/projects/.
  # Also reads global config from ~/.config/workspace/config.yml.
  class ProjectSettings
    # @param config [Workspace::Config] configuration for path lookups
    def initialize(config:)
      @config = config
    end

    # @param project_name [String] project name
    # @return [Hash] parsed project config, or empty hash if none exists
    def load(project_name)
      path = project_config_path(project_name)
      return {} unless File.exist?(path)
      YAML.safe_load_file(path) || {}
    rescue Psych::SyntaxError
      {}
    end

    # @param project_name [String] project name
    # @param data [Hash] config data to write
    # @return [void]
    def save(project_name, data)
      path = project_config_path(project_name)
      FileUtils.mkdir_p(File.dirname(path))
      atomic_write(path, YAML.dump(data))
    end

    # @return [Hash] parsed global config, or empty hash if none exists
    def load_global
      path = global_config_path
      return {} unless File.exist?(path)
      YAML.safe_load_file(path) || {}
    rescue Psych::SyntaxError
      {}
    end

    # Written to a temp file and renamed into place, so readers that don't
    # take the lock (every `statusline` render) never see a truncated file.
    #
    # @param data [Hash] config data to write
    # @return [void]
    def save_global(data)
      path = global_config_path
      FileUtils.mkdir_p(File.dirname(path))
      atomic_write(path, YAML.dump(data))
    end

    # Guards a load -> mutate -> write cycle on the global config with an
    # exclusive flock on a sibling lock file, matching {#project_config_path}
    # writers ({Workspace::Commands::Config}) so concurrent `config set`
    # calls serialize instead of clobbering each other.
    #
    # @yield the current global config Hash; the block's return value is saved
    # @return [void]
    def with_global_lock
      path = global_config_path
      FileUtils.mkdir_p(File.dirname(path))
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)
        data = yield(load_global)
        save_global(data)
      end
    end

    # Creates a default project config if one does not already exist.
    #
    # @param project_name [String] project name
    # @return [void]
    def ensure_exists(project_name)
      path = project_config_path(project_name)
      return if File.exist?(path)
      save(project_name, {"hooks" => {}, "layouts" => {}})
    end

    # @param project_name [String] project name
    # @return [void]
    def remove(project_name)
      path = project_config_path(project_name)
      File.delete(path) if File.exist?(path)
    end

    # @param project_name [String] project name
    # @param event [String] hook event name (e.g. "post_launch")
    # @return [String, nil] hook script or nil
    def hook_for(project_name, event)
      data = load(project_name)
      data.dig("hooks", event)
    end

    # @param project_name [String] project name
    # @return [Hash] merged layouts (project overrides global)
    def layouts_for(project_name)
      global_layouts = load_global.dig("layouts") || {}
      project_layouts = load(project_name).dig("layouts") || {}
      global_layouts.merge(project_layouts)
    end

    # @param project_name [String] project name
    # @return [String] path to the project config file
    def project_config_path(project_name)
      File.join(@config.workspace_config_dir, "projects", "#{project_name}.yml")
    end

    # @return [String] path to the global config file
    def global_config_path
      File.join(@config.workspace_config_dir, "config.yml")
    end

    private

    def atomic_write(path, content)
      tmp_path = "#{path}.tmp#{Process.pid}"
      File.write(tmp_path, content)
      File.rename(tmp_path, path)
    ensure
      File.delete(tmp_path) if tmp_path && File.exist?(tmp_path)
    end
  end
end
