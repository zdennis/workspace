RSpec.describe Workspace::AgentProvider do
  describe "#waiting_screen" do
    let(:codex) { described_class.find("codex") }

    it "names the reason for a sign-in, trust or approval screen" do
      expect(codex.waiting_screen("> 1. Sign in with ChatGPT\n  2. API key\n")).to include(reason: "sign_in")
      expect(codex.waiting_screen("Trust this folder?\n\n> 1. Trust and continue\n  2. Quit\n")).to include(reason: "trust")
      expect(codex.waiting_screen("Would you like to run the following command?\n\n> 1. Yes, proceed\n")).to include(reason: "approval")
    end

    it "is nil for ordinary output, a nil screen and a provider with no waiting screens" do
      expect(codex.waiting_screen("starting...\n")).to be_nil
      expect(codex.waiting_screen(nil)).to be_nil
      expect(described_class.find("claude").waiting_screen("> 1. Sign in with ChatGPT\n")).to be_nil
    end

    it "looks only at the last lines of the screen" do
      limit = described_class::SCREEN_WAIT_LINES
      prompt = "> 1. Sign in with ChatGPT\n"
      expect(codex.waiting_screen(prompt + ("filler\n" * limit))).to be_nil
      expect(codex.waiting_screen(prompt + ("filler\n" * (limit - 1)))).to include(reason: "sign_in")
    end
  end

  describe ".all" do
    it "includes Claude Code with hook support" do
      claude = described_class.find("claude")

      expect(claude.label).to eq("Claude Code")
      expect(claude.supports_hooks?).to be true
      expect(claude.settings_path).to eq(File.join(".claude", "settings.json"))
    end

    it "includes agents that have no hook system workspace can install into" do
      expect(described_class.find("opencode").supports_hooks?).to be false
      expect(described_class.find("pi").supports_hooks?).to be false
      expect(described_class.find("opencode").hook_events).to eq([])
      expect(described_class.find("pi").hook_events).to eq([])
    end

    it "gives Codex user-level hooks reporting every hook event type" do
      codex = described_class.find("codex")

      expect(codex.supports_hooks?).to be true
      expect(codex.user_scoped?).to be true
      expect(codex.hook_events).to eq(described_class::HOOK_EVENT_TYPES)
      expect(codex.hook_trust_hint).to include("/hooks")
      expect(described_class.find("claude").user_scoped?).to be false
      expect(described_class.find("claude").hook_events).to eq(described_class::HOOK_EVENT_TYPES)
    end

    it "only Claude Code supports statusLine routing" do
      expect(described_class.find("claude").supports_statusline?).to be true
      expect(described_class.find("codex").supports_statusline?).to be false
      expect(described_class.find("opencode").supports_statusline?).to be false
      expect(described_class.find("pi").supports_statusline?).to be false
    end

    it "returns nil for an unknown key" do
      expect(described_class.find("nope")).to be_nil
    end

    it "lists Escape as the interrupt key of Claude Code and Codex, and none for the agents not checked yet" do
      expect(%w[claude codex opencode pi].to_h { |key| [key, described_class.find(key).interrupt_keys] })
        .to eq("claude" => ["Escape"], "codex" => ["Escape"], "opencode" => [], "pi" => [])
    end

    it "gives Claude Code a ready pattern matching its prompt, but leaves other providers without one" do
      claude = described_class.find("claude")

      expect(claude.ready_pattern).to match(("─" * 20) + "\n❯ Try something")
      expect(claude.ready_pattern).to match(("─" * 20) + "\n❯\u00A0\n")
      expect(claude.ready_pattern).not_to match("Do you trust the files in this folder?\n│ ❯ 1. Yes │")
      expect(described_class.find("codex").ready_pattern).to be_nil
    end

    it "opts pi out of the path-segment matching heuristic" do
      expect(described_class.find("pi").path_segment_matching?).to be false
    end

    it "leaves path-segment matching on for the other providers" do
      expect(described_class.find("claude").path_segment_matching?).to be true
      expect(described_class.find("codex").path_segment_matching?).to be true
      expect(described_class.find("opencode").path_segment_matching?).to be true
    end

    it "has a unique executable per provider" do
      executables = described_class.all.map(&:executable)

      expect(executables.uniq).to eq(executables)
    end

    it "lets handoff clear and resume Claude Code and Codex, and a pane not identified yet" do
      expect(described_class.restartable_kinds).to eq(%w[claude codex unknown])
      expect(described_class.find("opencode").restartable?).to be false
      expect(described_class.find("pi").restartable?).to be false
    end

    it "types /clear for every agent, Codex included" do
      expect(described_class.all.map(&:clear_command).uniq).to eq(["/clear"])
    end

    it "reads Codex context from the percent used in its status footer" do
      codex = described_class.find("codex")

      expect(codex.context_remaining?).to be false
      expect(Regexp.new(codex.context_pattern).match("  gpt-5  Context 72% used · Context 28% left")[1]).to eq("72")
      expect(Regexp.new(codex.context_pattern).match("Context 0% used · Context 100% left")[1]).to eq("0")
      expect(Regexp.new(codex.context_pattern).match("72% context left")).to be_nil
      expect(described_class.find("claude").context_pattern).to be_nil
      expect(described_class.find("claude").context_remaining?).to be false
    end
  end

  describe "#hook_settings" do
    subject(:settings) { described_class.find("claude").hook_settings("workspace session-event") }

    it "routes every subscribed event to the command" do
      commands = settings["hooks"].values.flatten.flat_map { |e| e["hooks"] }.map { |h| h["command"] }

      expect(commands.uniq).to eq(["workspace session-event"])
    end

    it "matches every tool, not just Task, so any tool use marks a lock holder active" do
      expect(settings["hooks"]["PreToolUse"].first).not_to have_key("matcher")
    end

    it "omits the matcher for events that are not tool-scoped" do
      expect(settings["hooks"]["Stop"].first).not_to have_key("matcher")
    end

    it "subscribes to StopFailure, the turn that ended on an API error" do
      expect(settings["hooks"]).to include("StopFailure")
      expect(settings["hooks"]["StopFailure"].first).not_to have_key("matcher")
    end

    it "subscribes to Notification and PostToolUse, which start and end a pane's wait" do
      expect(settings["hooks"]).to include("Notification", "PostToolUse")
      expect(settings["hooks"]["PostToolUse"].first).not_to have_key("matcher")
    end

    it "subscribes to PermissionRequest without a matcher" do
      expect(settings["hooks"]["PermissionRequest"].first).not_to have_key("matcher")
    end

    it "subscribes to PostToolUseFailure, which ends a tool that failed or was interrupted" do
      expect(settings["hooks"]).to include("PostToolUseFailure")
      expect(settings["hooks"]["PostToolUseFailure"].first).not_to have_key("matcher")
    end

    it "gives Claude Code's hooks no timeout, as before" do
      expect(settings["hooks"].values.flatten.flat_map { |e| e["hooks"] }).to all(satisfy { |h| !h.key?("timeout") })
    end

    describe "for Codex" do
      subject(:settings) { described_class.find("codex").hook_settings("workspace session-event") }

      it "runs session-event naming the agent, for every Codex event workspace maps" do
        commands = settings["hooks"].values.flatten.flat_map { |e| e["hooks"] }.map { |h| h["command"] }

        expect(commands.uniq).to eq(["if [ -n \"$TMUX_PANE\" ]; then workspace session-event --agent codex; else cat >/dev/null; fi"])
        expect(settings["hooks"].keys).to contain_exactly("SessionStart", "SessionEnd", "UserPromptSubmit", "Stop",
          "Interrupt", "SubagentStart", "SubagentStop", "PreToolUse", "PermissionRequest", "PostToolUse")
      end

      it "sets a short timeout, at most 3 seconds where Codex allows no more" do
        timeout = ->(event) { settings["hooks"][event].first["hooks"].first["timeout"] }

        expect(timeout.call("PreToolUse")).to eq(10)
        expect(timeout.call("SessionEnd")).to eq(3)
        expect(timeout.call("Interrupt")).to eq(3)
      end
    end
  end

  describe "#hook_command for Codex" do
    let(:codex) { described_class.find("codex") }

    # A stand-in for `workspace session-event` that says it ran and exits 2,
    # as a denied edit does; the agent flag lands after the `:`.
    def run_hook(env)
      require "open3"
      Open3.capture3(env, "/bin/sh", "-c", codex.hook_command("printf ran; exit 2; :"), stdin_data: "{\"hook_event_name\":\"Stop\"}")
    end

    it "starts nothing outside a tmux pane, reads the payload, and exits 0" do
      out, err, status = run_hook({"TMUX_PANE" => nil})

      expect([out, err, status.exitstatus]).to eq(["", "", 0])
    end

    it "runs session-event in a tmux pane and passes its exit status on" do
      out, _err, status = run_hook({"TMUX_PANE" => "%3"})

      expect([out, status.exitstatus]).to eq(["ran", 2])
    end

    it "lists the unguarded command it used to install, so an upgrade replaces it" do
      expect(codex.hook_commands("workspace session-event"))
        .to eq([codex.hook_command("workspace session-event"), "workspace session-event --agent codex"])
      expect(described_class.find("claude").hook_commands("workspace session-event")).to eq(["workspace session-event"])
    end
  end

  describe "#user_config_path" do
    let(:codex) { described_class.find("codex") }

    it "is the hook file under the home directory" do
      expect(codex.user_config_path(env: {}, home: "/h")).to eq("/h/.codex/hooks.json")
    end

    it "follows CODEX_HOME, unless it is empty" do
      expect(codex.user_config_path(env: {"CODEX_HOME" => "/c"}, home: "/h")).to eq("/c/hooks.json")
      expect(codex.user_config_path(env: {"CODEX_HOME" => ""}, home: "/h")).to eq("/h/.codex/hooks.json")
      expect(codex.user_config_path(env: {"CODEX_HOME" => "rel"}, home: "/h")).to eq("/h/rel/hooks.json")
    end

    it "is nil for an agent whose hooks are per project" do
      expect(described_class.find("claude").user_config_path(env: {}, home: "/h")).to be_nil
    end
  end

  describe ".detect" do
    let(:claude) { described_class.find("claude") }

    def tree(*processes) = Workspace::ProcessTree::Snapshot.new(processes)

    it "does not know claude-dev without aliases" do
      expect(described_class.detect(command: "claude-dev", pid: 10, tree: tree({pid: 10, ppid: 1, command: "claude-dev", args: "claude-dev"}))).to be_nil
    end

    it "takes a pane running an aliased command as that agent" do
      found = described_class.detect(command: "claude-dev", pid: 10, tree: tree, aliases: {"claude" => ["claude-dev"]})

      expect(found).to eq(provider: claude, pid: 10)
    end

    it "finds an aliased command among a shell's descendants, by exact basename" do
      processes = [{pid: 10, ppid: 1, command: "zsh", args: "-zsh"},
        {pid: 11, ppid: 10, command: "node", args: "/opt/bin/claude-dev --continue"},
        {pid: 12, ppid: 10, command: "vim", args: "vim /src/claude-dev/notes.md"}]

      found = described_class.detect(command: "zsh", pid: 10, tree: tree(*processes), aliases: {"claude" => ["claude-dev"]})

      expect(found).to eq(provider: claude, pid: 11)
    end

    it "does not match an alias as a path segment" do
      processes = [{pid: 10, ppid: 1, command: "zsh", args: "-zsh"}, {pid: 11, ppid: 10, command: "ruby", args: "ruby /src/claude-dev/run.rb"}]

      expect(described_class.detect(command: "zsh", pid: 10, tree: tree(*processes), aliases: {"claude" => ["claude-dev"]})).to be_nil
    end

    it "ignores aliases for another kind" do
      expect(described_class.detect(command: "claude-dev", pid: 10, tree: tree, aliases: {"codex" => ["claude-dev"]})&.fetch(:provider)&.key).to eq("codex")
    end
  end

  describe "Codex waiting screens" do
    let(:screens) { described_class.find("codex").waiting_screens }

    def fixture(name) = File.read(File.expand_path("../fixtures/codex_screens/#{name}.txt", __dir__))

    it "names no waiting screens for the other agents" do
      expect(described_class.all.reject { |p| p.key == "codex" }.map(&:waiting_screens)).to all(be_empty)
    end

    it "matches each screen's fixture under one message" do
      expected = {
        "approval_command" => /approve a command/, "approval_patch" => /approve a command/,
        "trust_folder" => /trust this folder/, "trust_restricted" => /trust this folder/,
        "sign_in" => /sign in/, "sign_in_browser" => /sign in/, "sign_in_api_key" => /sign in/
      }
      expected.each do |name, message|
        matched = screens.select { |_, pattern| pattern.match?(fixture(name)) }.keys
        expect(matched.size).to eq(1), name
        expect(matched.first).to match(message)
      end
    end

    it "does not match ordinary output" do
      expect(screens.values.none? { |pattern| pattern.match?(fixture("ordinary_output")) }).to be(true)
    end
  end
end
