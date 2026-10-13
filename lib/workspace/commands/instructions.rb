require "json"

module Workspace
  module Commands
    # `workspace instructions compose`: prints the instructions built from
    # library packs for the pane and project it is run in. See
    # {Workspace::InstructionComposer}.
    class Instructions
      # The schema version of the `compose --json` document.
      JSON_SCHEMA_VERSION = 1

      # @param composer [Workspace::InstructionComposer]
      # @param bindings [Workspace::Commands::Binding] finds the pane's binding
      # @param output [IO]
      def initialize(composer:, bindings:, output: $stdout)
        @composer = composer
        @bindings = bindings
        @output = output
      end

      # @param packs [Array<String>] pack names; empty composes the default packs (`workflows.defaults.include`)
      # @param cwd [String] the project's directory
      # @param pane [String, nil] a pane id ("%19") whose binding follows the `binding` pack
      # @param json [Boolean] print one JSON document instead of the text
      # @param start [Boolean] compose what `start` and `launch` send (see {Workspace::InstructionComposer#compose_start})
      #   instead: the automatic packs, then +packs+; the JSON has no binding
      # @param no_packs [Boolean] with +start+, leave out the automatic packs
      # @return [void]
      # @raise [Workspace::UsageError] for a bad pack name or a pane that is not a pane id
      # @raise [Workspace::Error] see {Workspace::InstructionComposer#compose}
      def compose(packs:, cwd:, pane: nil, json: false, start: false, no_packs: false)
        return compose_start(packs: packs, cwd: cwd, json: json, no_packs: no_packs) if start

        packs = nil if packs.empty?
        binding = pane && @bindings.live(pane: pane)
        result = @composer.compose(packs: packs, cwd: cwd, binding: binding)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true,
            "packs" => result["packs"], "binding" => binding, "text" => result["text"]})
        else
          @output.write(result["text"])
        end
      end

      private

      def compose_start(packs:, cwd:, json:, no_packs:)
        result = @composer.compose_start(cwd: cwd, packs: packs, none: no_packs)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true,
            "packs" => result["packs"], "binding" => nil, "text" => result["text"].to_s})
        else
          @output.write(result["text"].to_s)
        end
      end
    end
  end
end
