require "stringio"
require "tmpdir"

RSpec.describe Workspace::HelpPages do
  pages = described_class::COMMANDS

  # A collaborator that fails the example on any call, to show a request for help did no work.
  untouchable = Class.new do
    def method_missing(name, *, **)
      raise "unexpected call to #{name}"
    end

    def respond_to_missing?(*) = true
  end

  # The real CLI in a throwaway HOME, so no real state is read or written.
  def with_cli
    Dir.mktmpdir("workspace-help-pages") do |home|
      saved = ENV.to_h
      ENV.replace("HOME" => home, "PATH" => File.dirname(RbConfig.ruby))
      begin
        out = StringIO.new
        err = StringIO.new
        raise "#{Dir.home} is outside the throwaway HOME" unless Dir.home == home

        cli = Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {})
        yield cli, out, err, home
      ensure
        ENV.replace(saved)
      end
    end
  end

  describe "the tables" do
    it "name the same verbs as the tables the commands dispatch on" do
      expect(pages["plan"].keys).to eq(
        (Workspace::CLI::PLAN_FLAGS.keys - ["task"]) + Workspace::CLI::PLAN_TASK_FLAGS.keys.map { |verb| "task #{verb}" }
      )
      expect(pages["daemon"].keys).to match_array(Workspace::CLI::DAEMON_SUBCOMMANDS)
      expect(pages["library"].keys).to match_array(Workspace::CLI::LIBRARY_SUBCOMMANDS)
      expect(pages["workflow"].keys).to match_array(Workspace::CLI::WORKFLOW_SUBCOMMANDS)
    end

    it "name the verbs of the commands whose verbs are not in a constant" do
      expect(pages["spine"].keys).to match_array(["show", "set", "check", "verify", "goal set", "start", "init"])
      expect(pages["binding"].keys).to match_array(%w[set show clear])
      expect(pages["step"].keys).to match_array(%w[done status])
      expect(pages["review"].keys).to match_array(%w[show list])
      expect(pages["pr"].keys).to match_array(%w[create feedback])
      expect(pages["ticket"].keys).to match_array(%w[show list])
      expect(pages["goal"].keys).to match_array(%w[show list])
      expect(pages["pipeline"].keys).to match_array(%w[start advance status reset])
      expect(pages["notes"].keys).to eq(["dir"])
      expect(pages["instructions"].keys).to eq(["compose"])
      expect(pages["ui"].keys).to eq(["open"])
      expect(pages["projects"].keys).to eq(["list"])
      expect(pages["projects group"].keys).to match_array(%w[create add list show])
      expect(pages["config"].keys).to eq(["show"])
      expect(pages["ask"].keys).to match_array(%w[list answer deliver withdraw])
      expect(pages["inbox"].keys).to match_array(%w[add list show edit done dismiss reopen snooze ack])
      expect(pages["agent-run"].keys).to eq(["command", "inject", "restart", "send", "queue", "queue list", "queue cancel", "examples"])
      expect(pages["handoff"].keys).to eq(%w[check new])
    end

    it "name the verbs of lock and dev, the hidden dev __run apart" do
      expect(pages["lock"].keys).to eq(%w[acquire release status clear instructions])
      expect(pages["dev"].keys).to eq(%w[up down status wait leave __run])
      expect(pages["dev"].select { |_, page| page[:hidden] }.keys).to eq(["__run"])
    end

    it "state the default poll the lock wait uses" do
      poll = pages["lock"]["acquire"][:options].to_h.fetch("--poll DURATION")
      expect(poll).to include("default: #{Workspace::Commands::Lock::DEFAULT_POLL_SECONDS})")
    end

    it "state the agent-run restart limits the code uses" do
      restart = pages["agent-run"]["restart"]
      expect(restart[:about].join(" ")).to include("up to #{Workspace::AgentRestart::QUIET_TIMEOUT}s")
      timeout = restart[:options].to_h.fetch("--timeout DURATION")
      expect(timeout).to include("default #{Workspace::AgentRestart::CONFIRM_TIMEOUT}s")
      expect(timeout).to include("at most #{Workspace::Commands::Agent::MAX_RESTART_TIMEOUT}s")
    end

    it "give each plan verb the flags PLAN_FLAGS and PLAN_TASK_FLAGS allow" do
      flags = lambda do |page|
        page[:options].map { |label, _| label.split.first.delete_prefix("--").tr("-", "_").to_sym }
      end
      pages["plan"].each do |key, page|
        verb = key.delete_prefix("task ")
        allowed = (verb == key) ? Workspace::CLI::PLAN_FLAGS.fetch(verb) : Workspace::CLI::PLAN_TASK_FLAGS.fetch(verb) + %i[name json]
        expect(flags.call(page)).to match_array(allowed), "plan #{key}"
      end
    end

    it "list only agent kinds the agent providers know" do
      kinds = Workspace::AgentProvider.all.map(&:key).join(", ")
      spawn = pages.values.flat_map(&:values).flat_map { |page| page[:options] }.select { |label, _| label.start_with?("--spawn", "--agent-kind") }
      expect(spawn).not_to be_empty
      spawn.each { |_, text| expect(text).to include(kinds) }
    end

    it "list the default timeout the readiness wait uses" do
      timeout = pages["workflow"]["start"][:options].to_h.fetch("--prompt-timeout DURATION")
      expect(timeout).to include("(default #{Workspace::AgentReadiness::DEFAULT_TIMEOUT}s)")
    end

    it "give every page a usage, summary, about, options and examples" do
      pages.each do |command, table|
        table.each do |key, page|
          expect(page.keys - [:hidden]).to eq(%i[usage summary about options examples]), "#{command} #{key}"
          expect(page[:usage].first).to start_with("#{command} #{key.split.first}"), "#{command} #{key}"
        end
      end
    end

    parsers = {
      "plan" => :plan_parser, "daemon" => :daemon_parser, "workflow" => :workflow_parser, "library" => :library_parser,
      "spine" => :spine_parser, "binding" => :binding_parser, "step" => :step_parser, "review" => :review_parser,
      "pr" => :pr_parser, "ticket" => :ticket_parser, "goal" => :goal_parser, "notes" => :notes_parser,
      "instructions" => :instructions_parser, "ui" => :ui_parser
    }
    parsers.each do |command, factory|
      it "list only flags the #{command} parser accepts" do
        with_cli do |cli, *|
          pages.fetch(command).each do |key, page|
            parser_factory = ((command == "spine" && key == "init") ? :spine_init_parser : factory)
            page[:options].each do |label, _|
              word = label.split(", ").first
              flag = word.split.first.sub("[no-]", "")
              takes_value = word.include?(" ") && !word.include?("[")
              options = Hash.new { |hash, k| hash[k] = [] }
              argv = takes_value ? [flag, "1"] : [flag]
              expect { cli.send(parser_factory, options).parse(argv) }.not_to raise_error, "#{command} #{key} #{label}"
            end
          end
        end
      end
    end
  end

  describe ".render" do
    let(:page) { {usage: ["plan x [--yes]", "plan y"], summary: "s", about: ["About it."], options: [["--yes", "Confirm"]], examples: []} }

    it "prints usage, summary, about and options, and no Examples section while there are none" do
      expect(described_class.render(page)).to eq([
        "Usage: workspace plan x [--yes]", "       workspace plan y", "", "s.", "", "About it.", "", "Options:",
        "    --yes                        Confirm", "    -h, --help                   Show this help"
      ])
    end

    it "writes the examples last, with the one separator" do
      lines = described_class.render(page.merge(examples: [["workspace plan x", "the usual case"]]))
      expect(lines.last(2)).to eq(["Examples:", "  workspace plan x#{described_class::EXAMPLE_SEPARATOR}the usual case"])
    end
  end

  describe ".value_flags" do
    it "registers every word of a label that has a metavar, and skips optional values" do
      page = {options: [["-n, --name NAME", "x"], ["--project [NAME]", "y"], ["--yes", "z"], ["--note TEXT", "w"]]}
      expect(described_class.value_flags(page)).to eq(%w[-n --name --note])
    end
  end

  describe ".lookup" do
    let(:table) { {"task" => {}, "task add" => {}, "show" => {}} }

    it "takes the longest leading match" do
      expect(described_class.lookup(table, %w[task add --help]).first).to eq("task add")
      expect(described_class.lookup(table, %w[task bogus --help]).first).to eq("task")
      expect(described_class.lookup(table, %w[show some-workspace --help]).first).to eq("show")
    end

    it "finds nothing when an option leads or the verb is unknown" do
      expect(described_class.lookup(table, %w[--help])).to be_nil
      expect(described_class.lookup(table, %w[--name x show])).to be_nil
      expect(described_class.lookup(table, %w[bogus --help])).to be_nil
    end

    it "lets a word that leads exactly one two-word verb find that verb" do
      local = {"goal set" => {}, "task add" => {}, "task move" => {}, "show" => {}}
      expect(described_class.lookup(local, %w[goal --help]).first).to eq("goal set")
      expect(described_class.lookup(local, %w[task --help])).to be_nil
      expect(described_class.lookup(local, %w[bogus --help])).to be_nil
    end

    it "prints the goal set page for spine goal --help" do
      with_cli do |cli, out, *|
        begin
          cli.run(%w[spine goal --help])
        rescue SystemExit
          nil
        end
        expect(out.string).to eq(described_class.render(described_class::SPINE.fetch("goal set")).join("\n") + "\n")
      end
    end
  end

  describe "--help before any work" do
    # Every verb with a page, so a new verb joins the list by being added to a table, plus the same
    # verbs with arguments in front of the help request.
    verbs = Workspace::HelpPages::COMMANDS.flat_map { |command, table| table.keys.map { |key| command.split + key.split } }
    with_arguments = [
      %w[workflow cancel wr_1], %w[workflow approve wr_1 --bogus], %w[library remove play/x --yes],
      %w[plan delete --yes], %w[plan delete --bogus], %w[daemon restart --all], %w[daemon restart my-app],
      %w[projects group create Billing], %w[spine start verify]
    ]

    def run_with_untouchable_collaborators(argv, untouchable)
      with_cli do |cli, out, _err, home|
        cli.instance_variables.grep(/_command\z|\A@library\z/).each do |ivar|
          cli.instance_variable_set(ivar, untouchable.new) unless cli.instance_variable_get(ivar).nil?
        end
        cli.run(argv)
        expect(out.string).not_to be_empty
        expect(Dir.children(home)).to eq([])
        return out.string
      end
    end

    (verbs.map { |v| v + ["--help"] } + with_arguments.flat_map { |v| [v + ["--help"], v + ["-h"]] }).each do |argv|
      it "prints a page for 'workspace #{argv.join(" ")}' and calls nothing" do
        text = run_with_untouchable_collaborators(argv, untouchable)
        expect(text).to start_with("Usage: workspace #{argv.first}")
      end
    end

    [
      %w[workflow --name x cancel --help], %w[library --name x remove play/x --help], %w[plan --name x delete --help],
      %w[daemon --name x restart --help], %w[spine --name x set verify --help], %w[binding --name x clear --help],
      %w[pr --name x create --help]
    ].each do |argv|
      it "does no work for 'workspace #{argv.join(" ")}', whichever page it prints" do
        run_with_untouchable_collaborators(argv, untouchable)
      end
    end

    it "prints the page of the verb asked about, not the whole command's" do
      with_cli do |cli, out, *|
        cli.run(%w[plan delete --help])
        expect(out.string).to include("Usage: workspace plan delete")
        expect(out.string).not_to include("workspace plan status")
        expect(out.string).to include("--yes")
        expect(out.string).not_to include("--spawn")
      end
    end

    it "keeps the overview for the bare command, built from the pages" do
      with_cli do |cli, out, *|
        cli.run(%w[plan --help])
        text = out.string
        Workspace::HelpPages::PLAN.each_value { |page| expect(text).to include(page[:usage].first) }
        expect(text).to include("Run `workspace plan VERB --help`")
      end
    end
  end

  describe "a literal --help" do
    it "is a value after a flag that takes one, and nothing after --" do
      page = pages["workflow"]["approve"]
      expect(cli_help_requested(%w[wr_1 --note --help], page)).to be(false)
      expect(cli_help_requested(%w[wr_1 --note=x --help], page)).to be(true)
      expect(cli_help_requested(%w[wr_1 -- --help], page)).to be(false)
      expect(cli_help_requested(%w[wr_1 --json --help], page)).to be(true)
      expect(cli_help_requested(%w[wr_1 -h], page)).to be(true)
    end

    it "does not swallow the word after a flag whose value is optional" do
      page = pages["library"]["remove"]
      expect(cli_help_requested(%w[play/x --project --help], page)).to be(true)
    end

    it "is the value of --name on a layout verb, so the verb's page is not shown" do
      page = pages["layout"]["save"]
      expect(cli_help_requested(%w[--name --help], page)).to be(false)
      expect(cli_help_requested(%w[--name x --help], page)).to be(true)
      with_cli do |cli, out, *|
        layout = instance_double(Workspace::Commands::Layout)
        expect(layout).to receive(:save).with("--help", "default")
        cli.instance_variable_set(:@layout_command, layout)
        cli.run(%w[layout save --name --help])
        expect(out.string).not_to include("Usage: workspace layout save")
      end
    end

    it "stays the question text of an ask that records one, and the answer text after --" do
      with_cli do |cli, out, *|
        ask = instance_double(Workspace::Commands::Ask)
        expect(ask).to receive(:call).with(hash_including(question: "--help", default: "-h")).and_return({exit_code: 0})
        cli.instance_variable_set(:@ask_command, ask)
        cli.run(["ask", "--default", "-h", "--", "--help"])
        expect(out.string).not_to include("Usage: workspace ask")
      end
    end

    it "leaves --help after --default to the option parser, which prints usage and exits 0" do
      with_cli do |cli, out, *|
        cli.instance_variable_set(:@ask_command, untouchable.new)
        saved = $stdout
        $stdout = out
        begin
          expect { cli.run(["ask", "q", "--default", "x", "--help"]) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        ensure
          $stdout = saved
        end
        expect(out.string).to include("Usage: workspace ask")
      end
    end

    it "takes --help after -- as the title of inbox add" do
      with_cli do |cli, out, *|
        inbox = instance_double(Workspace::Commands::Inbox)
        expect(inbox).to receive(:add).with(hash_including(title: "--help")).and_return({exit_code: 0, results: []})
        cli.instance_variable_set(:@inbox_command, inbox)
        cli.run(["inbox", "add", "--", "--help"])
        expect(out.string).not_to include("Usage: workspace inbox add")
      end
    end

    it "shows the page of ask answer for its alias resolve" do
      with_cli do |cli, out, *|
        cli.run(%w[ask resolve --help])
        expect(out.string).to start_with("Usage: workspace ask answer")
      end
    end

    def cli_help_requested(argv, page)
      with_cli { |cli, *| return cli.send(:help_requested?, argv, page) }
    end
  end
end
