module Workspace
  # The one rule for which config layer a key is read from: the order the
  # layers are consulted in and which one wins. It is pure (no IO), so the
  # readers (through {ConfigResolver}) and {ConfigReport} can share it and
  # `config show` can't disagree with the code that acts on config.
  #
  # Layers are "worktree", "project" and "global"; a key's `resolve` mode and
  # `overridable_in` list say which of them it may come from.
  module ConfigLayering
    # One layer's value for a key.
    #
    # @!attribute layer [String] "worktree", "project" or "global"
    # @!attribute value [Object] the stored, unparsed value; never nil
    Hit = Struct.new(:layer, :value, keyword_init: true)

    # Layers a `:layered` key may be read from, highest precedence first.
    LAYERED_ORDER = %w[worktree project global].freeze

    # Layers each `upto:` value keeps.
    UPTO = {"global" => %w[global], "project" => %w[project global]}.freeze

    # The layers a reader consults for a key, highest precedence first.
    # A key whose mode is `:own`, `:merge` or `:none` has special handling in
    # {ConfigReport} and no reader, so it has no read order.
    #
    # @param key [ConfigSchema::Key, String] the key or its name
    # @param worktree [Boolean] whether the workspace is a worktree
    # @param upto [String, nil] "global" or "project" to drop the layers above it; nil keeps all
    # @return [Array<String>]
    # @raise [ArgumentError] if `upto` is anything else
    def self.read_order(key, worktree:, upto: nil)
      key = schema_key(key)
      check_upto(upto)
      order = case key.resolve
      when :own_then_parent then [worktree ? "worktree" : "project"]
      when :layered then LAYERED_ORDER.select { |layer| (worktree || layer != "worktree") && key.overridable_in?(layer) }
      when :parent then ["project"]
      when :global then ["global"]
      else []
      end
      upto ? order & UPTO.fetch(upto) : order
    end

    # @param key [ConfigSchema::Key, String] the key or its name
    # @param data_by_layer [Hash{String => Hash}] each layer's parsed config; a missing layer counts as empty
    # @param worktree [Boolean] whether the workspace is a worktree
    # @param upto [String, nil] as for {read_order}
    # @return [Array<Hit>] the layers that hold a value, in read order; the first is the winner. A value
    #   that later fails to parse is still the winner: it does not fall through to a lower layer.
    def self.hits(key, data_by_layer, worktree:, upto: nil)
      key = schema_key(key)
      parts = key.name.split(".")
      read_order(key, worktree: worktree, upto: upto).filter_map do |layer|
        value = dig(data_by_layer[layer], parts)
        Hit.new(layer: layer, value: value) unless value.nil?
      end
    end

    # @param key [ConfigSchema::Key, String] the key or its name
    # @param worktree [Boolean] whether the workspace is a worktree
    # @return [String] the layer `config set` writes the key to when no layer is named: "global" for a key of the
    #   global file (a global-file key that is also layered keeps writing there until `--scope` can name another),
    #   else "worktree" for a worktree when the key allows it, else "project". {ConfigReport} reports this as `target_layer`.
    def self.default_layer(key, worktree:)
      key = schema_key(key)
      return "global" if key.global?
      return "worktree" if worktree && key.overridable_in?(:worktree)
      "project"
    end

    # @param upto [String, nil]
    # @raise [ArgumentError] unless `upto` is "global", "project" or nil
    def self.check_upto(upto)
      return if upto.nil? || UPTO.key?(upto)
      raise ArgumentError, "upto must be \"global\", \"project\" or nil, got #{upto.inspect}"
    end

    def self.schema_key(key)
      return key unless key.is_a?(String)
      ConfigSchema.key(key) or raise KeyError, "undeclared config key #{key.inspect}"
    end
    private_class_method :schema_key

    def self.dig(data, parts)
      parts.reduce(data) { |node, part| node.is_a?(Hash) ? node[part] : nil }
    end
    private_class_method :dig
  end
end
