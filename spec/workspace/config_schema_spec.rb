require "spec_helper"

RSpec.describe Workspace::ConfigSchema do
  let(:root) { File.expand_path("../..", __dir__) }

  it "lists the settable keys in the order `config set` has always reported them" do
    expect(described_class.project_keys.map(&:name)).to eq(%w[dev.up dev.ready dev.stop_timeout dev.startup_timeout dev.ready_timeout dev.kill_grace dev.release_on_session_end dev.instructions locks.idle_grace locks.ps_timeout locks.reap_interval alerts.notify alerts.idle_after agentd.poll_interval handoff.threshold handoff.check_prompt handoff.resume_prompt handoff.auto commands.test commands.lint notes.dir notes.default_dir notes.instructions plan.stall_seconds])
    expect(described_class.global_keys.map(&:name)).to eq(%w[statusline.command context.source context.pattern launch.headless workflows.defaults.include])
  end

  it "names the keys a running daemon only reads at startup" do
    expect(described_class.restart_required_names).to eq(%w[locks.ps_timeout locks.reap_interval alerts.notify alerts.idle_after agentd.poll_interval])
  end

  it "tells settable keys from keys that are only documented" do
    expect(described_class.settable?("dev.up")).to be true
    expect(described_class.settable?("hooks")).to be false
    expect(described_class.settable?("dev.bogus")).to be false
  end

  it "has a description for every key" do
    expect(described_class.all).to all(satisfy { |key| !key.doc.to_s.strip.empty? })
  end

  describe "notes.default_dir" do
    def parse(value) = described_class.parse("notes.default_dir", value)

    it "accepts an absolute path, ~/ and a relative path, unchanged, with placeholders" do
      expect(parse("/notes/{workspace}")).to eq("/notes/{workspace}")
      expect(parse("~/notes/{workspace}/{branch}")).to eq("~/notes/{workspace}/{branch}")
      expect(parse("tmp/my notes")).to eq("tmp/my notes")
      expect(parse("/a/../b")).to eq("/a/../b")
    end

    it "rejects a relative path with .., a bare or user ~, blank, padded or control-character values" do
      expect { parse("../x") }.to raise_error(ArgumentError, /"\.\."/)
      expect { parse("a/../x") }.to raise_error(ArgumentError, /"\.\."/)
      expect { parse("~") }.to raise_error(ArgumentError, /~\//)
      expect { parse("~bob/x") }.to raise_error(ArgumentError, /~\//)
      expect { parse("  ") }.to raise_error(ArgumentError, /blank/)
      expect { parse(" tmp") }.to raise_error(ArgumentError, /whitespace/)
      expect { parse("tmp\nx") }.to raise_error(ArgumentError, /control character/)
    end

    it "rejects an unbalanced brace and a value that names the worktree root, home or /" do
      expect { parse("/n/{workspace") }.to raise_error(ArgumentError, /unbalanced brace/)
      expect { parse("/n/workspace}") }.to raise_error(ArgumentError, /unbalanced brace/)
      %w[. ./ ~/ /].each { |value| expect { parse(value) }.to raise_error(ArgumentError, /not the worktree root/) }
    end

    it "rejects a placeholder other than {workspace} and {branch}" do
      expect { parse("/n/{project}") }.to raise_error(ArgumentError, /{project}.*{workspace}.*{branch}/)
    end
  end

  describe "reading attributes" do
    it "resolves a project key from the parent project's file and a global key from the global file" do
      expect(described_class.key("dev.up").resolve).to eq(:parent)
      expect(described_class.key("context.source").resolve).to eq(:global)
      expect(described_class.key("hooks", scope: :project).resolve).to eq(:own)
      expect(described_class.key("layouts", scope: :project).resolve).to eq(:merge)
      expect(described_class.key("notes.dir").resolve).to eq(:own_then_parent)
      expect(described_class.key("notes.default_dir")).to have_attributes(resolve: :parent, scope: :project, type: :path, settable: true, default: nil)
      expect(described_class.key("notes.dir").type).to eq(:path)
    end

    it "says global hooks are read by nothing" do
      expect(described_class.key("hooks", scope: :global).resolve).to eq(:none)
    end

    it "applies keys the daemon reads at startup on a daemon restart, hooks on the next event, the rest on the next call" do
      expect(described_class.key("alerts.notify").applies).to eq(:daemon_restart)
      expect(described_class.key("locks.ps_timeout").applies).to eq(:daemon_restart)
      expect(described_class.key("hooks", scope: :project).applies).to eq(:next_event)
      expect(described_class.key("dev.ready_timeout").applies).to eq(:next_call)
      expect(described_class.all.select { |key| key.applies == :daemon_restart }.map(&:name)).to include(*described_class.restart_required_names)
    end

    it "marks every key that holds a command or hook as sensitive and no duration or prompt" do
      sensitive = described_class.all.select(&:sensitive).map { |key| [key.name, key.scope] }
      expect(sensitive).to contain_exactly(
        ["dev.up", :project], ["dev.ready", :project], ["alerts.notify", :project], ["commands.test", :project], ["commands.lint", :project], ["statusline.command", :global],
        ["hooks", :global], ["hooks", :project], ["worktree_hooks", :project], ["pipeline", :project]
      )
    end

    it "gives every key a type" do
      expect(described_class.all.map(&:type).uniq - %i[command duration percent text path enum regex boolean mapping]).to eq([])
      expect(described_class.key("dev.stop_timeout").type).to eq(:duration)
    end
  end

  describe ".key" do
    it "picks the key of the given scope when a name is declared under both" do
      expect(described_class.key("hooks", scope: :global).scope).to eq(:global)
      expect(described_class.key("hooks", scope: :project).scope).to eq(:project)
    end

    it "returns nil for a name not declared under that scope" do
      expect(described_class.key("dev.up", scope: :global)).to be_nil
    end

    it "prefers a settable key when no scope is given" do
      expect(described_class.key("dev.up")).to be_settable
    end
  end

  describe ".default" do
    it "holds the default every reader falls back to" do
      expect(described_class.default("dev.stop_timeout")).to eq(20)
      expect(described_class.default("dev.startup_timeout")).to eq(30)
      expect(described_class.default("dev.ready_timeout")).to eq(120)
      expect(described_class.default("dev.kill_grace")).to eq(2)
      expect(described_class.default("locks.idle_grace")).to eq(300)
      expect(described_class.default("locks.ps_timeout")).to eq(5)
      expect(described_class.default("locks.reap_interval")).to eq(30)
      expect(described_class.default("alerts.idle_after")).to eq(600)
      expect(described_class.default("agentd.poll_interval")).to eq(10)
      expect(described_class.default("handoff.threshold")).to eq(11)
      expect(described_class.default("alerts.notify")).to be_nil
    end

    it "gives the two handoff prompts their built-in text as the default" do
      expect(described_class.default("handoff.check_prompt")).to start_with("%{usage} Update %{doc} now with").and include("%{new_cmd}")
      expect(described_class.default("handoff.resume_prompt")).to start_with("Read %{doc} and follow its").and end_with("yourself.")
      expect { format(described_class.default("handoff.check_prompt"), usage: "u", doc: "d", new_cmd: "n") }.not_to raise_error
      expect { format(described_class.default("handoff.resume_prompt"), doc: "d") }.not_to raise_error
    end
  end

  describe ".parse" do
    it "accepts an absolute notes.dir unchanged, keeping inner spaces" do
      expect(described_class.parse("notes.dir", "/Users/me/notes")).to eq("/Users/me/notes")
      expect(described_class.parse("notes.dir", "/Users/me/My Notes")).to eq("/Users/me/My Notes")
    end

    it "rejects a padded absolute notes.dir" do
      expect { described_class.parse("notes.dir", " /x ") }.to raise_error(ArgumentError, /leading or trailing whitespace/)
      expect { described_class.parse("notes.dir", "/x ") }.to raise_error(ArgumentError, /leading or trailing whitespace/)
    end

    it "rejects a notes.dir with a newline or other control character" do
      expect { described_class.parse("notes.dir", "/x\ny") }.to raise_error(ArgumentError, /newline or other control character/)
      expect { described_class.parse("notes.dir", "/x\ty") }.to raise_error(ArgumentError, /newline or other control character/)
    end

    it "rejects a blank, relative or tilde notes.dir" do
      expect { described_class.parse("notes.dir", "  ") }.to raise_error(ArgumentError, /must not be blank/)
      expect { described_class.parse("notes.dir", "notes/app") }.to raise_error(ArgumentError, /absolute path/)
      expect { described_class.parse("notes.dir", "~/notes") }.to raise_error(ArgumentError, /absolute path.*"~" is not expanded/)
    end

    it "parses durations and returns seconds" do
      expect(described_class.parse("dev.stop_timeout", "5m")).to eq(300.0)
      expect(described_class.parse("dev.stop_timeout", "0")).to eq(0.0)
    end

    it "requires positive durations where the key says so" do
      expect { described_class.parse("dev.ready_timeout", "0") }.to raise_error(ArgumentError, /greater than 0/)
      expect { described_class.parse("locks.idle_grace", "0") }.to raise_error(ArgumentError, /greater than 0/)
      expect { described_class.parse("agentd.poll_interval", "0") }.to raise_error(ArgumentError, /greater than 0/)
      expect(described_class.parse("agentd.poll_interval", "15s")).to eq(15.0)
    end

    it "caps and ranges durations" do
      expect { described_class.parse("dev.kill_grace", "61") }.to raise_error(ArgumentError, /at most 60s/)
      expect { described_class.parse("locks.ps_timeout", "0.5") }.to raise_error(ArgumentError, /at least 1s and at most 60s/)
      expect(described_class.parse("locks.ps_timeout", "1m")).to eq(60.0)
    end

    it "checks a handoff threshold, a notify command, a prompt and launch.headless" do
      expect(described_class.parse("handoff.threshold", "42")).to eq(42)
      expect { described_class.parse("handoff.threshold", "101") }.to raise_error(ArgumentError, /between 1 and 100/)
      expect(described_class.parse("alerts.notify", "  say hi ")).to eq("say hi")
      expect { described_class.parse("alerts.notify", " ") }.to raise_error(ArgumentError, /blank/)
      expect { described_class.parse("handoff.check_prompt", " ") }.to raise_error(ArgumentError, /blank/)
      expect(described_class.parse("launch.headless", "true")).to eq("true")
      expect { described_class.parse("launch.headless", "yes") }.to raise_error(ArgumentError, /"true" or "false"/)
      expect(described_class.parse("notes.instructions", "false")).to eq("false")
      expect(described_class.parse("notes.instructions", true)).to eq("true")
      expect { described_class.parse("notes.instructions", "maybe") }.to raise_error(ArgumentError, /"true" or "false"/)
      expect(described_class.default("notes.instructions")).to be(true)
      expect(described_class.parse("dev.instructions", "false")).to eq("false")
      expect { described_class.parse("dev.instructions", "maybe") }.to raise_error(ArgumentError, /"true" or "false"/)
      expect(described_class.default("dev.instructions")).to be(true)
    end

    it "checks context.source and context.pattern" do
      expect(described_class.parse("context.source", "scrape")).to eq("scrape")
      expect { described_class.parse("context.source", "x") }.to raise_error(ArgumentError, /"statusline" or "scrape"/)
      expect { described_class.parse("context.pattern", "no group") }.to raise_error(ArgumentError, /exactly one capture group/)
      expect { described_class.parse("context.pattern", "(") }.to raise_error(RegexpError)
      expect(described_class.parse("context.pattern", "(\\d+)% ctx")).to eq("(\\d+)% ctx")
      expect { described_class.parse("context.pattern", "[(]x(a)(b)") }.to raise_error(ArgumentError, /exactly one/)
    end

    it "reads workflows.defaults.include as pack names separated by commas or spaces, or as a list" do
      expect(described_class.parse("workflows.defaults.include", "binding, commits")).to eq(%w[binding commits])
      expect(described_class.parse("workflows.defaults.include", "binding play/house-rules")).to eq(%w[binding play/house-rules])
      expect(described_class.parse("workflows.defaults.include", %w[binding review])).to eq(%w[binding review])
      expect(described_class.default("workflows.defaults.include")).to eq(%w[binding orchestrator commits])
      ["", " , ", "Binding", "agent/x", "../x", [], [1], ["ok", ""]].each do |bad|
        expect { described_class.parse("workflows.defaults.include", bad) }.to raise_error(ArgumentError, /one or more pack names/)
      end
    end

    it "passes free-text keys through" do
      expect(described_class.parse("dev.up", "bin/dev")).to eq("bin/dev")
    end
  end

  describe "readers" do
    it "declares every key a reader fetches" do
      reader_keys = %w[dev_config lock_config alert_config agentd_config handoff_config].flat_map do |file|
        source = File.read(File.join(root, "lib/workspace/#{file}.rb"))
        section = {"dev_config" => "dev", "lock_config" => "locks", "alert_config" => "alerts",
                   "agentd_config" => "agentd", "handoff_config" => "handoff"}.fetch(file)
        source.scan(/ConfigSchema\.(?:key|default|parse)\("([a-z_.]+)"/).flatten.tap do |names|
          expect(names).to all(start_with("#{section}."))
        end
      end
      expect(reader_keys.uniq - described_class.all.map(&:name)).to eq([])
    end
  end
end

RSpec.describe Workspace::ConfigSchema, "layers and limits" do
  let(:legacy) { {global: %i[global], parent: %i[project], own_then_parent: %i[project worktree], own: %i[project worktree], merge: %i[project worktree], none: []} }

  it "gives every key the layers its resolve mode reads today" do
    expect(described_class.all).to all(satisfy { |key| key.overridable_in == legacy.fetch(key.resolve) })
    expect(described_class.key("notes.dir").overridable_in).to eq(%i[project worktree])
    expect(described_class.key("dev.up").overridable_in?("project")).to be true
    expect(described_class.key("dev.up").overridable_in?(:worktree)).to be false
  end

  it "declares choices for closed sets, seconds for durations, and limits where the parser has them" do
    expect(described_class.key("context.source").choices).to eq(%w[statusline scrape])
    expect(described_class.key("handoff.auto").choices).to eq(%w[true false])
    expect(described_class.key("dev.up").choices).to be_nil
    expect(described_class.all.select { |k| k.type == :duration }).to all(satisfy { |k| k.unit == "seconds" })
    expect(described_class.key("dev.up").unit).to be_nil
    threshold = described_class.key("handoff.threshold")
    expect([threshold.min, threshold.max]).to eq([1, 100])
    ps = described_class.key("locks.ps_timeout")
    expect([ps.min, ps.max]).to eq([described_class::MIN_PS_TIMEOUT, described_class::MAX_PS_TIMEOUT])
    expect(described_class.key("dev.kill_grace").max).to eq(described_class::MAX_KILL_GRACE)
  end
end
