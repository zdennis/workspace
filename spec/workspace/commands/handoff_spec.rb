require "spec_helper"
require "tmpdir"
require "socket"

RSpec.describe Workspace::Commands::Handoff do
  # Unix socket paths cap at 104 bytes on macOS, so stay under /tmp directly.
  let(:tmpdir) { Dir.mktmpdir("ws-handoff-cmd", "/tmp") }
  let(:socket_path) { File.join(tmpdir, "workspace-myapp.sock") }
  let(:config) { instance_double(Workspace::Config, agent_socket_path: socket_path) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  # Stands in for the workspace's own tmux session "myapp": a pane id is
  # found as given, and "window.pane" is the pane whose id ends in that index.
  let(:locator) { instance_double(Workspace::PaneLocator) }
  let(:handoff_config) { instance_double(Workspace::HandoffConfig) }
  let(:restart_agent_command) { instance_double(Workspace::Commands::RestartAgent) }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:binder) { instance_double(Workspace::Commands::Binding, live: nil, bind: {}) }
  let(:library) { instance_double(Workspace::Library) }
  let(:notes_dir) { "/notes/myapp" }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  subject(:command) do
    described_class.new(config: config, tmux: tmux, locator: locator, handoff_config: handoff_config,
      restart_agent_command: restart_agent_command, notes: notes, binder: binder, library: library, output: output, error_output: error_output)
  end

  let(:defaults) { {threshold: 11, check_prompt: nil, resume_prompt: nil} }

  before do
    allow(notes).to receive(:info).and_return({"dir" => notes_dir})
    allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults)
    allow(tmux).to receive(:session_name_for).with("myapp").and_return("myapp")
    allow(locator).to receive(:locate) do |_name, spec|
      {id: spec.start_with?("%") ? spec : "%#{spec.split(".").last}", session: "myapp"}
    end
  end

  after { FileUtils.remove_entry(tmpdir) }

  # Answers one "sessions" request with +panes+ and closes.
  def with_sessions(panes)
    File.delete(socket_path) if File.exist?(socket_path)
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
      expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("HANDOFF.md", "workspace handoff new myapp --pane '%1'"))
      expect(output.string).to include("42%", "sent save-state prompt")
    end

    it "selects the pane by tmux pane id when --pane is a %N id" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
      other_pane = {"index" => 4, "pane_id" => "%9", "kind" => "claude", "context_pct" => 3, "context_error" => nil}
      over_pane = claude_pane.merge("index" => 7, "pane_id" => "%1", "context_pct" => 42)

      result = with_sessions([other_pane, over_pane]) { command.check(name: "myapp", pane: "%1", handoff_doc: "HANDOFF.md") }

      expect(result).to eq(exit_code: 1)
      expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("--pane '%1'"))
    end

    # The pane is looked up in the workspace's own tmux session, and the
    # prompt goes to the pane id found there. The daemon's index for a pane
    # is never a target: a daemon listing another session's panes would
    # point it at the wrong one.
    describe "finding the pane in the workspace's own session" do
      let(:over_pane) { claude_pane.merge("index" => 2, "pane_id" => "%7", "context_pct" => 42) }

      before { allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted)) }

      it "reads a bare index as a pane of window 0 and types into the pane id found there" do
        allow(locator).to receive(:locate).with("myapp", "0.3").and_return({id: "%7", session: "myapp-session"})

        with_sessions([over_pane]) { command.check(name: "myapp", pane: "3", json: true) }

        expect(tmux).to have_received(:deliver).with("myapp-session", "%7", a_string_including("--pane '%7'"))
        expect(JSON.parse(output.string)).to include("pane" => 2, "pane_id" => "%7")
      end

      it "accepts window.pane, for a pane outside window 0" do
        allow(locator).to receive(:locate).with("myapp", "1.0").and_return({id: "%7", session: "myapp"})

        with_sessions([over_pane]) { command.check(name: "myapp", pane: "1.0") }

        expect(tmux).to have_received(:deliver).with("myapp", "%7", anything)
      end

      it "types nothing when the daemon's default pane belongs to another session" do
        refusal = Workspace::Error.new("Pane %7 belongs to tmux session 'myapp-ui', not 'myapp' (workspace 'myapp').", code: "wrong_session")
        allow(locator).to receive(:locate).with("myapp", "%7").and_raise(refusal)

        with_sessions([over_pane]) do
          expect { command.check(name: "myapp") }.to raise_error(Workspace::Error, /belongs to tmux session 'myapp-ui'/) { |e| expect(e.code).to eq("wrong_session") }
        end
        expect(tmux).not_to have_received(:deliver)
      end

      it "types nothing when the named pane isn't in the workspace's session" do
        refusal = Workspace::Error.new("No pane 0.9 in tmux session 'myapp' (workspace 'myapp').", code: "no_such_pane")
        allow(locator).to receive(:locate).with("myapp", "0.9").and_raise(refusal)

        with_sessions([over_pane]) do
          expect { command.check(name: "myapp", pane: "9") }.to raise_error(Workspace::Error, /No pane 0.9/) { |e| expect(e.code).to eq("no_such_pane") }
        end
        expect(tmux).not_to have_received(:deliver)
      end

      it "exits 2 and types nothing when the daemon doesn't list the workspace's pane" do
        result = with_sessions([over_pane]) { command.check(name: "myapp", pane: "%3") }

        expect(result).to eq(exit_code: 2)
        expect(error_output.string).to include("the agent daemon for 'myapp' doesn't list pane %3 of tmux session 'myapp'",
          "workspace agentd restart myapp")
        expect(error_output.string).not_to include("statusLine")
        expect(tmux).not_to have_received(:deliver)
      end

      it "skips a listed Claude pane that has no pane id when picking the default" do
        with_sessions([claude_pane.merge("pane_id" => nil)]) do
          expect { command.check(name: "myapp") }.to raise_error(Workspace::UsageError, /No Claude Code or Codex pane found/)
        end
      end
    end

    it "sends the prompt verbatim (via --handoff-prompt) instead of a doc" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
      over_pane = claude_pane.merge("context_pct" => 42)

      with_sessions([over_pane]) { command.check(name: "myapp", handoff_prompt: "Wrap up") }

      expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("--handoff-prompt Wrap\\ up"))
    end

    describe "with neither --handoff-doc nor --handoff-prompt" do
      let(:over_pane) { claude_pane.merge("context_pct" => 42) }

      before { allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted)) }

      it "uses HANDOFF.md in the notes directory, made first, and names it in both commands" do
        with_sessions([over_pane]) { command.check(name: "myapp") }

        expect(notes).to have_received(:info).with(name: "myapp", create: true)
        expect(tmux).to have_received(:deliver).with("myapp", "%1",
          a_string_including("/notes/myapp/HANDOFF.md", "workspace handoff new myapp --pane '%1' --handoff-doc /notes/myapp/HANDOFF.md"))
      end

      it "still sends the prompt when the notes directory cannot be made" do
        allow(notes).to receive(:info).with(name: "myapp", create: true).and_raise(Workspace::Error.new("no room", code: "notes_dir_unresolved"))
        with_sessions([over_pane]) { command.check(name: "myapp") }

        expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("/notes/myapp/HANDOFF.md"))
        expect(error_output.string).to include("Warning", "no room")
      end

      it "falls back to letting the agent pick a path when the notes directory cannot be resolved" do
        allow(notes).to receive(:info).and_raise(Workspace::Error.new("detached", code: "notes_dir_unresolved"))
        result = with_sessions([over_pane]) { command.check(name: "myapp", json: true) }

        expect(result).to eq(exit_code: 1)
        expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("--handoff-doc PATH"))
        expect(JSON.parse(output.string)).to include("next" => "handoff", "doc" => nil)
      end

      it "leaves an explicit --handoff-doc alone and never asks for the notes directory" do
        with_sessions([over_pane]) { command.check(name: "myapp", handoff_doc: "/x/H.md") }

        expect(notes).not_to have_received(:info)
        expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("--handoff-doc /x/H.md"))
      end
    end

    describe "--json next and doc" do
      it "reports continue and the default doc under the threshold, without making the directory" do
        with_sessions([claude_pane]) { command.check(name: "myapp", json: true) }

        expect(JSON.parse(output.string)).to include("status" => "ok", "next" => "continue", "doc" => "/notes/myapp/HANDOFF.md")
        expect(notes).to have_received(:info).with(name: "myapp", create: false)
      end

      it "reports handoff and the doc given, expanded, when over the threshold" do
        allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
        with_sessions([claude_pane.merge("context_pct" => 42)]) { command.check(name: "myapp", json: true, handoff_doc: "/x/H.md") }

        expect(JSON.parse(output.string)).to include("status" => "handoff_sent", "next" => "handoff", "doc" => "/x/H.md")
      end

      it "reports handoff when the delivery failed" do
        allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :failed, message: "x"))
        with_sessions([claude_pane.merge("context_pct" => 42)]) { command.check(name: "myapp", json: true) }

        expect(JSON.parse(output.string)).to include("status" => "handoff_send_failed", "next" => "handoff")
      end

      it "reports unknown when usage cannot be read" do
        with_sessions([claude_pane.merge("context_pct" => nil, "context_error" => "no reading")]) { command.check(name: "myapp", json: true) }

        expect(JSON.parse(output.string)).to include("status" => "undetermined", "next" => "unknown", "doc" => "/notes/myapp/HANDOFF.md")
      end

      it "reports unknown when no daemon answers" do
        command.check(name: "myapp", json: true)

        expect(JSON.parse(output.string)).to include("next" => "unknown")
      end

      it "reports a null doc for --handoff-prompt" do
        with_sessions([claude_pane]) { command.check(name: "myapp", json: true, handoff_prompt: "Wrap up") }

        expect(JSON.parse(output.string)).to include("next" => "continue", "doc" => nil)
      end
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

    it "picks the daemon's own threshold override" do
      allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults.merge(threshold: 50))

      result = with_sessions([claude_pane]) { command.check(name: "myapp") }

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("threshold 50%")
    end

    it "rejects an out-of-range --context-pct instead of guessing" do
      with_sessions([claude_pane]) do
        expect { command.check(name: "myapp", context_pct: 101) }
          .to raise_error(Workspace::UsageError, /--context-pct must be between 0 and 100/)
      end
    end

    describe "a Codex pane" do
      let(:codex_pane) { claude_pane.merge("kind" => "codex", "pane_id" => "%4", "context_pct" => 42) }

      before { allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted)) }

      it "gets the save-state prompt like a Claude Code pane" do
        result = with_sessions([codex_pane]) { command.check(name: "myapp", pane: "%4", handoff_doc: "HANDOFF.md") }

        expect(result).to eq(exit_code: 1)
        expect(tmux).to have_received(:deliver).with("myapp", "%4", a_string_including("HANDOFF.md", "workspace handoff new myapp --pane '%4'"))
      end

      it "exits 0 under the threshold" do
        result = with_sessions([codex_pane.merge("context_pct" => 3)]) { command.check(name: "myapp", pane: "%4") }

        expect(result).to eq(exit_code: 0)
        expect(tmux).not_to have_received(:deliver)
      end

      it "is the default pane when no Claude Code pane is listed" do
        result = with_sessions([claude_pane.merge("kind" => "shell"), codex_pane]) { command.check(name: "myapp", handoff_doc: "HANDOFF.md") }

        expect(result).to eq(exit_code: 1)
        expect(tmux).to have_received(:deliver).with("myapp", "%4", anything)
      end

      it "is not the default pane while a Claude Code pane is listed" do
        over_claude = claude_pane.merge("context_pct" => 42)
        with_sessions([codex_pane, over_claude]) { command.check(name: "myapp", handoff_doc: "HANDOFF.md") }

        expect(tmux).to have_received(:deliver).with("myapp", "%1", anything)
      end

      it "hands `new` the Codex pane to restart when it is the only agent" do
        allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

        with_sessions([codex_pane]) { command.new(name: "myapp", handoff_doc: "HANDOFF.md") }

        expect(restart_agent_command).to have_received(:call).with(hash_including(name: "myapp", pane: "%4"))
      end
    end

    it "refuses an OpenCode pane, naming both agents handoff does restart" do
      allow(tmux).to receive(:deliver)

      with_sessions([claude_pane.merge("kind" => "opencode")]) do
        expect { command.check(name: "myapp", pane: "1") }
          .to raise_error(Workspace::UsageError, /is running opencode, not Claude Code or Codex/)
      end
      expect(tmux).not_to have_received(:deliver)
    end

    it "refuses to deliver into a pane that isn't running Claude Code" do
      allow(tmux).to receive(:deliver)
      shell_pane = claude_pane.merge("kind" => "shell")

      with_sessions([shell_pane]) do
        expect { command.check(name: "myapp", pane: "1") }
          .to raise_error(Workspace::UsageError, /is running shell, not Claude Code/)
      end
      expect(tmux).not_to have_received(:deliver)
    end

    it "reports a failed delivery distinctly from a successful one, in JSON and in text" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :failed, message: "tmux could not paste"))
      over_pane = claude_pane.merge("context_pct" => 42)

      json_result = with_sessions([over_pane]) { command.check(name: "myapp", handoff_doc: "HANDOFF.md", json: true) }
      expect(json_result).to eq(exit_code: 1)
      payload = JSON.parse(output.string)
      expect(payload).to include("status" => "handoff_send_failed", "landed" => false)

      text_result = with_sessions([over_pane]) { command.check(name: "myapp", handoff_doc: "HANDOFF.md") }
      expect(text_result).to eq(exit_code: 1)
      expect(error_output.string).to include("did not reach the pane")
    end

    it "falls back to the built-in template when a custom check_prompt has a bad placeholder" do
      allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults.merge(check_prompt: "Save %{oops}"))
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
      over_pane = claude_pane.merge("context_pct" => 42)

      with_sessions([over_pane]) { command.check(name: "myapp", handoff_doc: "HANDOFF.md") }

      expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("Update HANDOFF.md now"))
      expect(error_output.string).to include("invalid prompt template")
    end
  end

  describe "#check following up" do
    let(:over_pane) { claude_pane.merge("context_pct" => 42) }
    let(:defaults) do
      {threshold: 11, check_prompt: nil, resume_prompt: nil, followup_interval: 30, followup_max: 10, followup_prompt: nil}
    end
    let(:watch_requests) { [] }
    let(:delivered) { [] }

    before do
      allow(tmux).to receive(:deliver) do |_session, _pane, text|
        delivered << text
        Workspace::Tmux::Delivery.new(status: :submitted)
      end
    end

    # Answers the "sessions" request, then the next request with +watch_reply+ (a String; nil
    # leaves it unanswered, :partial writes half a line and waits, :gone closes the socket first), recording what that request said.
    def with_daemon(panes, watch_reply: {ok: true, watching: true, reason: nil}.to_json)
      File.delete(socket_path) if File.exist?(socket_path)
      server = UNIXServer.new(socket_path)
      thread = Thread.new do
        client = server.accept
        client.gets
        client.puts({"workspace" => "myapp", "panes" => panes}.to_json)
        client.close
        if watch_reply == :gone
          server.close
          File.delete(socket_path)
          next
        end
        client = begin
          server.accept
        rescue IOError
          next
        end
        watch_requests << JSON.parse(client.gets)
        client.puts(watch_reply) if watch_reply.is_a?(String)
        client.write('{"ok":tru') if watch_reply == :partial
        # Silent and partial daemons hold the connection until `check` gives up and closes it.
        client.read if watch_reply.nil? || watch_reply == :partial
        client.close
      end
      yield
    ensure
      server&.close
      thread&.join(2)
    end

    def check(**opts)
      result = nil
      with_daemon([over_pane], **opts.slice(:watch_reply)) do
        result = command.check(name: "myapp", handoff_doc: "HANDOFF.md", **opts.except(:watch_reply))
      end
      result
    end

    it "asks the daemon to watch the pane after a landed prompt" do
      sent_at = Time.now
      expect(check).to eq(exit_code: 1)

      request = watch_requests.first
      expect(request).to include("type" => "handoff_watch", "workspace" => "myapp", "pane_id" => "%1",
        "interval" => 30, "max" => 10, "sent_text" => delivered.first)
      expect(Time.iso8601(request["sent_at"])).to be_within(5).of(sent_at)
      expect(request["sent_at"]).to match(/\.\d{3}/)
      expect(request["text"]).to include("workspace handoff new myapp --pane '%1' --handoff-doc HANDOFF.md")
      expect(output.string).to include("follow up")
    end

    it "sends nothing to the daemon when the prompt did not land" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :failed))

      with_daemon([over_pane]) { command.check(name: "myapp", json: true) }

      expect(watch_requests).to be_empty
      expect(JSON.parse(output.string)).to include("status" => "handoff_send_failed").and(satisfy { |doc| !doc.key?("followup") })
    end

    it "puts followup in the --json document of a handoff_sent only" do
      check(json: true)
      document = JSON.parse(output.string)
      expect(document["followup"]).to eq("watching" => true, "reason" => nil)
      expect(document.keys - ["followup"]).to eq(%w[schema_version ok status context_pct threshold pane pane_id delivery landed next doc])
    end

    it "leaves followup out of the under-threshold and undetermined documents" do
      with_sessions([claude_pane]) { command.check(name: "myapp", json: true) }
      expect(JSON.parse(output.string)).not_to have_key("followup")
    end

    describe "skipping the watch" do
      it "skips with 'disabled' when followup_max is 0" do
        allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults.merge(followup_max: 0))
        check(json: true)
        expect(JSON.parse(output.string)["followup"]).to eq("watching" => false, "reason" => "disabled")
        expect(watch_requests).to be_empty
      end

      %w[run review].each do |kind|
        it "skips with 'bound_pane' for a #{kind} binding" do
          allow(binder).to receive(:live).with(pane: "%1").and_return({"kind" => kind})
          check(json: true)
          expect(JSON.parse(output.string)["followup"]).to eq("watching" => false, "reason" => "bound_pane")
          expect(watch_requests).to be_empty
        end
      end

      it "still watches a pane bound to a play" do
        allow(binder).to receive(:live).with(pane: "%1").and_return({"kind" => "play"})
        check(json: true)
        expect(JSON.parse(output.string)["followup"]).to eq("watching" => true, "reason" => nil)
      end

      it "skips with 'text_too_long' when the prompt would pass the daemon's 4,000 character limit" do
        result = check(json: true, handoff_prompt: "x" * 4000, handoff_doc: nil)
        expect(result).to eq(exit_code: 1)
        expect(JSON.parse(output.string)["followup"]).to eq("watching" => false, "reason" => "text_too_long")
        expect(watch_requests).to be_empty
        expect(delivered.size).to eq(1)
      end

      it "still exits 1 when looking up the binding raises" do
        allow(binder).to receive(:live).and_raise(Workspace::Error, "bindings unreadable")
        expect(check(json: true)).to eq(exit_code: 1)
        expect(JSON.parse(output.string)["followup"]).to eq("watching" => false, "reason" => "error")
        expect(error_output.string).to include("bindings unreadable")
      end

      it "reports the daemon's reason when it declines" do
        check(json: true, watch_reply: {ok: true, watching: false, reason: "not_claude"}.to_json)
        expect(JSON.parse(output.string)["followup"]).to eq("watching" => false, "reason" => "not_claude")
        expect(output.string).not_to include("will follow up")
      end

      describe "when the daemon does not take the request" do
        before { stub_const("#{described_class}::FOLLOWUP_REPLY_WAIT", 0.2) }

        let(:outcomes) do
          {
            dead: {watch_reply: :gone, reason: "no_daemon"},
            silent: {watch_reply: nil, reason: "no_reply"},
            partial: {watch_reply: :partial, reason: "no_reply"},
            old: {watch_reply: {ok: false, error: "unknown_type"}.to_json, reason: "unsupported_daemon"}
          }
        end

        it "reports the same handoff_sent status and exit code whichever way" do
          outcomes.each_value do |outcome|
            output.truncate(0)
            output.rewind
            expect(check(json: true, watch_reply: outcome[:watch_reply])).to eq(exit_code: 1)
            document = JSON.parse(output.string)
            expect(document).to include("status" => "handoff_sent", "landed" => true)
            expect(document["followup"]).to eq("watching" => false, "reason" => outcome[:reason])
          end
        end

        it "warns once when the daemon is gone" do
          check(json: true, watch_reply: :gone)
          expect(error_output.string.scan("Warning").size).to eq(1)
        end

        it "warns once, within the limit, when the daemon is silent" do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          check(json: true, watch_reply: nil)
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
          expect(error_output.string.scan("Warning").size).to eq(1)
        end

        it "gives up on a daemon that writes half a line instead of waiting for the rest" do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          check(json: true, watch_reply: :partial)
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
          expect(error_output.string.scan("Warning").size).to eq(1)
        end

        it "does not warn about an old daemon" do
          check(json: true, watch_reply: outcomes[:old][:watch_reply])
          expect(error_output.string).to eq("")
        end
      end

      it "does not warn when the daemon declines" do
        check(json: true, watch_reply: {ok: true, watching: false, reason: "not_claude"}.to_json)
        expect(error_output.string).to eq("")
      end

      it "gives the reason 'unknown' when the daemon declines without one" do
        check(json: true, watch_reply: {ok: true, watching: false}.to_json)
        expect(JSON.parse(output.string)["followup"]).to eq("watching" => false, "reason" => "unknown")
        output.truncate(0)
        output.rewind
        check(json: true, watch_reply: {ok: true, watching: false, reason: ""}.to_json)
        expect(JSON.parse(output.string)["followup"]).to eq("watching" => false, "reason" => "unknown")
      end
    end

    describe "the command the follow-up names" do
      it "keeps --handoff-prompt, shell-quoted, when a prompt is given" do
        check(handoff_prompt: "resume it", handoff_doc: nil)
        expect(watch_requests.first["text"]).to include("workspace handoff new myapp --pane '%1' --handoff-prompt resume\\ it")
      end

      it "leaves the plan to be found, as the save-state prompt does" do
        File.write(File.join(tmpdir, "IMPLEMENTATION_PLAN.md"), "x")
        allow(notes).to receive(:info).and_return({"dir" => tmpdir})
        with_daemon([over_pane]) { command.check(name: "myapp") }
        expect(watch_requests.first["text"]).to include("workspace handoff new myapp --pane '%1'")
        expect(watch_requests.first["text"]).not_to include("--handoff-doc")
      end

      it "keeps the --handoff-doc PATH the path-picking prompt shows" do
        allow(notes).to receive(:info).and_raise(Workspace::Error, "no notes dir")
        with_daemon([over_pane]) { command.check(name: "myapp") }
        expect(delivered.first).to include("--pane '%1' --handoff-doc PATH")
        expect(watch_requests.first["text"]).to include("workspace handoff new myapp --pane '%1' --handoff-doc PATH")
      end
    end

    describe "the follow-up template" do
      let(:built_in) { format(Workspace::ConfigSchema.default("handoff.followup_prompt"), new_cmd: "workspace handoff new myapp --pane '%1' --handoff-doc HANDOFF.md") }

      it "uses handoff.followup_prompt with %{new_cmd}" do
        allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults.merge(followup_prompt: "Handing off? Run %{new_cmd}"))
        check
        expect(watch_requests.first["text"]).to eq("Handing off? Run workspace handoff new myapp --pane '%1' --handoff-doc HANDOFF.md")
      end

      it "falls back to the schema's default text, with a warning, when the template is bad" do
        allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults.merge(followup_prompt: "50% sure, run %{new_cmd} %{usage}"))
        check
        expect(watch_requests.first["text"]).to eq(built_in)
        expect(error_output.string).to match(/invalid prompt template/)
      end

      it "uses the schema's default when none is set" do
        check
        expect(watch_requests.first["text"]).to eq(built_in)
      end
    end
  end

  describe "#new" do
    it "resolves the default Claude pane and delegates to restart_agent_command" do
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

      result = with_sessions([claude_pane]) { command.new(name: "myapp", handoff_doc: "HANDOFF.md") }

      expect(result).to eq(exit_code: 0)
      expect(restart_agent_command).to have_received(:call)
        .with(name: "myapp", pane: "%1", prompt: a_string_including("HANDOFF.md", "Start here"), wait: false, json: false)
    end

    it "passes a pane id straight to restart_agent_command" do
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

      command.new(name: "myapp", pane: "%2", handoff_doc: "HANDOFF.md")

      expect(restart_agent_command).to have_received(:call)
        .with(name: "myapp", pane: "%2", prompt: a_string_including("HANDOFF.md"), wait: false, json: false)
    end

    it "uses an explicit --pane without needing the daemon" do
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

      result = command.new(name: "myapp", pane: "3", handoff_prompt: "Resume now")

      expect(result).to eq(exit_code: 0)
      expect(restart_agent_command).to have_received(:call).with(name: "myapp", pane: "3", prompt: "Resume now", wait: false, json: false)
    end

    it "passes wait: through to restart_agent_command" do
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

      command.new(name: "myapp", pane: "3", handoff_prompt: "Resume now", wait: true)

      expect(restart_agent_command).to have_received(:call).with(name: "myapp", pane: "3", prompt: "Resume now", wait: true, json: false)
    end

    it "resumes from HANDOFF.md in the notes directory when neither flag is given" do
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

      command.new(name: "myapp", pane: "%2")

      expect(restart_agent_command).to have_received(:call)
        .with(name: "myapp", pane: "%2", prompt: a_string_including("/notes/myapp/HANDOFF.md", "Start here"), wait: false, json: false)
    end

    it "passes on the notes error when neither flag is given and no directory resolves" do
      allow(notes).to receive(:info).and_raise(Workspace::Error.new("detached", code: "notes_dir_unresolved"))

      expect { command.new(name: "myapp", pane: "%2") }.to raise_error(Workspace::Error, "detached")
    end

    it "raises when the daemon lists no Claude pane and no pane was given" do
      with_sessions([claude_pane.merge("kind" => "shell")]) do
        expect { command.new(name: "myapp", handoff_doc: "HANDOFF.md") }.to raise_error(Workspace::UsageError, /No Claude Code or Codex pane found/)
      end
    end

    it "raises when no agent daemon is reachable and no pane was given" do
      expect { command.new(name: "myapp", handoff_doc: "HANDOFF.md") }.to raise_error(Workspace::Error, /no agent daemon/)
    end

    it "substitutes %{doc} into a configured resume_prompt override" do
      allow(handoff_config).to receive(:for_workspace).with("myapp").and_return(defaults.merge(resume_prompt: "Resume from %{doc} please"))
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

      command.new(name: "myapp", pane: "1", handoff_doc: "HANDOFF.md")

      expect(restart_agent_command).to have_received(:call).with(name: "myapp", pane: "1", prompt: "Resume from HANDOFF.md please", wait: false, json: false)
    end
  end
  describe "when the workspace has a plan" do
    let(:notes_dir) { File.join(tmpdir, "notes") }
    let(:plan_path) { File.join(notes_dir, "IMPLEMENTATION_PLAN.md") }
    let(:over_pane) { claude_pane.merge("context_pct" => 42) }
    let(:play) { {"ref" => "play/implementation-plan", "scope" => "builtin", "path" => "/lib/library/play/implementation-plan.md"} }

    before do
      FileUtils.mkdir_p(notes_dir)
      File.write(plan_path, "---\nplan: 1\n---\n\n## Tasks\n\n- [ ] T1 First\n")
      allow(library).to receive(:pack).with("implementation-plan", cwd: nil).and_return([play, "body"])
      allow(library).to receive(:play_binding) do |entry, packs: []|
        base = {"kind" => "play", "id" => entry["ref"], "instructions" => entry["path"]}
        packs.any? ? base.merge("packs" => packs) : base
      end
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
      allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})
    end

    describe "check" do
      it "names the plan, not HANDOFF.md, and leaves the new command to find it so the pane is bound" do
        with_sessions([over_pane]) { command.check(name: "myapp") }

        expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including(plan_path, "workspace handoff new myapp --pane '%1'"))
        expect(tmux).not_to have_received(:deliver).with(anything, anything, a_string_including("HANDOFF.md", "--handoff-doc"))
      end

      it "tells the agent not to run new when the plan is paused" do
        with_sessions([over_pane]) { command.check(name: "myapp") }

        expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("If the plan's status: is paused, write the doc and end your turn without running that command."))
      end

      it "adds no paused note for an explicit doc" do
        with_sessions([over_pane]) { command.check(name: "myapp", handoff_doc: "/x/H.md") }

        expect(tmux).not_to have_received(:deliver).with(anything, anything, a_string_including("paused"))
      end

      it "reports the plan as doc in --json, under the threshold and over it" do
        with_sessions([claude_pane]) { command.check(name: "myapp", json: true) }
        expect(JSON.parse(output.string)).to include("next" => "continue", "doc" => plan_path)

        output.truncate(0)
        output.rewind
        with_sessions([over_pane]) { command.check(name: "myapp", json: true) }
        expect(JSON.parse(output.string)).to include("next" => "handoff", "doc" => plan_path)
      end

      it "keeps an explicit --handoff-doc over the plan" do
        with_sessions([over_pane]) { command.check(name: "myapp", handoff_doc: "/x/H.md", json: true) }

        expect(JSON.parse(output.string)).to include("doc" => "/x/H.md")
        expect(tmux).to have_received(:deliver).with("myapp", "%1", a_string_including("--handoff-doc /x/H.md"))
      end

      it "keeps HANDOFF.md when the notes directory has no plan file" do
        File.delete(plan_path)
        with_sessions([claude_pane]) { command.check(name: "myapp", json: true) }

        expect(JSON.parse(output.string)).to include("doc" => File.join(notes_dir, "HANDOFF.md"))
      end

      it "does not take a directory named like the plan for a plan" do
        File.delete(plan_path)
        Dir.mkdir(plan_path)
        with_sessions([claude_pane]) { command.check(name: "myapp", json: true) }

        expect(JSON.parse(output.string)).to include("doc" => File.join(notes_dir, "HANDOFF.md"))
      end
    end

    describe "new" do
      it "resumes from the plan and binds the pane to the plan play before the restart" do
        order = []
        allow(binder).to receive(:bind) { |**| order << :bind }
        allow(restart_agent_command).to receive(:call) { |**| (order << :restart) && {exit_code: 0} }

        command.new(name: "myapp", pane: "%2")

        expect(binder).to have_received(:bind).with(hash_including({workspace: "myapp", pane: "%2"}.merge("kind" => "play", "id" => "play/implementation-plan",
          "instructions" => play["path"])))
        expect(restart_agent_command).to have_received(:call).with(name: "myapp", pane: "%2", prompt: a_string_including(plan_path), wait: false, json: false)
        expect(order).to eq(%i[bind restart])
      end

      it "binds the pane the daemon names when no --pane is given" do
        with_sessions([claude_pane]) { command.new(name: "myapp") }

        expect(binder).to have_received(:bind).with(hash_including(workspace: "myapp", pane: "%1"))
      end

      it "keeps the packs a play binding already has" do
        allow(binder).to receive(:live).with(pane: "%2").and_return({"kind" => "play", "id" => "play/notes", "packs" => %w[notes handoff]})

        command.new(name: "myapp", pane: "%2")

        expect(binder).to have_received(:bind).with(hash_including("id" => "play/implementation-plan", "packs" => %w[notes handoff]))
      end

      it "leaves a run or review binding as it is" do
        allow(binder).to receive(:live).with(pane: "%2").and_return({"kind" => "run", "id" => "wr_1"})

        command.new(name: "myapp", pane: "%2")

        expect(binder).not_to have_received(:bind)
        expect(restart_agent_command).to have_received(:call)
      end

      it "does not bind or change anything for an explicit --handoff-doc" do
        command.new(name: "myapp", pane: "%2", handoff_doc: "/x/H.md")

        expect(binder).not_to have_received(:bind)
        expect(restart_agent_command).to have_received(:call).with(hash_including(prompt: a_string_including("/x/H.md")))
      end

      it "does not bind for --handoff-prompt" do
        command.new(name: "myapp", pane: "%2", handoff_prompt: "Resume now")

        expect(binder).not_to have_received(:bind)
      end

      it "does not bind when there is no plan, and resumes from HANDOFF.md" do
        File.delete(plan_path)

        command.new(name: "myapp", pane: "%2")

        expect(binder).not_to have_received(:bind)
        expect(restart_agent_command).to have_received(:call).with(hash_including(prompt: a_string_including(File.join(notes_dir, "HANDOFF.md"))))
      end

      [Workspace::Error.new("pane gone", code: "pane_not_found"), Errno::EACCES.new("bindings.json")].each do |error|
        it "warns and still restarts when the binding fails with #{error.class}" do
          allow(binder).to receive(:bind).and_raise(error)

          result = command.new(name: "myapp", pane: "%2")

          expect(result).to eq(exit_code: 0)
          expect(error_output.string).to include("Warning: could not bind pane %2 to the plan play")
        end
      end

      it "warns and still restarts when the plan play cannot be read" do
        allow(library).to receive(:pack).and_raise(Workspace::Error.new("gone", code: "library_source_missing"))

        command.new(name: "myapp", pane: "%2")

        expect(error_output.string).to include("Warning: could not bind pane %2 to the plan play", "gone")
        expect(restart_agent_command).to have_received(:call)
      end
    end
  end

  describe "the built-in play" do
    let(:play_dir) { File.expand_path("../../../lib/library/play", __dir__) }

    it "ships implementation-plan with a description and the task syntax" do
      text = File.read(File.join(play_dir, "implementation-plan.md"))

      expect(text).to start_with("---\ndescription: ")
      expect(text).to include("workspace plan path", "workspace plan init --title", "workspace plan status", "workspace plan start",
        "- [ ] T1 Short title in the imperative", "`[~]` in progress")
    end

    it "ends the turn on a paused plan in both the plan play and the handoff pack" do
      expect(File.read(File.join(play_dir, "implementation-plan.md"))).to include("Do not run `workspace handoff new`")
      expect(File.read(File.join(play_dir, "handoff.md")))
        .to include("If the plan's `status:` is `paused`, write the doc and end your turn without running `handoff new`.")
    end
  end

  describe "the built-in packs" do
    let(:pack_dir) { File.expand_path("../../../lib/library/play", __dir__) }

    it "has the handoff pack leave the doc and the threshold to the command, as the command now does" do
      text = File.read(File.join(pack_dir, "handoff.md"))

      expect(text).to include('workspace handoff check --pane "$TMUX_PANE"', "workspace handoff new")
      expect(text).not_to include("--handoff-doc", "DOC", "--threshold ")
    end

    it "has the notes pack name the same doc for a handoff and keep the plan apart" do
      text = File.read(File.join(pack_dir, "notes.md"))

      expect(text).to include("`IMPLEMENTATION_PLAN.md`", "`HANDOFF.md`")
    end
  end
end
