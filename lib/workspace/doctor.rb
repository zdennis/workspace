require "open3"

module Workspace
  # Checks that all required dependencies are installed and configured.
  class Doctor
    # @param config [Workspace::Config] configuration for path lookups
    # @param state [Workspace::State] state persistence for health checks
    # @param output [IO] output stream for results
    def initialize(config:, state:, output: $stdout)
      @config = config
      @state = state
      @output = output
    end

    # @return [void]
    # @raise [Workspace::Error] if any issues are found
    def run
      @output.puts "workspace doctor"
      @output.puts ""

      issues = 0

      checks = [
        {
          name: "ruby",
          check: -> { check_command("ruby", version_pattern: /(\d+)/, min_major: 3, install_hint: "Install via rbenv, asdf, or https://www.ruby-lang.org/en/downloads/") }
        },
        {
          name: "tmux",
          check: -> { check_command("tmux", version_flag: "-V", version_pattern: /(\d+)/, min_major: 3, install_hint: "brew install tmux") }
        },
        {
          name: "tmuxinator",
          check: -> { check_command("tmuxinator", version_flag: "version", version_pattern: /(\d+)/, install_hint: "brew install tmuxinator") }
        },
        {
          name: "iTerm2",
          check: -> { check_app("iTerm2", bundle_id: "com.googlecode.iterm2", install_hint: "https://iterm2.com/") }
        },
        {
          name: "window-tool",
          check: -> { check_command("window-tool", version_flag: nil, install_hint: "https://github.com/zdennis/window-tool") }
        },
        {
          name: "git",
          check: -> { check_command("git", version_pattern: /(\d+)/, min_major: 2, install_hint: "brew install git") }
        },
        {
          name: "gh",
          check: -> { check_command("gh", version_pattern: /(\d+)/, min_major: 2, install_hint: "brew install gh") }
        },
        {
          name: "ascii-banner",
          check: -> { check_command("ascii-banner", version_flag: nil, install_hint: "https://github.com/zdennis/homebrew-bin/blob/main/docs/README.ascii-banner.md") }
        }
      ]

      checks.each do |entry|
        result = entry[:check].call
        if result[:found]
          if result[:outdated]
            @output.puts "  ✗  #{entry[:name]} (found #{result[:version]}, need #{result[:min_version]})"
            @output.puts "     ↳ install: #{result[:install_hint]}"
            issues += 1
          elsif result[:version]
            @output.puts "  ✓  #{entry[:name]} (#{result[:version]})"
          else
            @output.puts "  ✓  #{entry[:name]}"
          end
        else
          @output.puts "  ✗  #{entry[:name]} (not found)"
          @output.puts "     ↳ install: #{result[:install_hint]}"
          issues += 1
        end
      end

      templates = ["workspace.project-template.yml", "workspace.project-worktree-template.yml"]
      all_installed = templates.all? { |t| File.exist?(File.join(@config.tmuxinator_dir, t)) }

      if all_installed
        @output.puts "  ✓  templates installed"
      else
        missing = templates.reject { |t| File.exist?(File.join(@config.tmuxinator_dir, t)) }
        @output.puts "  ✗  templates (missing: #{missing.join(", ")})"
        @output.puts "     ↳ fix: run 'workspace init' to install them"
        issues += 1
      end

      issues += check_duplicate_window_ids

      @output.puts ""
      if issues > 0
        raise Workspace::Error, "#{issues} issue(s) found."
      else
        @output.puts "Everything looks good!"
      end
    end

    private

    def check_duplicate_window_ids
      @state.load
      return 0 if @state.empty?

      ids_to_projects = {}
      @state.each do |project, data|
        wid = data["iterm_window_id"]
        next unless wid
        (ids_to_projects[wid] ||= []) << project
      end

      duplicates = ids_to_projects.select { |_, projects| projects.size > 1 }
      if duplicates.any?
        @output.puts "  ✗  state: duplicate window IDs detected"
        duplicates.each do |wid, projects|
          @output.puts "     ↳ window #{wid} claimed by: #{projects.join(", ")}"
        end
        @output.puts "     ↳ fix: run 'workspace stop' then 'workspace launch' for affected projects"
        1
      else
        @output.puts "  ✓  state: no duplicate window IDs"
        0
      end
    end

    def check_command(name, version_flag: "--version", version_pattern: /(\d+)/, min_major: nil, install_hint: nil)
      stdout, _, status = Open3.capture3("which", name)
      if !status.success? || stdout.strip.empty?
        return {found: false, install_hint: install_hint}
      end

      version_str = nil
      major = nil
      if version_flag
        stdout, _ = Open3.capture3(name, version_flag)
        match = stdout.strip.match(version_pattern)
        if match
          major = match[1].to_i
          version_str = "#{major}+"
        end
      end

      if min_major && major && major < min_major
        return {found: true, version: version_str, outdated: true, min_version: "#{min_major}+", install_hint: install_hint}
      end

      {found: true, version: version_str}
    end

    def check_app(name, bundle_id:, install_hint:)
      stdout, _, status = Open3.capture3("mdfind", "kMDItemCFBundleIdentifier == '#{bundle_id}'")
      if !status.success? || stdout.strip.empty?
        {found: false, install_hint: install_hint}
      else
        {found: true}
      end
    end
  end
end
