require "yaml"

module Workspace
  module Commands
    # Sets up workspace by installing tmuxinator templates and creating
    # the config directory if it doesn't exist.
    class Init
      TEMPLATES = [
        "workspace.project-template.yml",
        "workspace.project-worktree-template.yml"
      ].freeze

      # @param config [Workspace::Config] configuration for path lookups
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      def initialize(config:, output: $stdout, error_output: $stderr)
        @config = config
        @output = output
        @error_output = error_output
      end

      DEFAULT_GLOBAL_CONFIG = {"hooks" => {}, "layouts" => {}}.freeze

      # @param dry_run [Boolean] show what would be done without making changes
      # @param force [Boolean] overwrite existing templates even if they differ
      # @return [void]
      def call(dry_run: false, force: false)
        @output.puts "workspace init#{" (dry run)" if dry_run}"
        @output.puts ""

        ensure_tmuxinator_dir(dry_run)
        install_templates(dry_run, force)
        ensure_workspace_config_dir(dry_run)
        install_global_config(dry_run)

        @output.puts ""
        if dry_run
          @output.puts "No changes made (dry run)."
        else
          @output.puts "Done! Workspace is ready to use."
        end
      end

      private

      def ensure_tmuxinator_dir(dry_run)
        tmuxinator_dir = @config.tmuxinator_dir

        if File.directory?(tmuxinator_dir)
          @output.puts "  exists  #{tmuxinator_dir}"
        elsif dry_run
          @output.puts "  create  #{tmuxinator_dir}"
        else
          FileUtils.mkdir_p(tmuxinator_dir)
          @output.puts "  create  #{tmuxinator_dir}"
        end
      end

      def install_templates(dry_run, force)
        TEMPLATES.each do |template|
          src = File.join(@config.templates_dir, template)
          dest = File.join(@config.tmuxinator_dir, template)

          unless File.exist?(src)
            @error_output.puts "  error   #{template} not found in #{@config.templates_dir}"
            next
          end

          install_template(src, dest, template, dry_run, force)
        end
      end

      def ensure_workspace_config_dir(dry_run)
        workspace_dir = @config.workspace_config_dir
        projects_dir = File.join(workspace_dir, "projects")

        [workspace_dir, projects_dir].each do |dir|
          if File.directory?(dir)
            @output.puts "  exists  #{dir}"
          elsif dry_run
            @output.puts "  create  #{dir}"
          else
            FileUtils.mkdir_p(dir)
            @output.puts "  create  #{dir}"
          end
        end
      end

      def install_global_config(dry_run)
        path = File.join(@config.workspace_config_dir, "config.yml")

        if File.exist?(path)
          @output.puts "  skip    config.yml (already exists)"
        elsif dry_run
          @output.puts "  create  config.yml -> #{path}"
        else
          File.write(path, YAML.dump(DEFAULT_GLOBAL_CONFIG))
          @output.puts "  create  config.yml -> #{path}"
        end
      end

      def install_template(src, dest, template, dry_run, force)
        if File.exist?(dest)
          if FileUtils.identical?(src, dest)
            @output.puts "  skip    #{template} (already up to date)"
          elsif force
            FileUtils.cp(src, dest) unless dry_run
            @output.puts "  update  #{template} -> #{dest}"
          else
            @output.puts "  skip    #{template} (already exists, use --force to overwrite)"
          end
        elsif dry_run
          @output.puts "  copy    #{template} -> #{dest}"
        else
          FileUtils.cp(src, dest)
          @output.puts "  copy    #{template} -> #{dest}"
        end
      end
    end
  end
end
