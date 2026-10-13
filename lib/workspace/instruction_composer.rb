module Workspace
  # Builds the instructions an agent is given from library packs. A pack is a
  # play: the built-in ones (`binding`, `orchestrator`, `commits`, `review`, `notes`,
  # `handoff`, `dev`)
  # ship with workspace and can't be replaced, and any other play can be
  # named as a pack too (see {Library#pack}).
  #
  # The result is one text with a heading per pack that names where the pack
  # came from. Two packs get lines generated for the caller: `binding` is
  # followed by the pane's current binding, and `commits` by the project's
  # `commands.test` and `commands.lint`.
  #
  # A workflow step's instructions have four layers, in this order, each
  # under its own heading: the default packs, the workflow's `include:`
  # packs and `instructions:`, the step's `include:` packs and prompt, and
  # what the runner knows about this attempt (why the last one failed, a
  # reject note, a note from the person who started the run).
  class InstructionComposer
    # The packs a caller composes when none is named and `workflows.defaults.include` is unset.
    DEFAULT_PACKS = ConfigSchema::DEFAULT_PACKS

    # @param library [Workspace::Library] resolves a pack name to a play
    # @param lineage [Workspace::WorkspaceLineage] names the project whose commands are read
    # @param commands_config [Workspace::CommandsConfig]
    # @param pane_bindings [Workspace::PaneBindings] words a binding for the agent
    # @param workflow_config [Workspace::WorkflowConfig, nil] reads `workflows.defaults.include`;
    #   nil composes {DEFAULT_PACKS} when no pack is named
    # @param notes_config [Workspace::NotesConfig, nil] reads `notes.instructions`; nil adds no
    #   automatic `notes` pack to {#start_packs}
    # @param handoff_config [Workspace::HandoffConfig, nil] reads `handoff.auto`; nil adds no
    #   automatic `handoff` pack, and refuses `handoff: true`
    # @param dev_config [Workspace::DevConfig, nil] reads `dev.up` and `dev.instructions`; nil adds no
    #   automatic `dev` pack
    # @param main_agent [Workspace::MainAgent, nil] says whether the project runs Claude Code,
    #   which the `handoff` pack needs
    def initialize(library:, lineage:, commands_config:, pane_bindings:, workflow_config: nil, notes_config: nil,
      handoff_config: nil, main_agent: nil, dev_config: nil)
      @library = library
      @lineage = lineage
      @commands_config = commands_config
      @pane_bindings = pane_bindings
      @workflow_config = workflow_config
      @notes_config = notes_config
      @handoff_config = handoff_config
      @main_agent = main_agent
      @dev_config = dev_config
    end

    # @param packs [Array<String>, nil] pack names (`name` or `play/name`), in the order
    #   they are composed; nil for the default packs (`workflows.defaults.include`). A pack
    #   named twice, here or in a layer's "include", is composed once, where it is first named
    # @param cwd [String] the project's directory: its library is searched after the
    #   built-in packs, and its `commands.*` keys are read
    # @param binding [Hash{String=>Object}, nil] the pane's binding, added after the `binding` pack
    # @param workflow [Hash{String=>Object}, nil] the workflow's layer: "name", "include"
    #   (pack names) and "text" (its `instructions:`, or nil)
    # @param step [Hash{String=>Object}, nil] the step's layer: "name", "include" and "text" (its prompt)
    # @param attempt [Array<String>, nil] what the runner says about this attempt, one paragraph each
    # @param skip [Array<String>] pack names to leave out wherever a layer names them (`dev`, for a step
    #   that already holds the dev environment)
    # @return [Hash{String=>Object}] "packs" (each "ref", "scope", "project", "path" and
    #   "sha256") and the composed "text"
    # @raise [Workspace::UsageError] for a bad name or a kind other than play
    # @raise [Workspace::Error] code `unknown_library_entry`, or `library_source_missing`
    #   when a pack can't be read
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def compose(packs:, cwd:, binding: nil, workflow: nil, step: nil, attempt: nil, skip: [])
      seen = []
      sections = pack_sections(packs || default_packs, cwd, binding, seen, skip)
      [["workflow", workflow], ["step", step]].each do |kind, layer|
        next unless layer
        sections.concat(pack_sections(layer["include"] || [], cwd, binding, seen, skip))
        sections << "## From #{kind} #{layer["name"]}\n\n#{layer["text"].strip}" if layer["text"]
      end
      sections << "## For this attempt\n\n#{attempt.join("\n\n")}" if attempt&.any?
      {"packs" => seen, "text" => sections.join("\n\n") + "\n"}
    end

    # The packs `start` and `launch` send an agent with its first prompt: the
    # automatic ones the config asks for (`notes`, unless `notes.instructions`
    # is false; `dev`, when the project sets `dev.up` and `dev.instructions` is not
    # false; `handoff`, when `handoff.auto` is true and the main agent is
    # Claude Code), then the ones named with `--pack`. A pack named twice is
    # listed once, where it is first named.
    #
    # @param cwd [String] the project's directory
    # @param packs [Array<String>] names given with `--pack`
    # @param none [Boolean] drop the automatic packs (`--no-packs`)
    # @param handoff [Boolean, nil] `--handoff` (true: send the `handoff` pack, as a "flag" pack),
    #   `--no-handoff` (false: never), or nil to follow `handoff.auto`
    # @return [Array<Hash{String=>String}>] each pack's "name" and "source" ("config" or "flag")
    # @raise [Workspace::UsageError] for +none+ together with +packs+ or with +handoff+ true
    # @raise [Workspace::Error] code `handoff_unsupported_agent` for +handoff+ true when the main
    #   agent is not Claude Code
    def start_packs(cwd:, packs: [], none: false, handoff: nil)
      start_selection(cwd: cwd, packs: packs, none: none, handoff: handoff).first
    end

    # Composes the {#start_packs}. Every pack is read here, so an unknown name
    # fails before the caller creates anything.
    #
    # @return [Hash{String=>Object}] "packs" (as {#compose} gives them, each with
    #   "source"), the composed "text", and "skipped": the config-driven packs left out,
    #   each with "name", "source", "reason" (`handoff_unsupported_agent`) and a "message"
    #   for a warning; nil text and no packs when none applies
    # @raise [Workspace::UsageError, Workspace::Error] see {#start_packs} and {#compose}
    def compose_start(cwd:, packs: [], none: false, handoff: nil)
      entries, skipped = start_selection(cwd: cwd, packs: packs, none: none, handoff: handoff)
      return {"packs" => [], "text" => nil, "skipped" => skipped} if entries.empty?
      result = compose(packs: entries.map { |entry| entry["name"] }, cwd: cwd)
      sources = entries.to_h { |entry| [entry["name"], entry["source"]] }
      {"packs" => result["packs"].map { |play| play.merge("source" => sources[play["ref"].split("/", 2).last]) }, "text" => result["text"], "skipped" => skipped}
    end

    # The `packs` rows `start --json` and `launch --json` report for one workspace.
    #
    # @param packs [Array<Hash>] "packs" from {#compose_start}
    # @param delivered [Boolean] whether the prompt carrying them was sent
    # @param pane [String, nil] the pane id it was sent to
    # @param skipped [Array<Hash>] "skipped" from {#compose_start}
    # @return [Array<Hash{String=>Object}>] "name", "source", "delivered" and "pane" of each; a skipped
    #   pack comes last, undelivered, with its "reason"
    def self.delivery_rows(packs, delivered:, pane:, skipped: [])
      rows = packs.map { |pack| {"name" => pack_names([pack]).first, "source" => pack["source"], "delivered" => delivered, "pane" => pane} }
      rows + skipped.map { |pack| {"name" => pack["name"], "source" => pack["source"], "delivered" => false, "pane" => nil, "reason" => pack["reason"]} }
    end

    # @param packs [Array<Hash>] "packs" from {#compose_start}
    # @return [Array<String>] their names
    def self.pack_names(packs)
      packs.map { |pack| pack["ref"].split("/", 2).last }
    end

    # Whether a prompt is nothing but automatic packs, so that failing to send it is a
    # warning: no `--prompt` text, no play, and no pack named with `--pack`.
    #
    # @param composed [Hash, nil] from {#compose_start}
    # @return [Boolean]
    def self.optional_prompt?(composed, prompt:, play:)
      !composed.nil? && play.nil? && prompt.to_s.strip.empty? && composed["packs"].all? { |pack| pack["source"] == "config" }
    end

    # @return [Array<String>] the packs composed when a caller names none
    # @raise [Workspace::ConfigParseError] if the global config file can't be parsed
    def default_packs
      @workflow_config ? @workflow_config.default_packs : DEFAULT_PACKS
    end

    private

    # The entries {#start_packs} lists, and the config-driven packs left out.
    def start_selection(cwd:, packs:, none:, handoff:)
      raise UsageError, "--no-packs cannot be combined with --pack." if none && packs.any?
      raise UsageError, "--no-packs cannot be combined with --handoff." if none && handoff == true
      project = @lineage.resolve(cwd: cwd).name
      automatic = (none ? [] : automatic_start_packs(project)).map { |pack| {"name" => pack, "source" => "config"} }
      extra, skipped = handoff_pack(project, none: none, handoff: handoff)
      flagged = packs.map { |pack| {"name" => pack.sub(%r{\Aplay/}, ""), "source" => "flag"} }
      [(automatic + extra + flagged).uniq { |pack| pack["name"] }, skipped]
    end

    def automatic_start_packs(project)
      packs = []
      packs << "notes" if @notes_config&.instructions?(project)
      packs << "dev" if @dev_config&.configured?(project) && @dev_config.instructions?(project)
      packs
    end

    # @return [Array(Array<Hash>, Array<Hash>)] the `handoff` entry to send, and the one to report as skipped
    def handoff_pack(project, none:, handoff:)
      flag = handoff == true
      raise Error, "--handoff is not available: no handoff config was wired." if flag && (@handoff_config.nil? || @main_agent.nil?)
      return [[], []] if handoff == false || (!flag && (none || @handoff_config.nil? || @main_agent.nil? || !@handoff_config.auto?(project)))
      kind = @main_agent.kind(project)
      return [[{"name" => "handoff", "source" => flag ? "flag" : "config"}], []] if kind == "claude"
      if flag
        raise Error.new("--handoff needs Claude Code as the main agent, and #{project}'s is #{kind_words(kind)}.",
          code: "handoff_unsupported_agent", details: {"kind" => kind})
      end
      [[], [{"name" => "handoff", "source" => "config", "reason" => "handoff_unsupported_agent",
             "message" => "the handoff pack was not sent to #{project}: handoff.auto is on, but its main agent is #{kind_words(kind)} and the pack needs Claude Code"}]]
    end

    def kind_words(kind)
      (kind == "none") ? "not a known coding agent: its config runs no coding agent" : kind
    end

    # One section per pack not composed yet; each play read is added to +seen+.
    def pack_sections(names, cwd, binding, seen, skip = [])
      names.filter_map do |ref|
        next if skip.include?(ref.sub(%r{\Aplay/}, ""))
        play, body = @library.pack(ref, cwd: cwd)
        next if seen.any? { |earlier| earlier["ref"] == play["ref"] }
        seen << play
        name = play["ref"].split("/", 2).last
        ["## From pack #{name} (#{source(play)})", strip_frontmatter(body).strip, generated(play, name, cwd, binding)].compact.join("\n\n")
      end
    end

    def source(play)
      case play["scope"]
      when "builtin" then "built-in"
      when "project" then "project #{play["project"]}"
      else play["scope"]
      end
    end

    # Removes a leading frontmatter block: `key: value` lines (and their
    # indented continuations) between two `---` lines, or nothing between
    # them. A play that opens with a `---` rule above prose keeps its text.
    def strip_frontmatter(body)
      body.sub(/\A---[ \t]*\n(?:[\w-]+:.*\n|[ \t]+\S.*\n|[ \t]*\n)*---[ \t]*\n/, "")
    end

    # The lines only this call can supply, for the two built-in packs that
    # take them; a play of another scope gets none, whatever its name.
    def generated(play, name, cwd, binding)
      return nil unless play["scope"] == "builtin"
      case name
      when "binding" then binding && "This pane's binding:\n\n#{@pane_bindings.context_for(binding)}"
      when "commits" then commands(cwd)
      end
    end

    def commands(cwd)
      set = @commands_config.for_project(@lineage.resolve(cwd: cwd).name)
      lines = [(command_line("Test", set[:test]) if set[:test]), (command_line("Lint", set[:lint]) if set[:lint])].compact
      return nil if lines.empty?
      lines.join((lines.any? { |line| line.include?("\n") }) ? "\n\n" : "\n")
    end

    # The command as markdown code, with a fence longer than any run of
    # backticks in it; a command of several lines goes in a fenced block.
    def command_line(label, command)
      longest = command.scan(/`+/).map(&:length).max.to_i
      if command.include?("\n")
        fence = "`" * [3, longest + 1].max
        "#{label} command for this project:\n\n#{fence}sh\n#{command}\n#{fence}"
      else
        fence = "`" * (longest + 1)
        pad = longest.zero? ? "" : " "
        "#{label} command for this project: #{fence}#{pad}#{command}#{pad}#{fence}"
      end
    end
  end
end
