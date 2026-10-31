require "stringio"

module Workspace
  # `--help --json`: decides whether a command line truly asks for a help page in
  # JSON, and turns the page text the command prints into one document, so the
  # JSON and the text are the same words and cannot drift.
  class HelpJson
    HELP_WORDS = ["--help", "-h"].freeze
    HEADING = /\A\S.*:\z/

    # Raised in place of an exit while a help page is read, so the status is kept.
    class Exit < Exception # rubocop:disable Lint/InheritException
      attr_reader :status

      def initialize(status)
        @status = status
        super("exit #{status}")
      end
    end

    # The exit handler of a help read: records the status by raising {Exit}.
    module ExitRecorder
      def self.exit(status = 0)
        raise Exit.new(status)
      end
    end

    # Commands whose words may be free text, with the verbs that are not: a `--help` after other
    # words of such a command is left alone (`ask what is --help --json` is a question), but
    # `ask --help` and `ask list --help` are help requests.
    FREE_TEXT = {"ask" => ["list", "answer", "resolve", "deliver", "withdraw"]}.freeze

    # Whether +args+ ask for a help page in JSON. Safe by construction: before any `--`, a `--json`
    # and a `--help` or `-h`, and no word before the help word that starts with a dash. A dashed
    # word before it could be a flag that takes the help word as its value (`--name --help`), and
    # the flags of a command are not known here, so the line is left alone and the command runs
    # as it did before (`plan pause --interrupt --help --json` prints the text page).
    #
    # @param args [Array<String>] the arguments after the program name
    # @return [Array<String>, nil] the arguments without `--json`, or nil when this is not a help request
    def self.strip(args)
      stop = args.index("--") || args.size
      head = args.first(stop)
      return nil unless head.include?("--json")

      words = head.reject { |arg| arg == "--json" }
      verbs = FREE_TEXT[words.first]
      return nil if verbs && words.size > 1 && !HELP_WORDS.include?(words[1]) && !verbs.include?(words[1])

      index = words.index { |arg| HELP_WORDS.include?(arg) }
      requested = index ? words.first(index).none? { |arg| arg.start_with?("-") } : words == ["help"]
      requested ? words + args.drop(stop) : nil
    end

    # The document for a printed help page. Always valid, whatever the shape of the text: what is
    # not recognised stays in +description+ or +sections+.
    #
    # @param text [String] the page as printed
    # @return [Hash] `usage`, `description`, `options`, `examples` and, for other headed parts, `sections`
    def self.document(text)
      lines = text.lines.map(&:chomp)
      usage = []
      if lines.first.to_s.start_with?("Usage:")
        usage << lines.shift.delete_prefix("Usage:").strip
        usage << lines.shift.strip while lines.first.to_s.match?(/\A\s+workspace\s/)
      end
      description = []
      description << lines.shift while lines.any? && !lines.first.match?(HEADING)
      sections = []
      lines.each do |line|
        if line.match?(HEADING)
          sections << {heading: line.delete_suffix(":"), body: []}
        else
          sections.last[:body] << line
        end
      end
      named = ->(name) { sections.select { |s| s[:heading] == name } }
      options = named.call("Options").flat_map { |s| options_of(s[:body]) }
      examples = named.call("Examples").flat_map { |s| s[:body].reject { |l| l.strip.empty? }.map { |l| example(l) } }
      other = sections.reject { |s| ["Options", "Examples"].include?(s[:heading]) }
        .map { |s| {"heading" => s[:heading], "text" => trim(s[:body])} }
      doc = {"usage" => usage, "description" => trim(description), "options" => options, "examples" => examples}
      doc["sections"] = other unless other.empty?
      doc
    end

    # A line that starts with a dash begins an option; any other line continues the one before.
    def self.options_of(body)
      body.reject { |l| l.strip.empty? }.each_with_object([]) do |line, found|
        text = line.strip
        if text.start_with?("-") || found.empty?
          found << option(text)
        else
          last = found.last
          last["description"] = [last["description"], text].reject(&:empty?).join(" ")
        end
      end
    end

    # The flags come first, then two or more spaces; a flag too long for that column is followed
    # by one space, so its words are taken while they look like flags or placeholders.
    def self.option(text)
      flags, description = text.split(/\s{2,}/, 2)
      if description.nil?
        words = text.split(" ")
        count = words.index { |w| !w.match?(/\A(-\S*|\[\S+\]|<\S+>|[A-Z][A-Z0-9_.|]*,?)\z/) } || words.size
        count = words.size if count.zero?
        flags = words.first(count).join(" ")
        description = words.drop(count).join(" ")
      end
      {"flags" => flags, "description" => description.to_s}
    end

    def self.example(line)
      command, scenario = line.strip.split(/\s+# /, 2)
      {"command" => command.to_s, "scenario" => scenario.to_s.strip}
    end

    def self.trim(lines)
      lines.join("\n").strip
    end
  end
end
