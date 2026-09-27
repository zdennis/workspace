require "spec_helper"
require "tmpdir"
require "socket"

RSpec.describe Workspace::Commands::Handoff do
  # Unix socket paths cap at 104 bytes on macOS, so stay under /tmp directly.
  let(:tmpdir) { Dir.mktmpdir("ws-handoff-cmd", "/tmp") }
  let(:socket_path) { File.join(tmpdir, "workspace-myapp.sock") }
  let(:config) { instance_double(Workspace::Config, agent_socket_path: socket_path) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:handoff_config) { instance_double(Workspace::HandoffConfig) }
  let(:restart_agent_command) { instance_double(Workspace::Commands::RestartAgent) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  subject(:command) do
    described_class.new(config: config, tmux: tmux, handoff_config: handoff_config,
      restart_agent_command: restart_agent_command, output: output, error_output: error_output)
  end

  let(:defaults) { {threshold: 11, check_prompt: nil, resume_prompt: nil} }

  before do
    allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults)
    allow(tmux).to receive(:session_name_for).with("myapp").and_return("myapp")
  end

  after { FileUtils.remove_entry(tmpdir) }

  # Answers one "sessions" request with +panes+ and closes.
  def with_sessions(panes)
    server = UNIXServer.new(socket_path)
    thread = Thread.new do
      client = server.accept
      client.gets
      client.puts({"workspace" => "myapp", "panes" => panes}.to_json)
      client.close
    end
    yield
  ensure
    thread&.join(2)
    thread&.kill
    server&.close
  end

  let(:claude_pane) { {"index" => 1, "pane_id" => "%1", "kind" => "claude", "context_pct" => 5, "context_error" => nil} }

  describe "#check" do
    it "exits 0 and sends nothing when usage is under the threshold" do
      allow(tmux).to receive(:deliver)
      result = with_sessions([claude_pane]) { command.check(name: "myapp") }

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("5%", "under threshold")
      expect(tmux).not_to have_received(:deliver)
    end

    it "exits 1 and delivers a save-state prompt when usage is at/over the threshold" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
      over_pane = claude_pane.merge("context_pct" => 42)

      result = with_sessions([over_pane]) { command.check(name: "myapp", handoff_doc: "HANDOFF.md") }

      expect(result).to eq(exit_code: 1)
      expect(tmux).to have_received(:deliver).with("myapp", "0.1", a_string_including("HANDOFF.md", "workspace handoff new myapp --pane 1"))
      expect(output.string).to include("42%", "sent save-state prompt")
    end

    it "sends the prompt verbatim (via --handoff-prompt) instead of a doc" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
      over_pane = claude_pane.merge("context_pct" => 42)

      with_sessions([over_pane]) { command.check(name: "myapp", handoff_prompt: "Wrap up") }

      expect(tmux).to have_received(:deliver).with("myapp", "0.1", a_string_including("--handoff-prompt Wrap\\ up"))
    end

    it "lets the agent pick a doc path when neither is given" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
      over_pane = claude_pane.merge("context_pct" => 42)

      with_sessions([over_pane]) { command.check(name: "myapp") }

      expect(tmux).to have_received(:deliver).with("myapp", "0.1", a_string_including("PATH replaced by the doc's absolute path", "--handoff-doc PATH"))
    end

    it "skips detection when --context-pct is given" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))

      result = with_sessions([claude_pane]) { command.check(name: "myapp", context_pct: 99, handoff_doc: "HANDOFF.md") }

      expect(result).to eq(exit_code: 1)
      expect(output.string).to include("99%")
    end

    it "exits 2 and never sends a prompt when usage can't be determined" do
      allow(tmux).to receive(:deliver)
      unknown_pane = claude_pane.merge("context_pct" => nil, "context_error" => "no reading recorded")

      result = with_sessions([unknown_pane]) { command.check(name: "myapp") }

      expect(result).to eq(exit_code: 2)
      expect(tmux).not_to have_received(:deliver)
      expect(error_output.string).to include("reason: no reading recorded", "Fix:")
    end

    it "exits 2 with the reason and fix in the JSON payload instead of stderr" do
      unknown_pane = claude_pane.merge("context_pct" => nil, "context_error" => "no reading recorded")

      result = with_sessions([unknown_pane]) { command.check(name: "myapp", json: true) }

      expect(result).to eq(exit_code: 2)
      expect(error_output.string).to eq("")
      payload = JSON.parse(output.string)
      expect(payload).to include("status" => "undetermined", "reason" => "no reading recorded")
      expect(payload["fix"]).to include("statusLine")
    end

    it "exits 2 when no agent daemon is reachable" do
      result = command.check(name: "myapp")

      expect(result).to eq(exit_code: 2)
      expect(error_output.string).to include("no agent daemon for 'myapp'")
    end

    it "raises a usage error when the named pane doesn't exist" do
      with_sessions([claude_pane]) do
        expect { command.check(name: "myapp", pane: "9") }.to raise_error(Workspace::UsageError, /No pane 9/)
      end
    end

    it "picks the daemon's own threshold override" do
      allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults.merge(threshold: 50))

      result = with_sessions([claude_pane]) { command.check(name: "myapp") }

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("threshold 50%")
    end
  end

  describe "#new" do
    it "resolves the default Claude pane and delegates to restart_agent_command" do
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

      result = with_sessions([claude_pane]) { command.new(name: "myapp", handoff_doc: "HANDOFF.md") }

      expect(result).to eq(exit_code: 0)
      expect(restart_agent_command).to have_received(:call)
        .with(name: "myapp", pane: "1", prompt: a_string_including("HANDOFF.md", "Start here"), json: false)
    end

    it "uses an explicit --pane without needing the daemon" do
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

      result = command.new(name: "myapp", pane: "3", handoff_prompt: "Resume now")

      expect(result).to eq(exit_code: 0)
      expect(restart_agent_command).to have_received(:call).with(name: "myapp", pane: "3", prompt: "Resume now", json: false)
    end

    it "raises when no agent daemon is reachable and no pane was given" do
      expect { command.new(name: "myapp", handoff_doc: "HANDOFF.md") }.to raise_error(Workspace::Error, /no agent daemon/)
    end
  end
end
