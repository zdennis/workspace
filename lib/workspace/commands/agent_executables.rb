require "json"

module Workspace
  module Commands
    # `agent executables`: the agent programs on PATH by family, and which one each family runs.
    # Read-only; the scan itself is {Workspace::AgentExecutables}.
    class AgentExecutables
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # @param executables [Workspace::AgentExecutables]
      # @param project_config [Workspace::ProjectConfig] says which workspace names exist
      # @param output [IO]
      def initialize(executables:, project_config:, output: $stdout)
        @executables = executables
        @project_config = project_config
        @output = output
      end

      # @param name [String, nil] the `--name` given; must be a known workspace
      # @param detected [String, nil] the workspace of the working directory, used when no name is given
      # @param kind [String, nil] an {AgentProvider} key to list only that family
      # @param json [Boolean] print the document documented in docs/README.agent.md
      # @return [void]
      # @raise [Workspace::Error] `unknown_workspace` for a name with no config, `unknown_agent_kind` for a bad kind
      def call(name: nil, detected: nil, kind: nil, json: false)
        workspace = resolve_workspace(name, detected)
        known = AgentProvider.all.map(&:key)
        if kind && !known.include?(kind)
          raise Workspace::Error.new("Unknown agent kind '#{kind}': use #{known.join(", ")}.",
            code: "unknown_agent_kind", details: {"kind" => kind, "known" => known})
        end
        result = @executables.call(workspace: workspace, kind: kind)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => workspace}.merge(result))
        else
          print_text(workspace, result, kind)
        end
      end

      private

      def resolve_workspace(name, detected)
        return detected unless name
        existing = @project_config.existing_name(name)
        return existing if existing

        raise Workspace::Error.new("Unknown workspace '#{name}': it has no config. See `workspace list`.",
          code: "unknown_workspace", details: {"name" => name})
      end

      def print_text(workspace, result, kind)
        @output.puts(workspace ? "Workspace: #{workspace}" : "Workspace: none (global settings)")
        @output.puts "Main agent kind: #{result["kind"]}"
        by_kind = result["executables"].group_by { |row| row["kind"] }
        (kind ? [kind] : AgentProvider.all.map(&:key)).each do |key|
          effective = result["effective"][key]
          source = (effective["layer"] == "default") ? "the default" : "#{effective["layer"]} settings"
          @output.puts ""
          @output.puts "#{key} (runs #{effective["program"]}, from #{source})"
          rows = by_kind.fetch(key, [])
          @output.puts "  none found" if rows.empty?
          rows.each { |row| @output.puts "  #{line(row, effective)}" }
        end
        @output.puts ""
        @output.puts "* marks what the family runs. Set it with `workspace config set agent.commands.<kind> VALUE`."
        @output.puts "More than #{Workspace::AgentExecutables::MAX_ROWS} matches: the list is cut. Narrow it with --kind." if result["truncated"]
      end

      def line(row, effective)
        effective_row = row["found"] ? row["path"] == effective["path"] : File.basename(row["name"]) == effective["program"]
        where = row["found"] ? row["path"] : "not found"
        text = "#{effective_row ? "*" : " "} #{row["name"]}  #{where}"
        text += "  (shadowed: #{row["shadowed"].join(", ")})" if row["shadowed"].any?
        text
      end
    end
  end
end
