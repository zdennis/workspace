require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::PermissionEscalationDesk do
  let(:dir) { Dir.mktmpdir }
  let(:inbox) { Workspace::InboxStore.new(path: File.join(dir, "inbox.json"), scope: "workspace:ws", error_output: StringIO.new) }
  let(:config) { double("policy_config", configured?: true) }
  let(:monitor) { double("monitor", snapshot: {"panes" => [{"pane_id" => "%5", "waits" => []}]}) }
  let(:now) { Time.now }
  let(:desk) { described_class.new(inbox_store: inbox, policy_config: config, workspace: "ws", project: nil, monitor: monitor, clock: -> { now }) }

  after { FileUtils.remove_entry(dir) }

  def request(extra = {})
    {"event" => "permission_request", "pane_id" => "%5", "tool" => "Bash", "input" => "make deploy", "decision" => "ask", "rule" => "Bash:make *"}.merge(extra)
  end

  it "opens a real inbox item, then closes it on the next event, and reopens on the next request" do
    desk.session_event(request)
    item = inbox.list.first
    expect(item).to include("state" => "open", "type" => "alert", "dedupe_key" => "permission:ws:%5:main")
    expect(item["title"]).to eq("ws pane %5: Bash needs permission")

    desk.session_event({"event" => "tool_use", "pane_id" => "%5"})
    expect(inbox.list.first).to include("state" => "done")

    desk.session_event(request)
    expect(inbox.list.size).to eq(1)
    expect(inbox.list.first["state"]).to eq("open")
  end

  it "opens an item for a request with no decision under a real config whose permissions value is broken" do
    view = double("view", data_by_layer: {"project" => {"agent" => {"permissions" => {"default" => "bogus-action"}}}})
    resolver = double("resolver", view: view)
    real = Workspace::PermissionPolicyConfig.new(config_resolver: resolver, bound_run: double("bound_run", run_id_strict: nil),
      run_store: double("run_store"), logger: Workspace::Logger.new)
    broken = described_class.new(inbox_store: inbox, policy_config: real, workspace: "ws", project: nil, monitor: monitor, clock: -> { now })

    expect(real.policy(workspace: "ws", project: nil)).to be_nil
    broken.session_event(request("decision" => nil, "rule" => nil))

    expect(inbox.list.first).to include("state" => "open", "dedupe_key" => "permission:ws:%5:main")
  end

  it "closes an item on scan once the pane has stopped waiting" do
    desk.session_event(request)
    later = described_class.new(inbox_store: inbox, policy_config: config, workspace: "ws", project: nil, monitor: monitor, clock: -> { now + 120 })
    later.scan

    expect(inbox.list.first["state"]).to eq("done")
  end
end
