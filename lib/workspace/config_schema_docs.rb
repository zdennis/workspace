module Workspace
  # Renders {ConfigSchema} into the blocks of docs/README.config.md that sit
  # between `<!-- BEGIN GENERATED: name -->` and `<!-- END GENERATED: name -->`
  # markers. `script/generate-config-docs` rewrites the file; a spec fails
  # when the checked-in file differs from what this renders.
  module ConfigSchemaDocs
    BLOCK = /(<!-- BEGIN GENERATED: (\S+) -->\n).*?(<!-- END GENERATED: \2 -->)/m

    # @param text [String] a document containing generated-block markers
    # @return [String] the document with every block re-rendered
    # @raise [ArgumentError] for a block name this module doesn't render
    def self.rewrite(text)
      text.gsub(BLOCK) { "#{$1}#{render($2)}#{$3}" }
    end

    # @param name [String] "keys", "restart", "global-settings" or "project-settings"
    # @return [String] the block's body, ending in a newline
    # @raise [ArgumentError] for an unknown name
    def self.render(name)
      case name
      when "keys" then keys_table
      when "restart" then restart_sentence
      when "global-settings" then settings_table(:global)
      when "project-settings" then settings_table(:project)
      else raise ArgumentError, "unknown generated block #{name.inspect}"
      end
    end

    def self.keys_table
      rows = ConfigSchema.settable.map do |key|
        prefix = "Global. " if key.global?
        "| `#{key.name}` | #{prefix}#{key.doc} |"
      end
      ["| Key | Description |", "|-----|-------------|", *rows].join("\n") + "\n"
    end
    private_class_method :keys_table

    def self.restart_sentence
      names = ConfigSchema.restart_required_names.map { |name| "`#{name}`" }
      list = "#{names[0..-2].join(", ")} and #{names.last}"
      "#{list} only take effect the next time the session-monitor daemon starts (`workspace launch`/`workspace agentd --force`); a daemon already running keeps the values it started with. `workspace config set` prints a reminder of this after setting any of these #{number_word(names.size)} keys.\n"
    end
    private_class_method :restart_sentence

    def self.settings_table(scope)
      rows = ConfigSchema.all.select { |key| key.scope == scope && !key.settable? }.map do |key|
        "| `#{key.name}` | #{key.doc} |"
      end
      ["| Setting | Description |", "|---------|-------------|", *rows].join("\n") + "\n"
    end
    private_class_method :settings_table

    def self.number_word(count) = {2 => "two", 3 => "three", 4 => "four", 5 => "five"}.fetch(count, count.to_s)
    private_class_method :number_word
  end
end
