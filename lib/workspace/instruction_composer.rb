module Workspace
  # Builds the instructions an agent is given from library packs. A pack is a
  # play: the built-in ones (`binding`, `orchestrator`, `commits`, `review`)
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
    def initialize(library:, lineage:, commands_config:, pane_bindings:, workflow_config: nil)
      @library = library
      @lineage = lineage
      @commands_config = commands_config
      @pane_bindings = pane_bindings
      @workflow_config = workflow_config
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
    # @return [Hash{String=>Object}] "packs" (each "ref", "scope", "project", "path" and
    #   "sha256") and the composed "text"
    # @raise [Workspace::UsageError] for a bad name or a kind other than play
    # @raise [Workspace::Error] code `unknown_library_entry`, or `library_source_missing`
    #   when a pack can't be read
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def compose(packs:, cwd:, binding: nil, workflow: nil, step: nil, attempt: nil)
      seen = []
      sections = pack_sections(packs || default_packs, cwd, binding, seen)
      [["workflow", workflow], ["step", step]].each do |kind, layer|
        next unless layer
        sections.concat(pack_sections(layer["include"] || [], cwd, binding, seen))
        sections << "## From #{kind} #{layer["name"]}\n\n#{layer["text"].strip}" if layer["text"]
      end
      sections << "## For this attempt\n\n#{attempt.join("\n\n")}" if attempt&.any?
      {"packs" => seen, "text" => sections.join("\n\n") + "\n"}
    end

    # @return [Array<String>] the packs composed when a caller names none
    # @raise [Workspace::ConfigParseError] if the global config file can't be parsed
    def default_packs
      @workflow_config ? @workflow_config.default_packs : DEFAULT_PACKS
    end

    private

    # One section per pack not composed yet; each play read is added to +seen+.
    def pack_sections(names, cwd, binding, seen)
      names.filter_map do |ref|
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
