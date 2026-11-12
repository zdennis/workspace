# Every help page must end with an `Examples:` section of 3 to 10 commented
# examples. HelpExamplesSpec::PAGES (spec/support/cli_golden.rb) is the one list
# of pages; every page must pass. Each page runs through CliGolden.run.
RSpec.describe "help pages end with examples" do
  pages = HelpExamplesSpec::PAGES
  aliases = HelpExamplesSpec::ALIASES
  def run_help(argv, extra: [])
    result = CliGolden.run(argv + ["--help"] + extra)
    [result.stdout, result.status, result.stdout + result.stderr]
  end

  def problems(argv)
    text, status, = run_help(argv)
    # 'workspace help' prints the root page, whose examples start with plain 'workspace'
    command = (argv == ["help"]) ? "" : argv.join(" ")
    found = []
    found << "exit #{status}" unless status == 0
    lines = text.lines.map(&:chomp)
    prefix = ["Usage: workspace", command].reject(&:empty?).join(" ")
    found << "first line is #{lines.first.inspect}" unless lines.first.to_s.match?(/\A#{Regexp.escape(prefix)}(\s|\[|\z)/)
    heading = lines.rindex { |l| l.match?(/\A\S.*:\z/) }
    if heading.nil? || lines[heading] != "Examples:"
      found << "last section is #{heading && lines[heading].inspect}, not \"Examples:\""
      return found
    end
    examples = lines[(heading + 1)..].reject { |l| l.strip.empty? }
    found << "#{examples.size} examples, want 3 to 10" unless (3..10).cover?(examples.size)
    start = /\A\s+(?:[A-Z_]+=\S+ )*#{Regexp.escape(["workspace", command].reject(&:empty?).join(" "))}(?:\s|\z)/
    examples.reject { |l| l.match?(start) }.each { |l| found << "example does not start with #{["workspace", command].reject(&:empty?).join(" ")}: #{l.strip}" }
    examples.reject { |l| l.include?(" #") }.each { |l| found << "example has no # comment: #{l.strip}" }
    found
  end

  def argv_for(page)
    page.split
  end

  it "lists each page once" do
    expect(pages.uniq).to eq(pages)
  end

  it "covers every subcommand and every verb table, so a new command cannot skip it" do
    # Commands with no verb constant (inbox, plan, lock...) have their verbs listed by hand above.
    missing = Workspace::CLI::SUBCOMMANDS - aliases.keys - pages
    expect(missing).to eq([])

    unlisted = Workspace::HelpPages::COMMANDS.flat_map { |command, table| table.keys.map { |key| "#{command} #{key}" } } - pages
    expect(unlisted).to eq([])

    {
      "daemon" => Workspace::CLI::DAEMON_SUBCOMMANDS,
      "library" => Workspace::CLI::LIBRARY_SUBCOMMANDS,
      "workflow" => Workspace::CLI::Workflow::SUBCOMMANDS
    }.each do |command, verbs|
      expect(verbs - pages.filter_map { |p| p.delete_prefix("#{command} ") if p.start_with?("#{command} ") }).to eq([])
    end
  end

  pages.each do |page|
    it "has a good page for 'workspace #{page} --help'" do
      expect(problems(argv_for(page))).to eq([])
    end
  end

  pages.each do |page|
    it "prints the page of 'workspace #{page} --help --json' as one document with the text page's examples" do
      text, = run_help(argv_for(page))
      json_text, status, = run_help(argv_for(page), extra: ["--json"])
      doc = JSON.parse(json_text)

      lines = text.lines.map(&:chomp)
      heading = lines.rindex { |l| l.match?(/\A\S.*:\z/) }
      text_examples = lines[(heading + 1)..].reject { |l| l.strip.empty? }
      expect(status).to eq(0)
      expect(doc.keys).to start_with("usage", "description", "options", "examples")
      expect(doc["usage"]).not_to be_empty
      expect(doc["examples"].size).to eq(text_examples.size)
      expect(doc["examples"].map { |e| e["command"] }).to all(match(/\A(?:[A-Z_]+=\S+ )*workspace/))
    end
  end

  aliases.each do |name, target|
    it "'workspace #{name} --help' shows the page of #{target}" do
      text, status, = run_help([name])
      target_text, target_status, = run_help([target])
      expect(text).to eq(target_text)
      expect(status).to eq(target_status)
    end
  end
end
