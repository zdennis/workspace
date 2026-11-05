require "spec_helper"
require "stringio"

RSpec.describe Workspace::Commands::AgentStatus do
  let(:output) { StringIO.new }
  let(:client) { double("client") }
  let(:tmux) do
    CLITestHelpers::FakeTmuxServer.new("api" => [{id: "%3", window: 0, index: 0}, {id: "%19", window: 0, index: 1}], "web" => [{id: "%7", window: 0, index: 0}])
  end
  let(:locator) { Workspace::PaneLocator.new(tmux: tmux) }
  let(:env) { {"TMUX_PANE" => "%19"} }

  subject(:command) { described_class.new(client: client, locator: locator, tmux: tmux, env: env, output: output) }

  describe ".parse_progress" do
    it "reads N/M into done and total" do
      expect(described_class.parse_progress("3/7")).to eq("done" => 3, "total" => 7)
      expect(described_class.parse_progress("0/1")).to eq("done" => 0, "total" => 1)
    end

    %w[7/3 3/0 -1/4 3 a/b 1.5/3 3/7/9].each do |value|
      it "refuses #{value} as a usage error" do
        expect { described_class.parse_progress(value) }.to raise_error(Workspace::UsageError, /--progress must be N\/M/)
      end
    end
  end

  describe "#request" do
    let(:reply) do
      {"ok" => true, "request_id" => "sr-abc", "expires_at" => "2026-10-17T22:10:00Z", "delivery" => "submitted", "pane" => "0.1", "pane_id" => "%19"}
    end

    it "resolves the pane in the workspace's own session, asks the daemon, and prints one document" do
      allow(client).to receive(:exchange_message).and_return(reply)

      command.request(name: "api", pane: "0.1", json: true)

      expect(client).to have_received(:exchange_message)
        .with("api", {"type" => "status_request", "pane_id" => "%19"}, timeout: described_class::REQUEST_TIMEOUT)
      expect(JSON.parse(output.string)).to eq({"schema_version" => 1, "ok" => true, "workspace" => "api"}.merge(reply.except("ok")))
    end

    it "prints the request id and where the reply shows without --json" do
      allow(client).to receive(:exchange_message).and_return(reply)

      command.request(name: "api", pane: "%19")

      expect(output.string).to include("request sr-abc").and include("events --follow --types agent_status")
    end

    it "refuses a pane of another session before asking the daemon" do
      allow(client).to receive(:exchange_message)

      expect { command.request(name: "api", pane: "%7") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("wrong_session") }
      expect(client).not_to have_received(:exchange_message)
    end

    it "raises the daemon's refusal with its code and the other fields as details" do
      allow(client).to receive(:exchange_message).and_return("ok" => false, "error" => "pane_not_ready", "message" => "nothing was typed: busy",
        "reason" => "waiting", "pane" => "0.1", "pane_id" => "%19")

      expect { command.request(name: "api", pane: "%19") }.to raise_error(Workspace::Error) { |e|
        expect([e.code, e.message, e.details]).to eq(["pane_not_ready", "nothing was typed: busy", {"reason" => "waiting", "pane" => "0.1", "pane_id" => "%19"}])
      }
    end

    it "raises not_submitted as the error that exits 2" do
      allow(client).to receive(:exchange_message).and_return("ok" => false, "error" => "not_submitted", "message" => "check", "request_id" => "sr-abc")

      expect { command.request(name: "api", pane: "%19") }.to raise_error(Workspace::Commands::Run::NotSubmittedError) { |e|
        expect(e.details).to include("request_id" => "sr-abc")
      }
    end

    it "says no_daemon when nothing answers, and connection_failed when it times out" do
      allow(client).to receive(:exchange_message).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("none", reason: :no_daemon))
      expect { command.request(name: "api", pane: "%19") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_daemon") }

      allow(client).to receive(:exchange_message).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("slow", reason: :timeout))
      expect { command.request(name: "api", pane: "%19") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("connection_failed") }
    end

    it "says unreadable_reply when the reply isn't JSON" do
      allow(client).to receive(:exchange_message).and_return(nil)

      expect { command.request(name: "api", pane: "%19") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unreadable_reply") }
    end
  end

  describe "#post" do
    let(:line) do
      {"ok" => true, "truncated" => false, "at" => "2026-10-17T22:01:00.000Z", "workspace" => "api", "pane_id" => "%19",
       "boot_id" => "BOOT", "seq" => 4, "summary" => "ok", "task" => "T3", "progress" => {"done" => 3, "total" => 7}, "reply_to" => "sr-abc"}
    end

    it "posts from $TMUX_PANE to the daemon of the pane's session and prints the line" do
      allow(client).to receive(:exchange_message).and_return(line)

      command.post(summary: "ok", task: "T3", progress: {"done" => 3, "total" => 7}, reply_to: "sr-abc", json: true)

      expect(client).to have_received(:exchange_message).with("api",
        {"type" => "status_post", "pane_id" => "%19", "summary" => "ok", "task" => "T3", "progress" => {"done" => 3, "total" => 7}, "reply_to" => "sr-abc"},
        timeout: described_class::POST_TIMEOUT)
      expect(JSON.parse(output.string)).to eq({"schema_version" => 1}.merge(line))
    end

    it "leaves out what wasn't given" do
      allow(client).to receive(:exchange_message).and_return(line.merge("reply_to" => nil))

      command.post(summary: "ok")

      expect(client).to have_received(:exchange_message).with("api", {"type" => "status_post", "pane_id" => "%19", "summary" => "ok"}, timeout: 5)
      expect(output.string).to eq("Posted status for pane %19.\n")
    end

    it "sends to the workspace whose session the pane is in, for a worktree whose session name differs" do
      allow(client).to receive(:exchange_message).and_return(line)
      worktree = described_class.new(client: client, locator: locator, tmux: tmux, env: env, output: output,
        workspace_for_session: ->(session) { (session == "api") ? "api.worktree-feature" : session })

      worktree.post(summary: "ok")

      expect(client).to have_received(:exchange_message).with("api.worktree-feature", anything, timeout: 5)
    end

    it "tells the caller to restart a daemon that predates agent status" do
      allow(client).to receive(:exchange_message).and_return("ok" => false, "error" => "unknown_type")

      expect { command.post(summary: "ok") }.to raise_error(Workspace::Error, /workspace agentd restart api/) { |e|
        expect(e.code).to eq("unknown_type")
      }
    end

    it "refuses outside a tmux pane with no_pane" do
      env.delete("TMUX_PANE")

      expect { command.post(summary: "ok") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_pane") }
    end

    it "refuses a pane in no session with not_in_workspace" do
      env["TMUX_PANE"] = "%99"

      expect { command.post(summary: "ok") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_in_workspace") }
    end

    it "raises a refused reply with the request id in details" do
      allow(client).to receive(:exchange_message).and_return("ok" => false, "error" => "status_reply_wrong_pane", "message" => "other pane", "request_id" => "sr-abc")

      expect { command.post(summary: "ok", reply_to: "sr-abc") }.to raise_error(Workspace::Error) { |e|
        expect([e.code, e.details]).to eq(["status_reply_wrong_pane", {"request_id" => "sr-abc"}])
      }
    end
  end
end
