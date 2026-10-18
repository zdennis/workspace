require "json"

module Workspace
  module Commands
    # `spine show`: one workspace's plan spine (the `spine/` folder of its notes directory) as the
    # stages {SpineTree} reads from it. Read-only: it creates no folder and writes no file, and a
    # bad file is a warning in the answer, never an error.
    class Spine
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # @param notes [Workspace::Commands::Notes] answers where a workspace's notes are
      # @param output [IO]
      def initialize(notes:, output: $stdout)
        @notes = notes
        @output = output
      end

      # @param name [String] the workspace
      # @param json [Boolean] print the document documented in docs/README.spine.md instead of a short summary
      # @return [void]
      # @raise [Workspace::Error] `unknown_workspace`, `notes_dir_unresolved` or `config_parse`; never because of a file's content
      def show(name:, json: false)
        tree = read(name)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name}.merge(tree.to_h))
        else
          print_text(name, tree)
        end
      end

      # @param name [String] the workspace
      # @return [SpineTree] the spine in the workspace's notes directory
      # @raise [Workspace::Error] as {#show}
      def read(name)
        notes_dir = @notes.info(name: name)["dir"]
        SpineTree.read(real(notes_dir))
      end

      private

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def print_text(name, tree)
        unless tree.exists
          @output.puts "#{name}: no spine/ in #{File.dirname(tree.dir)}"
          return
        end
        count = 0
        tree.each_stage { count += 1 }
        @output.puts "#{name}: #{count} #{(count == 1) ? "stage" : "stages"} in #{tree.dir}"
        @output.puts "Goal: #{tree.goal.value("title")}" if tree.goal&.value("title")
        print_stages(tree.stages, 0)
        tree.warnings.each { |w| @output.puts "warning #{w["code"]}: #{w["message"]}" }
        @output.puts "Not stages: #{tree.not_stages.join(", ")}" unless tree.not_stages.empty?
        @output.puts "Some entries were left out (#{tree.truncated})." if tree.truncated
      end

      def print_stages(stages, depth)
        stages.each do |stage|
          line = "#{"  " * depth}#{stage.number} #{stage.id}  #{stage.status}"
          line << " (sub-stages #{stage.rollup["status"]})" if stage.rollup
          owner = stage.file&.value("owner")
          line << "  owner #{owner}" if owner
          done = stage.file&.done_when
          line << "  #{done["done"]}/#{done["total"]} done" if done && done["total"].positive?
          warnings = stage.all_warnings.map { |w| w["code"] }.uniq
          line << "  warnings: #{warnings.join(", ")}" unless warnings.empty?
          @output.puts line
          print_stages(stage.children, depth + 1)
        end
      end
    end
  end
end
