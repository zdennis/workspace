module Workspace
  # Reads `focus.chain`, as written by `workspace config set`.
  class FocusConfig
    # The steps after the first `focus`, and a sentence when the stored value was not used.
    Reading = Struct.new(:steps, :warning)

    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # The chain `focus` runs after bringing the window forward: the global
    # `focus.chain`, or the default when it is unset. A value `config set`
    # would refuse, or a global file that can't be read, gives the default's
    # steps and a warning, so a bad config never stops `focus`. Prints nothing.
    #
    # @return [Reading] `steps` is an Array of token Arrays, split on `+`, e.g.
    #   `[["center"], ["dim", "--opacity", "0.5", "--duration", "3"]]`; `warning` is nil or a sentence
    def read
      value = @config_resolver.view(workspace: "", upto: "global").raw("focus.chain")
      Reading.new(steps_of(value.nil? ? ConfigSchema::DEFAULT_FOCUS_CHAIN : ConfigSchema.parse("focus.chain", value)), nil)
    rescue ArgumentError => e
      fallback("focus.chain #{e.message}")
    rescue Workspace::ConfigParseError => e
      fallback("The global config can't be read (#{e.message})")
    end

    private

    def fallback(reason)
      Reading.new(steps_of(ConfigSchema::DEFAULT_FOCUS_CHAIN), "#{reason}; using the default focus.chain.")
    end

    def steps_of(chain)
      Shellwords.split(chain).chunk_while { |a, b| a != "+" && b != "+" }.reject { |part| part == ["+"] }.drop(1)
    end
  end
end
