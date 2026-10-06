require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Commands::Daemon, "list and restart_all" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:workspaces) { %w[api web worker] }
  # Workspaces whose socket file exists, and which of those answer.
  let(:sockets) { [] }
  let(:answering) { [] }
  # pid holding each workspace's socket, and the process table.
  let(:holders) { {} }
  let(:table) { {} }
  let(:alive) { [] }
  let(:stuck) { [] }
  let(:signals) { [] }
  let(:ensure_calls) { [] }
  let(:failing_start) { [] }
  let(:next_pid) { [9000] }

  let(:config) do
    dir = tmpdir
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:agent_socket_path) { |name| File.join(dir, "workspace-#{name}.sock") }
      allow(c).to receive(:agent_log_path) { |name| File.join(dir, "workspace-#{name}.log") }
      allow(c).to receive(:agent_running?) { |name| answering.include?(name) }
    end
  end
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: workspaces, exists?: true) }
  let(:process_tree) do
    rows = table
    snapshot = Object.new
    snapshot.define_singleton_method(:find) { |pid| rows[pid] }
    double("process_tree", snapshot: snapshot)
  end
  let(:ensure_agent) do
    double("ensure_agent").tap do |e|
      allow(e).to receive(:call) do |name:, wc_socket:|
        ensure_calls << name
        next Workspace::Commands::EnsureAgent::Result.new(:failed, "boom") if failing_start.include?(name)

        pid = (next_pid[0] += 1)
        holders[name] = pid
        table[pid] = {pid: pid, lstart: "Mon Oct  5 10:00:00 2026", args: "/usr/bin/ruby workspace agentd --name #{name}"}
        alive << pid
        answering << name
        Workspace::Commands::EnsureAgent::Result.new(:started)
      end
    end
  end
  let(:signaller) do
    ->(signal, pid) {
      raise Errno::ESRCH unless alive.include?(pid)
      next if signal == 0

      signals << [signal, pid]
      next if stuck.include?(pid)

      alive.delete(pid)
      holders.delete_if { |_, held| held == pid }
      answering.reject! { |name| !holders.key?(name) }
    }
  end
  let(:now) { [0.0] }
  let(:command) do
    holder_lookup = ->(path) { [holders[File.basename(path)[/workspace-(.*)\.sock/, 1]]].compact }
    described_class.new(config: config, project_config: project_config, ensure_agent: ensure_agent, process_tree: process_tree,
      pid_finder: holder_lookup, signaller: signaller, sleeper: ->(s) { now[0] += s }, clock: -> { now[0] }, stop_timeout: 1, output: output)
  end

  # Starts a fake agentd for +name+ the way a real one would be found.
  def run_daemon(name, pid, args: "/usr/bin/ruby /opt/workspace/bin/workspace agentd --name #{name}", answers: true)
    File.write(File.join(tmpdir, "workspace-#{name}.sock"), "")
    holders[name] = pid
    table[pid] = {pid: pid, lstart: "Thu Sep 24 09:12:03 2026", args: args}
    alive << pid
    answering << name if answers
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#list" do
    it "says plainly that none is running, and exits 0" do
      expect(command.list).to eq(exit_code: 0)
      expect(output.string).to eq("No agentd processes are running.\n")
    end

    it "gives an empty list as JSON" do
      command.list(json: true)

      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "daemons" => [], "warnings" => [])
    end

    it "lists one daemon as a table with its workspace, pid and start time" do
      run_daemon("api", 4242)

      command.list

      header, row = output.string.lines.map(&:chomp)
      expect(header).to start_with("WORKSPACE  PID   STARTED")
      expect(row).to match(/\Aapi\s+4242  2026-09-24T09:12:03Z  yes\s+#{Regexp.escape(File.join(tmpdir, "workspace-api.sock"))}\z/)
    end

    it "lists many daemons in workspace order and leaves out workspaces with no socket" do
      run_daemon("worker", 3)
      run_daemon("api", 1)

      command.list(json: true)

      expect(JSON.parse(output.string)["daemons"].map { |d| [d["workspace"], d["pid"]] }).to eq([["api", 1], ["worker", 3]])
    end

    it "ignores a stale socket file that nothing answers on or holds" do
      File.write(File.join(tmpdir, "workspace-api.sock"), "")
      run_daemon("web", 7)

      command.list(json: true)

      expect(JSON.parse(output.string)["daemons"].map { |d| d["workspace"] }).to eq(["web"])
    end

    it "ignores a socket held by a process that is not an agentd and does not answer" do
      run_daemon("api", 5000, args: "/usr/bin/vim", answers: false)

      command.list(json: true)

      expect(JSON.parse(output.string)["daemons"]).to eq([])
    end

    it "lists a hung agentd as not answering" do
      run_daemon("api", 4242, answers: false)

      command.list(json: true)

      expect(JSON.parse(output.string)["daemons"].first).to include("workspace" => "api", "pid" => 4242, "answering" => false)
    end

    it "gives the JSON shape: pid, start time, sockets and log, with the work-coordinator socket read from the command line" do
      run_daemon("api", 4242, args: "/usr/bin/ruby workspace agentd --name api --wc-socket /tmp/wc.sock")

      command.list(json: true)

      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "warnings" => [], "daemons" => [
        {"workspace" => "api", "pid" => 4242, "started_at" => "2026-09-24T09:12:03Z", "answering" => true,
         "socket" => File.join(tmpdir, "workspace-api.sock"), "log" => File.join(tmpdir, "workspace-api.log"), "wc_socket" => "/tmp/wc.sock"}
      ])
    end

    it "lists a hung daemon whose socket several processes hold, with an unknown pid" do
      run_daemon("api", 4242, answers: false)
      allow(command).to receive(:socket_pids).and_return([4242, 4243])

      command.list(json: true)

      expect(JSON.parse(output.string)["daemons"].first).to include("workspace" => "api", "pid" => nil, "answering" => false)
    end

    it "gives a null started_at when the process's start time can't be parsed" do
      run_daemon("api", 4242)
      table[4242][:lstart] = "not a date"

      command.list(json: true)

      expect(JSON.parse(output.string)["daemons"].first).to include("pid" => 4242, "started_at" => nil)
    end

    it "still lists an answering daemon, without a pid, when the process table can't be read" do
      run_daemon("api", 4242)
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")

      command.list(json: true)

      expect(JSON.parse(output.string)["daemons"].first).to include("workspace" => "api", "started_at" => nil)
    end
  end

  describe "#restart_all" do
    it "restarts every running daemon, old pid to new pid, and signals nothing else" do
      run_daemon("api", 4242)
      run_daemon("web", 4243)

      results = command.restart_all

      expect(results.map { |name, r| [name, r.outcome, r.old_pid, r.pid.class] }).to eq([["api", "restarted", 4242, Integer], ["web", "restarted", 4243, Integer]])
      expect(signals).to eq([["TERM", 4242], ["TERM", 4243]])
      expect(ensure_calls).to eq(%w[api web])
    end

    it "does nothing when none is running" do
      expect(command.restart_all).to eq([])
      expect(signals).to eq([])
      expect(ensure_calls).to eq([])
    end

    it "does not signal a stale socket's workspace" do
      File.write(File.join(tmpdir, "workspace-api.sock"), "")

      expect(command.restart_all).to eq([])
      expect(signals).to eq([])
    end

    it "carries on past a workspace that fails to start, and reports why" do
      run_daemon("api", 4242)
      run_daemon("web", 4243)
      run_daemon("worker", 4244)
      failing_start << "web"

      results = command.restart_all.to_h

      expect(results.transform_values(&:outcome)).to eq("api" => "restarted", "web" => "failed", "worker" => "restarted")
      expect(results["web"]).to have_attributes(reason: "start_failed", old_pid: 4243)
      expect(results["web"].message).to include("boom")
    end

    it "reports a daemon that won't stop, leaves it running and goes on to the next" do
      run_daemon("api", 4242)
      run_daemon("web", 4243)
      stuck << 4242

      results = command.restart_all.to_h

      expect(results["api"]).to have_attributes(outcome: "failed", reason: "not_stopped")
      expect(results["api"].message).to include("still running")
      expect(results["web"].outcome).to eq("restarted")
      expect(ensure_calls).to eq(["web"])
      expect(signals).to eq([["TERM", 4242], ["TERM", 4243]])
    end

    it "gives a hung daemon with several holders a failed row and signals nothing" do
      run_daemon("api", 4242, answers: false)
      allow(command).to receive(:socket_pids).and_return([4242, 4243])

      results = command.restart_all.to_h

      expect(results["api"]).to have_attributes(outcome: "failed", reason: "not_stopped")
      expect(results["api"].message).to include("can't tell which process", "2 processes have its socket open")
      expect(signals).to eq([])
    end

    it "turns an error raised for one workspace into its failed row and restarts the others" do
      run_daemon("api", 4242)
      run_daemon("web", 4243)
      run_daemon("worker", 4244)
      original = command.method(:restart)
      allow(command).to receive(:restart) do |name:|
        raise Workspace::Error, "ps blew up" if name == "web"
        original.call(name: name)
      end

      results = command.restart_all.to_h

      expect(results["web"]).to have_attributes(outcome: "failed", reason: "restart_failed", message: "ps blew up")
      expect([results["api"].outcome, results["worker"].outcome]).to eq(%w[restarted restarted])
    end

    it "keeps the code an error carries as the reason" do
      run_daemon("api", 4242)
      allow(command).to receive(:restart).and_raise(Workspace::Error.new("gone", code: "unknown_workspace"))

      expect(command.restart_all.to_h["api"].reason).to eq("unknown_workspace")
    end

    it "refuses to signal a pid that is not an agentd" do
      run_daemon("api", 5000, args: "/usr/bin/vim")

      results = command.restart_all.to_h

      expect(results["api"]).to have_attributes(outcome: "failed", reason: "not_agentd")
      expect(signals).to eq([])
    end
  end
end
