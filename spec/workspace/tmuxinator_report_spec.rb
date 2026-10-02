require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::TmuxinatorReport do
  let(:dir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config) }

  # Answers like `tmux list-sessions` and `tmux list-panes -s`: sessions by
  # name, panes already split from tab-separated output.
  let(:tmux) do
    Class.new do
      attr_accessor :session_names, :panes

      def initialize
        @session_names = []
        @panes = []
      end

      def sessions(strict: false) = @session_names

      def pane_start_commands(_session) = @panes
    end.new
  end
  subject(:report) { described_class.new(config: config, tmux: tmux) }

  before { allow(config).to receive(:config_path_for) { |name| File.join(dir, "workspace.#{name}.yml") } }

  after { FileUtils.rm_rf(dir) }

  def write(name, text)
    File.write(File.join(dir, "workspace.#{name}.yml"), text)
  end

  let(:template) do
    <<~YAML
      # header
      name: api
      root: /src/api
      tmux_options: -CC
      attach: false
      on_project_start: |
        tmux resize-pane -t api:0.0 -y 15%

      startup_pane: 2

      windows:
        - workspace-api:
            layout: even-vertical
            panes:
              - |
                printf '\\033]2;workspace-api\\a' &&
                ascii-banner "api" --rainbow
              - claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions
              - echo 'Ready to work on api'
              -
              - workspace agentd --debug
    YAML
  end

  it "describes the session, windows and panes, with each pane's kind and 1-based line" do
    write("api", template)
    doc = report.show("api")

    expect(doc).to include("schema_version" => 1, "ok" => true, "workspace" => "api", "erb" => false, "parse_error" => nil, "applies" => "relaunch", "running" => false)
    expect(doc["etag"]).to start_with("sha256:")
    expect(doc["session"]).to include("name" => "api", "root" => "/src/api", "startup_pane" => 2, "tmux_options" => "-CC", "attach" => false)
    window = doc["windows"].first
    expect(window).to include("index" => 0, "name" => "workspace-api", "layout" => "even-vertical")
    expect(window["panes"].map { |p| [p["index"], p["kind"], p["line"]] }).to eq([[0, "banner", 15], [1, "claude", 18], [2, "command", 19], [3, "shell", 20], [4, "agentd", 21]])
    expect(window["panes"][3]["command"]).to be_nil
  end

  it "lists a claude pane's flags, and not a banner for a project named claude-tools" do
    write("claude-tools", "name: claude-tools\nwindows:\n  - w:\n      panes:\n        - ascii-banner \"claude-tools\"\n        - claude --continue --model opus || claude\n")
    panes = report.show("claude-tools")["windows"].first["panes"]

    expect(panes.map { |p| p["kind"] }).to eq(%w[banner claude])
    expect(panes[1]["flags"]).to eq(%w[--continue --model])
  end

  it "pairs panes with the live ones by position and reports the tmux pane id and start command" do
    write("api", template)
    tmux.session_names = ["api"]
    tmux.panes = [
      {window: 0, index: 1, id: "%25", start_command: "claude --continue"},
      {window: 0, index: 0, id: "%24", start_command: nil},
      {window: 1, index: 0, id: "%30", start_command: nil}
    ]

    doc = report.show("api")
    panes = doc["windows"].first["panes"]

    expect(doc["running"]).to be true
    expect(panes[0]["live"]).to eq("pane_id" => "%24", "start_command" => nil)
    expect(panes[1]["live"]).to eq("pane_id" => "%25", "start_command" => "claude --continue")
    expect(panes[2]["live"]).to be_nil
  end

  it "has no live panes when the session isn't running" do
    write("api", template)
    tmux.panes = [{window: 0, index: 0, id: "%24", start_command: nil}]

    expect(report.show("api")["windows"].first["panes"].map { |p| p["live"] }).to all(be_nil)
  end

  it "reports running as unknown when tmux doesn't answer" do
    write("api", template)
    allow(tmux).to receive(:sessions).and_raise(Workspace::Error, "tmux timed out")

    expect(report.show("api")["running"]).to be_nil
  end

  it "reads a titled pane and a list-of-commands pane" do
    write("api", "name: api\nwindows:\n  - w:\n      panes:\n        - build: make\n        - [cd src, ls]\n")
    panes = report.show("api")["windows"].first["panes"]

    expect(panes[0]).to include("title" => "build", "command" => "make")
    expect(panes[1]).to include("title" => nil, "command" => "cd src\nls")
  end

  it "handles a window with no panes key and a bare window name" do
    write("api", "name: api\nwindows:\n  - w:\n      layout: tiled\n  - plain\n")
    windows = report.show("api")["windows"]

    expect(windows.map { |w| [w["name"], w["layout"], w["panes"]] }).to eq([["w", "tiled", []], ["plain", nil, []]])
  end

  it "reads a window whose value is one command or a list of commands as a single pane, with its line" do
    write("api", "name: api\nwindows:\n  - editor: vim\n  - logs:\n      - ssh logs\n      - cd /var/logs\n")
    windows = report.show("api")["windows"]

    expect(windows.map { |w| w["panes"].map { |p| [p["command"], p["line"]] } }).to eq([[["vim", 3]], [["ssh logs\ncd /var/logs", 5]]])
    expect(windows.map { |w| w["layout"] }).to eq([nil, nil])
  end

  it "calls a pane that runs claude after a banner claude" do
    write("api", "name: api\nwindows:\n  - w:\n      panes:\n        - ascii-banner x; claude --continue\n")

    expect(report.show("api")["windows"].first["panes"].first).to include("kind" => "claude", "flags" => ["--continue"])
  end

  it "flags ERB without rendering it" do
    write("api", "name: api\nwindows:\n  - w:\n      panes:\n        - echo <%= 1 %>\n")

    expect(report.show("api")["erb"]).to be true
  end

  it "reports a file it can't parse as data" do
    write("api", "name: api\nwindows: [\n")
    doc = report.show("api")

    expect(doc["parse_error"]).to include("line" => 3, "column" => 1)
    expect(doc).to include("session" => nil, "windows" => [], "running" => nil)
  end

  it "raises unknown_workspace when the workspace has no tmuxinator file" do
    expect { report.show("nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
  end
end
