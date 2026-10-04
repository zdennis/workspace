require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::Restore do
  # Behaves like a tmux server: pane ids are never reused within a server, a
  # split puts the new pane right after its target, renumbers the ones after
  # it and halves the target's height, a pane under 3 rows can't be split
  # ("no space for a new pane"), a layout evens the heights out, and a
  # layout with fewer panes than the window is refused.
  let(:tmux_class) do
    Class.new do
      attr_reader :delivered, :layouts, :split_count, :last_error
      attr_accessor :rows, :delivery_status, :sessions_error, :server_pid, :pane_base

      def initialize
        @windows = {}
        @next_id = 0
        @delivered = []
        @layouts = []
        @split_count = 0
        @delivery_status = :submitted
        @server_pid = "500"
        @pane_base = 0
      end

      def add_session(name, panes, window: 0)
        @windows[name] ||= {}
        @windows[name][window] = panes.map { |command| new_pane(command) }
        even_out(@windows[name][window], 1)
      end

      def add_pane(name, command, window: 0) = @windows[name][window] << new_pane(command)

      def server_pid_for_pane(_pane_id) = server_pid

      attr_writer :session_names

      def session_name_for(name) = (@session_names || {}).fetch(name, name)

      def sessions(strict: false)
        raise Workspace::Error, sessions_error if sessions_error
        @windows.keys
      end

      def pane_details(session, window: "0")
        windows = @windows.fetch(session, {})
        windows = windows.slice(window.to_i) unless window.nil?
        windows.sort.flat_map do |index, panes|
          panes.each_with_index.map { |pane, pane_index| pane.merge(window: index, index: pane_index + pane_base, cwd: "/", title: "") }
        end
      end

      def split_window(session, window: "0", pane: nil, vertical: false)
        panes = @windows.dig(session, window.to_i)
        return nil if panes.nil? || (pane && panes[pane - pane_base].nil?)

        target = pane ? panes[pane - pane_base] : panes.last
        if rows && target[:height] < 3
          @last_error = "no space for a new pane"
          return nil
        end

        @split_count += 1
        at = panes.index(target) + 1
        panes.insert(at, new_pane("zsh"))
        panes[at][:height] = (target[:height] - 1) / 2 if rows
        target[:height] -= panes[at][:height] + 1 if rows
        at + pane_base
      end

      def apply_layout(session, layout, window: "0")
        @layouts << [session, window, layout]
        panes = @windows.dig(session, window.to_i)
        return false if layout != "tiled" && layout.scan(/\d+x\d+,\d+,\d+,\d+/).size < panes.size

        even_out(panes, (layout == "tiled") ? Math.sqrt(panes.size).ceil : 1)
        true
      end

      def deliver(session, pane, text, enter: true)
        @delivered << [session, pane, text]
        Workspace::Tmux::Delivery.new(status: delivery_status, message: "delivery #{delivery_status}")
      end

      def pane_start_commands(_session) = []

      def pid_of(pane_id) = @windows.values.flat_map(&:values).flatten.find { |pane| pane[:id] == pane_id }[:pid]

      private

      # Panes share the window's rows, one separator row between stacked panes.
      def even_out(panes, columns)
        return unless rows

        stacked = (panes.size / columns.to_f).ceil
        panes.each { |pane| pane[:height] = (rows - (stacked - 1)) / stacked }
      end

      def new_pane(command)
        id = "%#{@next_id}"
        @next_id += 1
        {id: id, pid: 1000 + @next_id, command: command}
      end
    end
  end

  let(:dir) { Dir.mktmpdir }
  let(:tmux) { tmux_class.new }
  let(:ledger) { Workspace::SessionLedger.new(path: File.join(dir, "state", "ledger.jsonl")) }
  let(:bindings) { Workspace::PaneBindings.new(path: File.join(dir, "state", "bindings.json")) }
  let(:config) { instance_double(Workspace::Config) }
  let(:report) { Workspace::TmuxinatorReport.new(config: config, tmux: tmux) }
  let(:processes) { [] }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:now) { [0.0] }
  let(:sleeps) { [] }
  let(:cwd) { File.join(dir, "checkout") }
  let(:launched) { [] }
  let(:ensured) { [] }
  let(:ensure_result) { Workspace::Commands::EnsureAgent::Result.new(:running) }
  let(:ensurer) do
    lambda do |name:|
      ensured << name
      ensure_result
    end
  end

  subject(:restore) do
    described_class.new(ledger: ledger, tmux: tmux, pane_bindings: bindings, tmuxinator_report: report, process_tree: process_tree, agent_ensurer: ensurer,
      sleeper: ->(seconds) {
        sleeps << seconds
        now[0] += seconds
      }, clock: -> { now[0] }, output: output, error_output: error_output)
  end

  before do
    FileUtils.mkdir_p(cwd)
    allow(config).to receive(:config_path_for) { |name| File.join(dir, "workspace.#{name}.yml") }
    allow(process_tree).to receive(:snapshot) { Workspace::ProcessTree::Snapshot.new(processes) }
    write_config("api")
  end

  after { FileUtils.rm_rf(dir) }

  def sid(number) = format("00000000-0000-4000-8000-%012d", number)

  def write_config(name, session: name, third: "echo ready", claude: "claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions")
    File.write(File.join(dir, "workspace.#{name}.yml"), <<~YAML)
      name: #{session}
      root: #{cwd}
      windows:
        - workspace-#{name}:
            panes:
              - ascii-banner #{name}
              - #{claude}
              - #{third}
              - workspace agentd
    YAML
  end

  # Writes a ledger line as the session-event hook does. The tmux server it
  # names is an earlier one than the fake's ("500") unless a spec says
  # otherwise: restore mostly runs after a tmux restart. nil is an entry
  # written before the server was recorded.
  def started(slot, session_id, tmux_server: "400", **extra)
    ledger.record({"event" => "session_start", "workspace" => slot[/\A[^:]+/], "pane_slot" => slot, "session_id" => session_id,
                   "tmux_server" => tmux_server, "cwd" => cwd}.merge(extra.transform_keys(&:to_s)))
  end

  def ended(slot, session_id, reason)
    ledger.record("event" => "session_end", "workspace" => slot[/\A[^:]+/], "pane_slot" => slot, "session_id" => session_id, "reason" => reason)
  end

  # A session as its config leaves it: banner shell, the agent, a shell, the daemon.
  def running_session(name = "api", commands = %w[zsh 2.1.289 zsh ruby])
    tmux.add_session(name, commands)
    tmux.pane_details(name, window: nil).each do |pane|
      agent = pane[:command] == "2.1.289"
      processes << {pid: pane[:pid], ppid: 1, command: pane[:command], args: agent ? "claude --dangerously-skip-permissions --continue" : "-#{pane[:command]}"}
    end
  end

  def call(names = ["api"], **options)
    restore.call(names, **options) do |missing|
      launched.concat(missing)
      missing.each { |name| running_session(name) }
      {}
    end
  end

  def rows(result, kind = "pane") = result[:results].select { |row| row["kind"] == kind }

  def layout(cells) = "abcd,80x24,0,0[" + (1..cells).map { |i| "80x5,0,#{i},#{i}" }.join(",") + "]"

  describe "--dry-run" do
    it "reports what it would do for a session that is not running, and changes nothing" do
      started("api:0.1", sid(1), pane_id: "%1")
      started("api:0.4", sid(2), pane_id: "%7")

      result = call(dry_run: true)

      expect(result).to include(exit_code: 0, status: "dry_run", extra: {"dry_run" => true, "unmatched" => []})
      expect(rows(result, "workspace")).to contain_exactly(include("workspace" => "api", "outcome" => "would_launch", "slot" => nil))
      expect(rows(result)).to match([
        include("slot" => "api:0.1", "outcome" => "skipped", "reason" => "config_pane", "session_id" => sid(1), "restored_slot" => nil),
        include("slot" => "api:0.4", "outcome" => "would_restore", "placement" => "appended", "restored_slot" => "api:0.4", "session_id" => sid(2), "cwd" => cwd, "pane" => nil)
      ])
      expect(launched).to eq([])
      expect(tmux.split_count).to eq(0)
      expect(tmux.delivered).to eq([])
      expect(File.exist?(File.join(dir, "state", "bindings.json"))).to be(false)
    end

    it "lists the slots it could not match, each with why" do
      running_session
      tmux.add_session("api", %w[zsh], window: 0)
      tmux.add_pane("api", "vim")
      processes.replace(tmux.pane_details("api", window: nil).map { |pane| {pid: pane[:pid], ppid: 1, command: pane[:command], args: pane[:command]} })
      started("api:0.1", sid(1))
      started("api:1.0", sid(2))
      started("api:0.2", "not-an-id")
      started("api:0.3", sid(4), cwd: File.join(dir, "gone"))

      result = call(dry_run: true)

      expect(result[:extra]["unmatched"]).to eq([
        {"workspace" => "api", "slot" => "api:0.1", "reason" => "pane_busy"},
        {"workspace" => "api", "slot" => "api:0.2", "reason" => "no_session_id"},
        {"workspace" => "api", "slot" => "api:0.3", "reason" => "cwd_missing"},
        {"workspace" => "api", "slot" => "api:1.0", "reason" => "no_window"}
      ])
      expect(result[:exit_code]).to eq(0)
      expect(output.string).to include("4 recorded panes could not be matched.")
      expect(tmux.delivered).to eq([])
    end

    it "reports a workspace with no config and no session as unmatched" do
      FileUtils.rm_f(File.join(dir, "workspace.api.yml"))
      started("api:0.1", sid(1))

      result = call(dry_run: true)

      expect(result[:results]).to match([
        include("kind" => "workspace", "outcome" => "unmatched", "reason" => "no_config"),
        include("kind" => "pane", "slot" => "api:0.1", "outcome" => "unmatched", "reason" => "not_launched", "session_id" => sid(1))
      ])
      expect(result[:extra]["unmatched"]).to eq([{"workspace" => "api", "slot" => nil, "reason" => "no_config"},
        {"workspace" => "api", "slot" => "api:0.1", "reason" => "not_launched"}])
    end

    it "words an empty plan and a single miss for a dry run" do
      running_session
      call(dry_run: true)
      started("api:1.0", sid(1))
      call(dry_run: true)

      expect(output.string).to start_with("Nothing to restore: the ledger has no agent panes for these workspaces.\n")
      expect(output.string).to end_with("1 recorded pane could not be matched.\n")
    end

    it "would resume in the config's plain shell pane of a session that is not running" do
      write_config("api", third: "")
      started("api:0.2", sid(1))

      expect(rows(call(dry_run: true))).to match([include("outcome" => "would_restore", "placement" => "existing", "restored_slot" => "api:0.2", "pane" => nil)])
    end

    it "predicts the index of each new pane from the recorded layout" do
      running_session
      started("api:0.5", sid(1), layout: layout(6))
      started("api:0.8", sid(2))

      result = call(dry_run: true)

      expect(rows(result)).to match([
        include("slot" => "api:0.5", "placement" => "exact", "restored_slot" => "api:0.5"),
        include("slot" => "api:0.8", "placement" => "appended", "restored_slot" => "api:0.6")
      ])
      expect(tmux.split_count).to eq(0)
      expect(tmux.layouts).to eq([])
    end
  end

  describe "a running session" do
    before { running_session }

    it "resumes in a pane that sits at a shell prompt, from the session's directory, with the config's permission flag" do
      started("api:0.2", sid(1))

      result = call

      expect(tmux.delivered).to eq([["api", "%2", "cd -- #{cwd} && claude --dangerously-skip-permissions --resume #{sid(1)}"]])
      expect(rows(result)).to match([include("outcome" => "restored", "placement" => "existing", "pane" => "%2", "restored_slot" => "api:0.2", "rebound" => false)])
      expect(result).to include(exit_code: 0, warnings: [])
      expect(result).not_to have_key(:status)
      expect(launched).to eq([])
      expect(output.string).to include("api:0.2: restored - Resumed session #{sid(1)} in its pane.")
    end

    it "never types into a pane that already runs an agent, so a second restore changes nothing" do
      started("api:0.1", sid(1))

      result = call

      expect(rows(result)).to match([include("outcome" => "skipped", "reason" => "agent_running", "pane" => "%1")])
      expect(tmux.delivered).to eq([])
    end

    it "finds an agent started from the pane's shell" do
      processes << {pid: 9000, ppid: tmux.pid_of("%2"), command: "2.1.289", args: "claude"}
      started("api:0.2", sid(1))

      expect(rows(call)).to match([include("outcome" => "skipped", "reason" => "agent_running")])
    end

    it "leaves a pane running another program alone" do
      started("api:0.3", sid(1))

      result = call

      expect(rows(result)).to match([include("outcome" => "unmatched", "reason" => "pane_busy", "message" => "The pane is running ruby.")])
      expect(tmux.delivered).to eq([])
    end

    it "leaves existing panes alone when the process table can't be read" do
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")
      started("api:0.2", sid(1))

      result = call

      expect(rows(result)).to match([include("outcome" => "unmatched", "reason" => "pane_unknown")])
      expect(result[:warnings]).to eq(["Could not read the process table (ps failed); panes that exist are left alone."])
      expect(tmux.delivered).to eq([])
    end

    it "recreates a pane split by hand at its slot and applies the recorded layout" do
      started("api:0.4", sid(1), layout: layout(5))

      result = call

      expect(tmux.split_count).to eq(1)
      expect(tmux.layouts).to eq([["api", "0", layout(5)]])
      expect(tmux.delivered).to eq([["api", "%4", "cd -- #{cwd} && claude --dangerously-skip-permissions --resume #{sid(1)}"]])
      expect(rows(result)).to match([include("outcome" => "restored", "placement" => "exact", "pane" => "%4", "restored_slot" => "api:0.4")])
    end

    it "makes the panes between, so a slot keeps its index when a non-agent pane sat before it" do
      started("api:0.5", sid(1), layout: layout(6))

      result = call

      expect(tmux.split_count).to eq(2)
      expect(tmux.delivered.map { |_, pane, _| pane }).to eq(["%5"])
      expect(rows(result)).to match([include("placement" => "exact", "restored_slot" => "api:0.5")])
    end

    it "uses the layout of the newest pane to recreate" do
      started("api:0.4", sid(1), layout: layout(5), at: "2026-10-01T00:00:00Z")
      started("api:0.5", sid(2), layout: layout(6))

      call

      expect(tmux.layouts).to eq([["api", "0", layout(6)]])
      expect(tmux.split_count).to eq(2)
    end

    it "adds panes after the last one when no layout was recorded, and says where each went" do
      started("api:0.4", sid(1))
      started("api:0.7", sid(2))

      result = call

      expect(tmux.layouts).to eq([])
      expect(rows(result)).to match([
        include("slot" => "api:0.4", "placement" => "appended", "restored_slot" => "api:0.4", "pane" => "%4"),
        include("slot" => "api:0.7", "placement" => "appended", "restored_slot" => "api:0.5", "pane" => "%5")
      ])
      expect(output.string).to include("api:0.7: restored - Resumed session #{sid(2)} in a new pane at index 5.")
    end

    it "ignores a recorded layout with no more panes than the window has" do
      started("api:0.6", sid(1), layout: layout(4))

      result = call

      expect(tmux.layouts).to eq([])
      expect(rows(result)).to match([include("placement" => "appended", "restored_slot" => "api:0.4")])
    end

    it "warns and keeps going when the layout can't be applied" do
      allow(tmux).to receive(:apply_layout).and_return(false)
      started("api:0.4", sid(1), layout: layout(5))

      result = call

      expect(rows(result)).to match([include("outcome" => "restored", "placement" => "exact")])
      expect(result[:warnings]).to eq(["api: the recorded layout of window 0 could not be applied; the new panes keep the size tmux gave them."])
      expect(error_output.string).to include("Warning: api: the recorded layout of window 0")
    end

    context "in a window of 24 rows" do
      before do
        tmux.rows = 24
        running_session
      end

      it "tiles the window once when tmux has no space for a new pane, and splits again" do
        started("api:0.4", sid(1))
        started("api:0.5", sid(2))

        result = call

        expect(tmux.last_error).to eq("no space for a new pane")
        expect(tmux.layouts).to eq([["api", "0", "tiled"]])
        expect(rows(result)).to match([
          include("slot" => "api:0.4", "outcome" => "restored", "pane" => "%8"),
          include("slot" => "api:0.5", "outcome" => "restored", "pane" => "%9", "restored_slot" => "api:0.5")
        ])
        expect(result).to include(exit_code: 0, warnings: ["api: window 0 was tiled to make room for a restored pane."])
      end
    end

    context "in a window of 4 rows" do
      before do
        tmux.rows = 4
        running_session
      end

      it "fails the slot, exit 1, when tmux still has no space after tiling, and restores the others" do
        started("api:0.2", sid(1))
        started("api:0.4", sid(2))

        result = call

        expect(tmux.layouts).to eq([["api", "0", "tiled"]])
        expect(rows(result)).to match([
          include("slot" => "api:0.2", "outcome" => "restored"),
          include("slot" => "api:0.4", "outcome" => "failed", "reason" => "split_failed", "pane" => nil, "restored_slot" => nil, "placement" => nil)
        ])
        expect(result[:exit_code]).to eq(1)
        expect(tmux.delivered.size).to eq(1)
      end

      it "fails a slot the window could not be grown to, and says the layout was not applied" do
        started("api:0.5", sid(1), layout: layout(6))

        result = call

        expect(rows(result)).to match([include("outcome" => "failed", "reason" => "split_failed")])
        expect(result[:warnings]).to include("api: the recorded layout of window 0 could not be applied; the new panes keep the size tmux gave them.")
        expect(tmux.delivered).to eq([])
      end

      it "fails the slot when tiling is refused too" do
        allow(tmux).to receive(:apply_layout).and_return(false)
        started("api:0.4", sid(1))

        expect(rows(call)).to match([include("outcome" => "failed", "reason" => "split_failed")])
        expect(tmux.split_count).to eq(0)
      end
    end

    it "fails the slot when the new pane can't be found afterwards" do
      allow(tmux).to receive(:split_window).and_return(9)
      started("api:0.4", sid(1))

      result = call

      expect(rows(result)).to match([include("outcome" => "failed", "reason" => "pane_not_found", "pane" => nil, "placement" => nil, "restored_slot" => nil)])
      expect(result[:exit_code]).to eq(1)
      expect(tmux.delivered).to eq([])
    end

    it "makes a pane in the window the slot names" do
      tmux.add_session("api", %w[zsh], window: 1)
      started("api:1.1", sid(1))

      result = call

      expect(tmux.pane_details("api", window: "1").map { |pane| pane[:id] }).to eq(%w[%4 %5])
      expect(tmux.delivered.map { |_, pane, _| pane }).to eq(["%5"])
      expect(rows(result)).to match([include("outcome" => "restored", "restored_slot" => "api:1.1")])
    end

    it "takes a login shell for a prompt" do
      tmux.add_session("api", %w[-zsh], window: 1)
      processes << {pid: tmux.pid_of("%4"), ppid: 1, command: "-zsh", args: "-zsh"}
      started("api:1.0", sid(1))

      expect(rows(call)).to match([include("outcome" => "restored", "placement" => "existing", "pane" => "%4")])
    end

    it "does not make a pane for a conversation Claude Code no longer has" do
      started("api:0.4", sid(1), transcript_path: File.join(dir, "gone.jsonl"))
      File.write(File.join(dir, "kept.jsonl"), "")
      started("api:0.5", sid(2), transcript_path: File.join(dir, "kept.jsonl"))

      result = call

      expect(rows(result)).to match([
        include("slot" => "api:0.4", "outcome" => "unmatched", "reason" => "transcript_missing"),
        include("slot" => "api:0.5", "outcome" => "restored")
      ])
      expect(tmux.split_count).to eq(1)
    end

    it "says a warning once however many workspaces it applies to" do
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")
      write_config("web")
      running_session("web")

      result = call(%w[api web])

      expect(result[:warnings]).to eq(["Could not read the process table (ps failed); panes that exist are left alone."])
      expect(error_output.string.scan("Warning:").size).to eq(1)
    end

    it "fails the slot when the command did not reach the pane" do
      tmux.delivery_status = :not_landed
      started("api:0.2", sid(1))

      result = call

      expect(rows(result)).to match([include("outcome" => "failed", "reason" => "not_delivered", "message" => "delivery not_landed")])
      expect(result[:exit_code]).to eq(1)
    end

    it "counts a command that may have arrived as restored, with a warning, rather than type it twice" do
      tmux.delivery_status = :unverified
      started("api:0.2", sid(1))

      result = call

      expect(rows(result)).to match([include("outcome" => "restored")])
      expect(result[:warnings]).to eq(["api:0.2: delivery unverified"])
      expect(tmux.delivered.size).to eq(1)
    end

    it "does not restore a session the user ended" do
      %w[prompt_input_exit logout clear].each_with_index do |reason, index|
        started("api:0.#{index + 4}", sid(index))
        ended("api:0.#{index + 4}", sid(index), reason)
      end

      result = call

      expect(rows(result).map { |row| row.values_at("outcome", "reason") }).to eq([%w[skipped ended]] * 3)
      expect(rows(result).first["message"]).to eq("The session ended (prompt_input_exit).")
      expect(tmux.split_count).to eq(0)
    end

    it "restores a session whose end was recorded as the terminal going away" do
      started("api:0.4", sid(1))
      ended("api:0.4", sid(1), "other")
      started("api:0.5", sid(2))
      ended("api:0.5", sid(2), nil)

      expect(rows(call).map { |row| row["outcome"] }).to eq(%w[restored restored])
    end

    it "never puts a session id that is not an id on a command line" do
      started("api:0.2", "x; touch #{File.join(dir, "pwned")}")
      started("api:0.4", "ABCDEF00-0000-4000-8000-000000000001")
      ledger.record("event" => "session_start", "workspace" => "api", "pane_slot" => "api:0.5", "cwd" => cwd)

      result = call

      expect(rows(result).map { |row| row["reason"] }).to eq(%w[no_session_id] * 3)
      expect(tmux.delivered).to eq([])
    end

    it "quotes the directory" do
      odd = File.join(dir, "my checkout; $(x)")
      FileUtils.mkdir_p(odd)
      started("api:0.2", sid(1), cwd: odd)

      call

      expect(tmux.delivered.first.last).to eq("cd -- #{Shellwords.escape(odd)} && claude --dangerously-skip-permissions --resume #{sid(1)}")
      expect(tmux.delivered.first.last).to include("my\\ checkout\\;\\ \\$\\(x\\)")
    end

    it "does not match a slot with no directory recorded" do
      ledger.record("event" => "session_start", "workspace" => "api", "pane_slot" => "api:0.2", "session_id" => sid(1))

      expect(rows(call)).to match([include("outcome" => "unmatched", "reason" => "cwd_missing")])
    end

    it "starts plain claude when the config's agent pane has no permission flag, and never carries --continue" do
      write_config("api", claude: "claude --model opus --continue")
      started("api:0.2", sid(1))

      call

      expect(tmux.delivered.first.last).to eq("cd -- #{cwd} && claude --resume #{sid(1)}")
    end

    it "starts plain claude when the config has no agent pane" do
      write_config("api", claude: "echo no agent")
      started("api:0.2", sid(1))

      call

      expect(tmux.delivered.first.last).to eq("cd -- #{cwd} && claude --resume #{sid(1)}")
    end

    it "restores a running session whose config is gone" do
      FileUtils.rm_f(File.join(dir, "workspace.api.yml"))
      started("api:0.2", sid(1))

      result = call

      expect(rows(result)).to match([include("outcome" => "restored")])
      expect(tmux.delivered.first.last).to eq("cd -- #{cwd} && claude --resume #{sid(1)}")
    end

    it "says so when the ledger has nothing for the workspaces" do
      result = call

      expect(result).to include(exit_code: 0, results: [])
      expect(output.string).to eq("Nothing to restore: the ledger has no agent panes for them.\n")
    end

    it "finds a worktree workspace's panes under its tmux session's name, which is what the hook records" do
      write_config("api.worktree-fix", session: "api-wt-fix")
      tmux.session_names = {"api.worktree-fix" => "api-wt-fix"}
      running_session("api-wt-fix")
      started("api-wt-fix:0.2", sid(1))
      started("api-wt-fix:0.4", sid(2))

      result = call(["api.worktree-fix"])

      expect(tmux.delivered.map { |session, pane, _| [session, pane] }).to eq([["api-wt-fix", "%6"], ["api-wt-fix", "%8"]])
      expect(rows(result)).to match([
        include("workspace" => "api.worktree-fix", "slot" => "api-wt-fix:0.2", "restored_slot" => "api-wt-fix:0.2"),
        include("workspace" => "api.worktree-fix", "slot" => "api-wt-fix:0.4", "restored_slot" => "api-wt-fix:0.4")
      ])
    end

    it "ignores an entry whose slot names another session" do
      ledger.record("event" => "session_start", "workspace" => "api", "pane_slot" => "other:0.2", "session_id" => sid(1), "cwd" => cwd)

      expect(call[:results]).to eq([])
    end

    it "keeps each workspace's slots to its own session" do
      running_session("web")
      write_config("web")
      started("api:0.2", sid(1))
      started("web:0.2", sid(2))

      result = call(%w[api web])

      expect(tmux.delivered.map { |session, _, text| [session, text[/\S+\z/]] }).to eq([["api", sid(1)], ["web", sid(2)]])
      expect(rows(result).map { |row| row["workspace"] }).to eq(%w[api web])
    end
  end

  describe "a session that is not running" do
    it "launches it through the block, leaves the config's panes to the config and recreates the others" do
      started("api:0.1", sid(1), pane_id: "%1")
      started("api:0.4", sid(2), pane_id: "%7", layout: layout(5))

      result = call

      expect(launched).to eq(["api"])
      expect(rows(result, "workspace")).to match([include("workspace" => "api", "outcome" => "launched")])
      expect(rows(result)).to match([
        include("slot" => "api:0.1", "outcome" => "skipped", "reason" => "config_pane", "pane" => "%1"),
        include("slot" => "api:0.4", "outcome" => "restored", "placement" => "exact", "pane" => "%4")
      ])
      expect(tmux.delivered).to eq([["api", "%4", "cd -- #{cwd} && claude --dangerously-skip-permissions --resume #{sid(2)}"]])
      expect(output.string).to include("api: launched\n")
    end

    it "launches a workspace the ledger has nothing for, as part of the active set" do
      result = call

      expect(launched).to eq(["api"])
      expect(result[:results]).to match([include("kind" => "workspace", "outcome" => "launched")])
    end

    it "does not type into a config pane even while it still sits at its shell" do
      started("api:0.2", sid(1))

      result = call

      expect(rows(result)).to match([include("outcome" => "skipped", "reason" => "config_pane")])
      expect(tmux.delivered).to eq([])
    end

    it "waits for the panes the config defines before it splits" do
      started("api:0.4", sid(1))

      result = restore.call(["api"]) do
        tmux.add_session("api", %w[zsh])
        {}
      end

      expect(sleeps.sum).to eq(described_class::PANE_WAIT)
      expect(result[:warnings]).to eq(["api: its session still has fewer panes than its config defines after 10s."])
      expect(rows(result)).to match([include("outcome" => "restored", "restored_slot" => "api:0.1")])
    end

    it "stops waiting as soon as the panes are there" do
      started("api:0.4", sid(1))
      allow(tmux).to receive(:pane_details).and_wrap_original do |original, *args, **options|
        tmux.add_pane("api", "zsh") if original.call("api", window: nil).size < 4
        original.call(*args, **options)
      end

      result = restore.call(["api"]) do
        tmux.add_session("api", %w[zsh])
        {}
      end

      expect(sleeps.size).to be <= 3
      expect(result[:warnings]).to eq([])
      expect(rows(result)).to match([include("outcome" => "restored", "restored_slot" => "api:0.4")])
    end

    it "fails the workspace and touches nothing when it could not be launched" do
      started("api:0.4", sid(1))

      result = restore.call(["api"]) { {"api" => "tmuxinator exited 1"} }

      expect(result[:results]).to match([
        include("kind" => "workspace", "outcome" => "failed", "reason" => "launch_failed", "message" => "tmuxinator exited 1"),
        include("kind" => "pane", "slot" => "api:0.4", "outcome" => "unmatched", "reason" => "not_launched", "session_id" => sid(1), "rebound" => false)
      ])
      expect(result[:extra]["unmatched"]).to eq([{"workspace" => "api", "slot" => "api:0.4", "reason" => "not_launched"}])
      expect(result[:exit_code]).to eq(1)
      expect(tmux.split_count).to eq(0)
    end

    it "still says which of a workspace's sessions had ended when it could not be launched" do
      started("api:0.4", sid(1))
      ended("api:0.4", sid(1), "logout")

      result = restore.call(["api"]) { {"api" => "no"} }

      expect(rows(result)).to match([include("outcome" => "skipped", "reason" => "ended")])
    end

    it "resumes in the config's plain shell pane once it is at a prompt, and leaves the panes the config gives a command" do
      write_config("api", third: "")
      started("api:0.2", sid(1))
      started("api:0.3", sid(2))

      result = call

      expect(rows(result)).to match([
        include("slot" => "api:0.2", "outcome" => "restored", "placement" => "existing", "pane" => "%2"),
        include("slot" => "api:0.3", "outcome" => "skipped", "reason" => "config_pane")
      ])
      expect(tmux.delivered.map { |_, pane, _| pane }).to eq(["%2"])
    end

    context "with tmux numbering windows and panes from 1 (base-index and pane-base-index)" do
      before { tmux.pane_base = 1 }

      def launch_numbered_from_one(names = ["api"])
        restore.call(names) do |missing|
          missing.each do |name|
            tmux.add_session(name, %w[zsh 2.1.289 zsh ruby], window: 1)
            tmux.pane_details(name, window: nil).each { |pane| processes << {pid: pane[:pid], ppid: 1, command: pane[:command], args: pane[:command]} }
          end
          {}
        end
      end

      it "leaves the config's claude pane alone while it still shows its shell, though its number is the bare shell's in the config" do
        write_config("api", third: "")
        started("api:0.2", sid(1))
        result = restore.call(["api"]) do
          tmux.add_session("api", %w[zsh zsh zsh ruby])
          tmux.pane_details("api", window: nil).each { |pane| processes << {pid: pane[:pid], ppid: 1, command: pane[:command], args: pane[:command]} }
          {}
        end

        expect(rows(result)).to match([include("slot" => "api:0.2", "outcome" => "skipped", "reason" => "config_pane", "pane" => "%1")])
        expect(tmux.delivered).to eq([])
      end

      it "resumes an agent that was started in the config's bare shell pane, in place" do
        write_config("api", third: "")
        started("api:1.3", sid(1))
        started("api:1.4", sid(2))

        result = launch_numbered_from_one

        expect(rows(result)).to match([
          include("slot" => "api:1.3", "outcome" => "restored", "placement" => "existing", "pane" => "%2", "restored_slot" => "api:1.3"),
          include("slot" => "api:1.4", "outcome" => "skipped", "reason" => "config_pane", "pane" => "%3")
        ])
        expect(tmux.delivered.map { |_, pane, _| pane }).to eq(["%2"])
      end

      it "makes a new pane after the last one, numbered from 1" do
        started("api:1.5", sid(1))

        result = launch_numbered_from_one

        expect(rows(result)).to match([include("outcome" => "restored", "placement" => "appended", "pane" => "%4", "restored_slot" => "api:1.5")])
      end
    end

    it "never types into the config's plain shell pane while it runs something" do
      write_config("api", third: "")
      started("api:0.2", sid(1))

      result = restore.call(["api"]) do
        running_session("api", %w[zsh 2.1.289 vim ruby])
        {}
      end

      expect(rows(result)).to match([include("outcome" => "unmatched", "reason" => "pane_busy", "message" => "The pane is running vim.")])
      expect(tmux.delivered).to eq([])
    end

    it "fails the workspace when nothing was given to launch it" do
      result = restore.call(["api"])

      expect(result[:results]).to match([include("outcome" => "failed", "reason" => "launch_failed")])
    end

    it "fails a workspace with no config without asking for a launch" do
      FileUtils.rm_f(File.join(dir, "workspace.api.yml"))

      result = call

      expect(launched).to eq([])
      expect(result[:results]).to match([include("kind" => "workspace", "outcome" => "failed", "reason" => "no_config")])
    end

    it "restores the others when one workspace fails to launch" do
      write_config("web")
      running_session("web")
      started("web:0.2", sid(1))

      result = restore.call(%w[api web]) { |missing| missing.to_h { |name| [name, "no"] } }

      expect(result[:results].map { |row| row.values_at("workspace", "outcome") }).to eq([%w[api failed], %w[web restored]])
      expect(ensured).to eq(["web"])
      expect(result[:exit_code]).to eq(1)
    end
  end

  describe "pane bindings" do
    def bind(pane_id, id, slot)
      bindings.bind(pane_id, "kind" => "run", "id" => id, "workspace" => "api", "session" => "api", "pane_slot" => slot)
    end

    it "moves a binding to the recreated pane after a tmux restart, before the resume command is typed" do
      bind("%7", "wr_1", "api:0.4")
      started("api:0.4", sid(1), pane_id: "%7")
      running_session
      bound_when_typed = nil
      allow(tmux).to receive(:deliver).and_wrap_original do |original, *args, **options|
        bound_when_typed = bindings.binding_for("%4")
        original.call(*args, **options)
      end

      result = call

      expect(bound_when_typed).to include("id" => "wr_1")
      expect(bindings.binding_for("%4")).to include("id" => "wr_1", "pane_slot" => "api:0.4", "session" => "api")
      expect(bindings.binding_for("%7")).to be_nil
      expect(rows(result)).to match([include("rebound" => true)])
      expect(output.string).to include("Its binding moved with it.")
    end

    it "keeps every binding when new panes got ids other bound panes had before the restart" do
      bind("%4", "wr_1", "api:0.2")
      bind("%2", "wr_2", "api:0.4")
      started("api:0.2", sid(1), pane_id: "%4")
      started("api:0.4", sid(2), pane_id: "%2")
      running_session

      call

      expect(bindings.binding_for("%2")).to include("id" => "wr_1", "pane_slot" => "api:0.2")
      expect(bindings.binding_for("%4")).to include("id" => "wr_2", "pane_slot" => "api:0.4")
    end

    it "records the slot the pane went to when it was added after the last one" do
      bind("%9", "wr_1", "api:0.7")
      started("api:0.7", sid(1), pane_id: "%9")
      running_session

      call

      expect(bindings.binding_for("%4")).to include("id" => "wr_1", "pane_slot" => "api:0.4")
    end

    it "moves the binding of a pane the config started or an agent already runs in" do
      bind("%8", "play/kickoff", "api:0.1")
      started("api:0.1", sid(1), pane_id: "%8")
      running_session

      result = call

      expect(rows(result)).to match([include("reason" => "agent_running", "rebound" => true)])
      expect(bindings.binding_for("%1")).to include("id" => "play/kickoff")
    end

    it "leaves a pane that kept its id and slot alone, as when tmux never restarted" do
      running_session
      bind("%2", "wr_1", "api:0.2")
      started("api:0.2", sid(1), pane_id: "%2", tmux_server: "500")
      before = File.read(File.join(dir, "state", "bindings.json"))

      result = call

      expect(rows(result)).to match([include("outcome" => "restored", "rebound" => false)])
      expect(File.read(File.join(dir, "state", "bindings.json"))).to eq(before)
    end

    it "leaves a binding made on a reused pane id for another slot" do
      running_session
      bind("%2", "wr_new", "api:0.2")
      started("api:0.4", sid(1), pane_id: "%2")

      call

      expect(bindings.binding_for("%2")).to include("id" => "wr_new", "pane_slot" => "api:0.2")
      expect(bindings.binding_for("%4")).to be_nil
    end

    it "leaves the binding where it is when the pane at the slot runs another program" do
      bind("%9", "wr_1", "api:0.3")
      started("api:0.3", sid(1), pane_id: "%9")
      running_session

      result = call

      expect(rows(result)).to match([include("reason" => "pane_busy", "rebound" => false)])
      expect(bindings.binding_for("%9")).to include("id" => "wr_1")
      expect(bindings.binding_for("%3")).to be_nil
    end

    it "keeps both workspaces' bindings when one's new pane took the id the other's bound pane had" do
      write_config("web")
      bindings.bind("%1", "kind" => "run", "id" => "wr_api", "workspace" => "api", "session" => "api", "pane_slot" => "api:0.4")
      bindings.bind("%8", "kind" => "run", "id" => "wr_web", "workspace" => "web", "session" => "web", "pane_slot" => "web:0.4")
      started("api:0.4", sid(1), pane_id: "%1")
      started("web:0.4", sid(2), pane_id: "%8")

      call(%w[api web])

      expect(tmux.delivered.map { |session, pane, _| [session, pane] }).to eq([["api", "%8"], ["web", "%9"]])
      expect(bindings.binding_for("%8")).to include("id" => "wr_api", "session" => "api", "pane_slot" => "api:0.4")
      expect(bindings.binding_for("%9")).to include("id" => "wr_web", "session" => "web", "pane_slot" => "web:0.4")
    end

    it "keeps the other workspace's binding when the two are restored one after the other" do
      write_config("web")
      bindings.bind("%1", "kind" => "run", "id" => "wr_api", "workspace" => "api", "session" => "api", "pane_slot" => "api:0.4")
      bindings.bind("%4", "kind" => "run", "id" => "wr_web", "workspace" => "web", "session" => "web", "pane_slot" => "web:0.4")
      started("api:0.4", sid(1), pane_id: "%1")
      started("web:0.4", sid(2), pane_id: "%4")

      call(%w[api])
      call(%w[web])

      expect(bindings.binding_for("%4")).to include("id" => "wr_api", "session" => "api")
      expect(bindings.binding_for("%9")).to include("id" => "wr_web", "session" => "web", "pane_slot" => "web:0.4")
    end

    it "moves nothing for a slot that was not restored" do
      bind("%7", "wr_1", "api:0.4")
      started("api:0.4", sid(1), pane_id: "%7")
      ended("api:0.4", sid(1), "logout")
      running_session

      call

      expect(bindings.binding_for("%7")).to include("id" => "wr_1")
    end

    it "warns and still resumes when the bindings can't be written" do
      bind("%7", "wr_1", "api:0.4")
      started("api:0.4", sid(1), pane_id: "%7")
      running_session
      allow(bindings).to receive(:move).and_raise(Errno::EACCES, "bindings.json")

      result = call

      expect(rows(result)).to match([include("outcome" => "restored", "rebound" => false)])
      expect(result[:warnings].first).to start_with("Pane bindings were not moved (Errno::EACCES")
    end
  end

  describe "a session that never restarted, after a sibling pane closed" do
    # Agents X (%4) and Y (%5) ran at 0.4 and 0.5, both bound. The pane at
    # 0.3 was closed, so they are at 0.3 and 0.4 now, and no hook has fired.
    let(:panes) { tmux.instance_variable_get(:@windows)["api"][0] }

    before do
      running_session("api", %w[zsh 2.1.289 zsh ruby 2.1.289 2.1.289])
      started("api:0.4", sid(1), pane_id: "%4", tmux_server: "500")
      started("api:0.5", sid(2), pane_id: "%5", tmux_server: "500")
      bindings.bind("%4", "kind" => "run", "id" => "wr_x", "session" => "api", "pane_slot" => "api:0.4")
      bindings.bind("%5", "kind" => "run", "id" => "wr_y", "session" => "api", "pane_slot" => "api:0.5")
      panes.delete_at(3)
    end

    it "takes each recorded pane id for the pane itself: nothing is typed, split or rebound" do
      before = File.read(File.join(dir, "state", "bindings.json"))

      result = call

      expect(rows(result)).to match([
        include("slot" => "api:0.4", "outcome" => "skipped", "reason" => "agent_running", "pane" => "%4", "rebound" => false),
        include("slot" => "api:0.5", "outcome" => "skipped", "reason" => "agent_running", "pane" => "%5", "rebound" => false)
      ])
      expect(tmux.delivered).to eq([])
      expect(tmux.split_count).to eq(0)
      expect(File.read(File.join(dir, "state", "bindings.json"))).to eq(before)
    end

    it "resumes in the pane itself, at its index now, when its agent is gone" do
      processes.find { |process| process[:pid] == tmux.pid_of("%5") }.merge!(command: "zsh", args: "-zsh")
      panes.find { |pane| pane[:id] == "%5" }[:command] = "zsh"

      result = call

      expect(tmux.delivered.map { |_, pane, _| pane }).to eq(["%5"])
      expect(rows(result).last).to include("slot" => "api:0.5", "outcome" => "restored", "placement" => "existing", "restored_slot" => "api:0.4", "rebound" => true)
      expect(bindings.binding_for("%5")).to include("id" => "wr_y", "pane_slot" => "api:0.4")
      expect(bindings.binding_for("%4")).to include("id" => "wr_x", "pane_slot" => "api:0.4")
    end

    it "makes a new pane, and never uses the one at the old index, for a recorded pane that was closed" do
      started("api:0.3", sid(3), pane_id: "%3", tmux_server: "500")

      result = call

      expect(rows(result).first).to include("slot" => "api:0.3", "outcome" => "restored", "placement" => "appended", "pane" => "%6", "restored_slot" => "api:0.5")
      expect(tmux.delivered.map { |_, pane, _| pane }).to eq(["%6"])
    end
  end

  describe "an entry written before the tmux server was recorded" do
    before { running_session("api", %w[zsh 2.1.289 zsh ruby 2.1.289]) }

    it "is matched by its index when the pane there is at a prompt" do
      started("api:0.2", sid(1), pane_id: "%9", tmux_server: nil)

      expect(rows(call)).to match([include("outcome" => "restored", "placement" => "existing", "pane" => "%2")])
    end

    it "never takes an agent at its index for its own: no keys, no binding moved" do
      bindings.bind("%9", "kind" => "run", "id" => "wr_1", "session" => "api", "pane_slot" => "api:0.1")
      started("api:0.1", sid(1), pane_id: "%9", tmux_server: nil)

      result = call

      expect(rows(result)).to match([include("outcome" => "unmatched", "reason" => "pane_ambiguous", "rebound" => false,
        "message" => "A coding agent runs in pane %1, and the ledger entry is too old to tell whether it is this session.")])
      expect(tmux.delivered).to eq([])
      expect(bindings.binding_for("%9")).to include("id" => "wr_1")
      expect(bindings.binding_for("%1")).to be_nil
    end

    it "makes no second pane for a session whose recorded pane id still runs an agent, as after a closed sibling" do
      started("api:0.5", sid(1), pane_id: "%4", tmux_server: nil)

      result = call

      expect(rows(result)).to match([include("outcome" => "unmatched", "reason" => "pane_ambiguous")])
      expect(tmux.split_count).to eq(0)
      expect(tmux.delivered).to eq([])
    end

    it "is recreated when no pane has its id or its index" do
      started("api:0.6", sid(1), pane_id: "%9", tmux_server: nil)

      expect(rows(call)).to match([include("outcome" => "restored", "placement" => "appended", "restored_slot" => "api:0.5")])
    end
  end

  describe "a pane id reused after a tmux restart" do
    it "is not taken for the recorded pane: the slot is matched by its index" do
      running_session
      started("api:0.2", sid(1), pane_id: "%1", tmux_server: "400")

      expect(rows(call)).to match([include("outcome" => "restored", "placement" => "existing", "pane" => "%2")])
    end

    it "moves the binding to the agent the config started at the same slot" do
      running_session
      bindings.bind("%8", "kind" => "play", "id" => "play/kickoff", "session" => "api", "pane_slot" => "api:0.1")
      started("api:0.1", sid(1), pane_id: "%8", tmux_server: "400")

      expect(rows(call)).to match([include("outcome" => "skipped", "reason" => "agent_running", "rebound" => true)])
    end
  end

  describe "after a tmux restart and a second restore" do
    it "restores once: the resumed session's own ledger entry and running agent stop a repeat" do
      running_session
      started("api:0.4", sid(1), pane_id: "%7")
      call
      # What the resumed session's SessionStart hook records, and what the pane then runs.
      started("api:0.4", sid(1), pane_id: "%4", source: "resume", tmux_server: "500")
      processes << {pid: 9000, ppid: tmux.pid_of("%4"), command: "2.1.289", args: "claude --resume #{sid(1)}"}

      result = call

      expect(rows(result)).to match([include("slot" => "api:0.4", "outcome" => "skipped", "reason" => "agent_running")])
      expect(tmux.delivered.size).to eq(1)
      expect(tmux.split_count).to eq(1)
    end
  end

  describe "the agent daemon" do
    it "is started for a running session that has none, before anything is typed" do
      running_session
      started("api:0.2", sid(1))
      allow(tmux).to receive(:deliver).and_wrap_original do |original, *args, **options|
        expect(ensured).to eq(["api"])
        original.call(*args, **options)
      end

      call

      expect(ensured).to eq(["api"])
      expect(tmux.delivered.size).to eq(1)
    end

    it "is left to the launch for a session restore launches, and never touched in a dry run" do
      started("api:0.4", sid(1))

      call(dry_run: true)
      call

      expect(ensured).to eq([])
    end

    context "when it can't be started" do
      let(:ensure_result) { Workspace::Commands::EnsureAgent::Result.new(:failed, "no answer in 5s") }

      it "warns and still restores" do
        running_session
        started("api:0.2", sid(1))

        result = call

        expect(result[:warnings]).to eq(["api: could not start its agent daemon: no answer in 5s"])
        expect(rows(result)).to match([include("outcome" => "restored")])
      end
    end

    context "when the pipeline config is not usable" do
      let(:ensure_result) { Workspace::Commands::EnsureAgent::Result.new(:invalid_config) }

      it "says nothing more, as launch does" do
        running_session

        expect(call[:warnings]).to eq([])
      end
    end

    it "is optional" do
      running_session
      started("api:0.2", sid(1))
      command = described_class.new(ledger: ledger, tmux: tmux, pane_bindings: bindings, tmuxinator_report: report, process_tree: process_tree,
        output: output, error_output: error_output)

      expect(command.call(["api"])[:exit_code]).to eq(0)
    end
  end

  describe "before anything changes" do
    it "raises when the ledger can't be read" do
      started("api:0.4", sid(1))
      File.chmod(0o000, File.join(dir, "state", "ledger.jsonl"))

      expect { call }.to raise_error(Workspace::Error, /Can't read the session ledger/)
      expect(launched).to eq([])
    ensure
      File.chmod(0o600, File.join(dir, "state", "ledger.jsonl"))
    end

    it "raises when tmux can't list sessions" do
      tmux.sessions_error = "tmux timed out"

      expect { call }.to raise_error(Workspace::Error, "tmux timed out")
      expect(launched).to eq([])
    end
  end
end
