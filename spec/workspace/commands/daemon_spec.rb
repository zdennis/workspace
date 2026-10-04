require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Commands::Daemon do
  let(:tmpdir) { Dir.mktmpdir }
  let(:log_path) { File.join(tmpdir, "workspace-api.log") }
  let(:socket_path) { File.join(tmpdir, "workspace-api.sock") }
  let(:output) { StringIO.new }
  # What the daemon's socket answers: true while a daemon is up.
  let(:up) { [false] }
  let(:config) do
    instance_double(Workspace::Config, agent_socket_path: socket_path, agent_log_path: log_path).tap do |c|
      allow(c).to receive(:agent_running?) { up[0] }
    end
  end
  let(:project_config) { instance_double(Workspace::ProjectConfig, exists?: true) }
  let(:ensure_result) { Workspace::Commands::EnsureAgent::Result.new(:started) }
  let(:ensure_calls) { [] }
  let(:ensure_agent) do
    calls = ensure_calls
    result = -> { ensure_result }
    double("ensure_agent").tap do |e|
      allow(e).to receive(:call) do |**kwargs|
        calls << kwargs
        up[0] = true if result.call.ok?
        result.call
      end
    end
  end
  let(:pids) { [[4242]] }
  let(:pid_finder) { ->(path) { (pids.size > 1) ? pids.shift : pids.first } }
  let(:signals) { [] }
  let(:exits_on_term) { true }
  let(:alive_pids) { [4242] }
  # Behaves like Process.kill: signal 0 only probes, and a dead pid raises ESRCH.
  let(:signaller) do
    ->(signal, pid) {
      raise Errno::ESRCH unless alive_pids.include?(pid)
      next if signal == 0

      signals << [signal, pid]
      if exits_on_term
        up[0] = false
        alive_pids.delete(pid)
      end
    }
  end
  let(:agentd_args) { "/usr/bin/ruby /opt/workspace/bin/workspace agentd --name api" }
  let(:process_table) { {4242 => {pid: 4242, args: agentd_args}, 5000 => {pid: 5000, args: "/usr/bin/vim"}} }
  let(:process_tree) do
    table = process_table
    snapshot = Object.new
    snapshot.define_singleton_method(:find) { |pid| table[pid] }
    double("process_tree", snapshot: snapshot)
  end
  let(:now) { [0.0] }
  let(:sleeper) { ->(seconds) { now[0] += seconds } }
  let(:clock) { -> { now[0] } }
  def build(**overrides)
    described_class.new(config: config, project_config: project_config, ensure_agent: ensure_agent, process_tree: process_tree,
      pid_finder: pid_finder, signaller: signaller, sleeper: sleeper, clock: clock, stop_timeout: 1, output: output, **overrides)
  end

  subject(:command) { build }

  after { FileUtils.remove_entry(tmpdir) }

  def document
    JSON.parse(output.string)
  end

  describe "unknown workspaces" do
    before { allow(project_config).to receive(:exists?).with("nope").and_return(false) }

    it "refuses status, log and restart with unknown_workspace, before reading or signalling anything" do
      up[0] = true
      [-> { command.status(name: "nope", json: true) }, -> { command.log(name: "nope", json: true) }, -> { command.restart(name: "nope") }].each do |call|
        expect(&call).to raise_error(Workspace::Error) { |e| expect([e.code, e.details]).to eq(["unknown_workspace", {"name" => "nope"}]) }
      end
      expect(output.string).to eq("")
      expect(signals).to eq([])
    end
  end

  describe "#status" do
    it "reports a running daemon and its pid as JSON" do
      up[0] = true

      expect(command.status(name: "api", json: true)).to eq(exit_code: 0)
      expect(document).to eq("schema_version" => 1, "ok" => true, "workspace" => "api", "running" => true, "pid" => 4242,
        "socket" => socket_path, "log" => log_path)
    end

    it "reports a stopped daemon as data, with a null pid and without asking lsof" do
      finder_calls = []
      finder = ->(path) { finder_calls << path }
      cmd = build(pid_finder: finder)

      expect(cmd.status(name: "api", json: true)).to eq(exit_code: 0)
      expect(document).to include("running" => false, "pid" => nil)
      expect(finder_calls).to eq([])
    end

    it "gives a null pid when more than one process has the socket open" do
      up[0] = true
      pids[0] = [4242, 5000]

      command.status(name: "api", json: true)

      expect(document["pid"]).to be_nil
    end

    it "never reports its own pid as the daemon" do
      up[0] = true
      pids[0] = [Process.pid]

      command.status(name: "api", json: true)

      expect(document["pid"]).to be_nil
    end

    it "gives a null pid, and still answers, when lsof doesn't answer in time" do
      up[0] = true

      expect(build(pid_finder: ->(_path) {}).status(name: "api", json: true)).to eq(exit_code: 0)
      expect(document).to include("running" => true, "pid" => nil)
    end

    it "prints text for a person, with the next step when stopped" do
      command.status(name: "api")

      expect(output.string).to include("agentd for api is not running", "workspace agentd --ensure --name api")
    end

    it "prints the pid and paths in text when running" do
      up[0] = true

      command.status(name: "api")

      expect(output.string).to include("agentd for api is running (pid 4242)", "socket: #{socket_path}", "log:    #{log_path}")
    end
  end

  describe "#log" do
    it "returns the last lines with the path the config computed" do
      File.write(log_path, (1..100).map { |i| "line #{i}\n" }.join)

      command.log(name: "api", lines: 3, json: true)

      expect(document).to eq("schema_version" => 1, "ok" => true, "workspace" => "api", "path" => log_path, "exists" => true,
        "lines" => ["line 98", "line 99", "line 100"])
    end

    it "defaults to 40 lines" do
      File.write(log_path, (1..100).map { |i| "line #{i}\n" }.join)

      command.log(name: "api", json: true)

      expect(document["lines"].size).to eq(40)
      expect(document["lines"].first).to eq("line 61")
    end

    it "keeps a last line that has no newline and returns everything of a short file" do
      File.write(log_path, "a\nb")

      command.log(name: "api", lines: 10, json: true)

      expect(document["lines"]).to eq(%w[a b])
    end

    it "returns no lines for an empty file, which exists" do
      File.write(log_path, "")

      command.log(name: "api", json: true)

      expect(document).to include("exists" => true, "lines" => [])
    end

    it "reports a missing log as exists false, not an error" do
      expect(command.log(name: "api", json: true)).to eq(exit_code: 0)
      expect(document).to include("exists" => false, "lines" => [], "path" => log_path)
    end

    it "explains a missing log in text" do
      command.log(name: "api")

      expect(output.string).to include("No log at #{log_path}")
    end

    it "prints the lines in text" do
      File.write(log_path, "one\ntwo\n")

      command.log(name: "api")

      expect(output.string).to eq("one\ntwo\n")
    end

    it "reads only the end of a large file and drops the line the boundary cut" do
      File.write(log_path, "x" * 100 + "\n" + ("y" * 1023 + "\n") * 1024)

      command.log(name: "api", lines: 5000, json: true)

      expect(document["lines"].size).to eq(1024)
      expect(document["lines"]).to all(eq("y" * 1023))
    end

    it "replaces invalid UTF-8 so the JSON document stays valid" do
      File.binwrite(log_path, "ok \xFF\xFE bytes\n")

      command.log(name: "api", json: true)

      expect(document["lines"]).to eq(["ok ?? bytes"])
    end

    it "keeps the first line when the 1 MiB boundary falls exactly on a line start" do
      # 5 bytes of head, then exactly 1 MiB of lines: the read starts right after a newline
      File.write(log_path, "z" * 4 + "\n" + ("y" * 1023 + "\n") * 1024)

      command.log(name: "api", lines: 5000, json: true)

      expect(document["lines"].size).to eq(1024)
      expect(document["lines"].first).to eq("y" * 1023)
    end

    it "rejects a count outside 1..10000 as a usage error" do
      [0, -1, 10_001].each do |bad|
        expect { command.log(name: "api", lines: bad) }.to raise_error(Workspace::UsageError, /--lines/)
      end
    end

    it "raises a Workspace::Error when the log can't be read" do
      FileUtils.mkdir_p(log_path)

      expect { command.log(name: "api") }.to raise_error(Workspace::Error, /Can't read #{Regexp.escape(log_path)}/)
    end
  end

  describe "#restart" do
    before { up[0] = true }

    it "stops the running daemon with SIGTERM, then starts one through EnsureAgent" do
      pids.replace([[4242], [4311]])

      result = command.restart(name: "api", wc_socket: "/tmp/wc.sock")

      expect(signals).to eq([["TERM", 4242]])
      expect(ensure_calls).to eq([{name: "api", wc_socket: "/tmp/wc.sock"}])
      expect(result).to have_attributes(outcome: "restarted", old_pid: 4242, pid: 4311)
      expect(result).to be_ok
    end

    it "starts one without signalling anything when none is running and nothing holds the socket" do
      up[0] = false
      pids.replace([[]])

      result = command.restart(name: "api")

      expect(signals).to eq([])
      expect(result).to have_attributes(outcome: "started", old_pid: nil)
    end

    it "stops a hung daemon that holds the socket but no longer answers" do
      up[0] = false
      pids.replace([[4242], [4311]])

      result = command.restart(name: "api")

      expect(signals).to eq([["TERM", 4242]])
      expect(result).to have_attributes(outcome: "restarted", old_pid: 4242)
      expect(ensure_calls.size).to eq(1)
    end

    it "waits for the old process to exit, not only for the socket to stop answering" do
      polls = [0]
      slow = build(sleeper: ->(seconds) {
        now[0] += seconds
        polls[0] += 1
        alive_pids.delete(4242) if polls[0] == 3
      }, stop_timeout: 5, signaller: ->(signal, pid) {
        raise Errno::ESRCH unless alive_pids.include?(pid)
        signals << [signal, pid] unless signal == 0
        up[0] = false unless signal == 0
      })

      expect(slow.restart(name: "api")).to be_ok
      expect(polls[0]).to eq(3)
      expect(ensure_calls.size).to eq(1)
    end

    it "fails without starting a second daemon when the old one is still running at the deadline, saying to re-run" do
      result = build(signaller: ->(*) {}).restart(name: "api")

      expect(result).to have_attributes(outcome: "failed", reason: "not_stopped", old_pid: 4242)
      expect(result.message).to include("still running 1s after SIGTERM", "workspace daemon status api", "workspace daemon restart api")
      expect(ensure_calls).to eq([])
    end

    it "refuses, signalling nothing, when lsof finds no process for an answering daemon" do
      pids.replace([[]])

      result = command.restart(name: "api")

      expect(result).to have_attributes(outcome: "failed", reason: "not_stopped")
      expect(result.message).to include("lsof found none")
      expect(signals).to eq([])
      expect(ensure_calls).to eq([])
    end

    it "refuses, signalling nothing, when several processes have the socket open" do
      pids.replace([[4242, 5000]])

      result = command.restart(name: "api")

      expect(result.reason).to eq("not_stopped")
      expect(result.message).to include("2 processes")
      expect(signals).to eq([])
    end

    it "refuses several owners of a socket nothing answers on too" do
      up[0] = false
      pids.replace([[4242, 5000]])

      expect(command.restart(name: "api").reason).to eq("not_stopped")
      expect(signals).to eq([])
      expect(ensure_calls).to eq([])
    end

    it "never signals its own process" do
      pids.replace([[Process.pid, 4242]])

      command.restart(name: "api")

      expect(signals).to eq([["TERM", 4242]])
    end

    it "refuses with not_agentd when the socket holder isn't an agentd process" do
      pids.replace([[5000]])

      result = command.restart(name: "api")

      expect(result).to have_attributes(outcome: "failed", reason: "not_agentd", old_pid: 5000)
      expect(result.message).to include("pid 5000", "/usr/bin/vim", "not signalling it")
      expect(signals).to eq([])
      expect(ensure_calls).to eq([])
    end

    it "refuses with not_agentd when the pid is no longer in the process table" do
      pids.replace([[7777]])

      result = command.restart(name: "api")

      expect(result).to have_attributes(reason: "not_agentd")
      expect(result.message).to include("is not in the process table")
      expect(signals).to eq([])
    end

    it "does not take a command that merely mentions agentd in argv[0] for the daemon" do
      process_table[4242] = {pid: 4242, args: "/opt/agentd/bin/other --name api"}

      expect(command.restart(name: "api").reason).to eq("not_agentd")
      expect(signals).to eq([])
    end

    it "refuses, signalling nothing, when the process table can't be read" do
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "could not read the process table (ps failed: x)")

      result = command.restart(name: "api")

      expect(result).to have_attributes(outcome: "failed", reason: "not_stopped")
      expect(result.message).to include("couldn't confirm pid 4242", "ps failed")
      expect(signals).to eq([])
    end

    it "treats a process that is already gone as stopped" do
      gone = ->(signal, pid) {
        up[0] = false
        raise Errno::ESRCH
      }

      expect(build(signaller: gone).restart(name: "api")).to have_attributes(outcome: "restarted")
    end

    it "keeps waiting while the old pid answers a probe with EPERM, then fails not_stopped at the deadline" do
      probing = ->(signal, pid) {
        raise Errno::EPERM if signal == 0

        signals << [signal, pid]
        up[0] = false
      }

      result = build(signaller: probing).restart(name: "api")

      expect(result).to have_attributes(outcome: "failed", reason: "not_stopped")
      expect(ensure_calls).to eq([])
    end

    it "fails when the signal is refused, without starting another daemon" do
      result = build(signaller: ->(*) { raise Errno::EPERM }).restart(name: "api")

      expect(result).to have_attributes(outcome: "failed", reason: "not_stopped")
      expect(ensure_calls).to eq([])
    end

    it "reports an invalid pipeline config as its own reason, after stopping the old daemon" do
      allow(ensure_agent).to receive(:call).and_return(Workspace::Commands::EnsureAgent::Result.new(:invalid_config))

      result = command.restart(name: "api")

      expect(result).to have_attributes(outcome: "failed", reason: "invalid_config", old_pid: 4242)
    end

    it "reports a failed start with the detail" do
      up[0] = false
      pids.replace([[]])
      allow(ensure_agent).to receive(:call).and_return(Workspace::Commands::EnsureAgent::Result.new(:failed, "it did not answer within 5s"))

      result = command.restart(name: "api")

      expect(result).to have_attributes(outcome: "failed", reason: "start_failed")
      expect(result.message).to include("it did not answer within 5s")
    end

    it "reports a null pid when the new daemon's process can't be identified right after it starts" do
      pids.replace([[4242], []])

      expect(command.restart(name: "api")).to have_attributes(outcome: "restarted", old_pid: 4242, pid: nil)
    end

    it "refuses, signalling and starting nothing, when lsof doesn't answer in time" do
      [true, false].each do |answering|
        up[0] = answering

        result = build(pid_finder: ->(_path) {}).restart(name: "api")

        expect(result).to have_attributes(outcome: "failed", reason: "not_stopped", old_pid: nil)
        expect(result.message).to include("lsof did not answer within 2s", "nothing was stopped")
      end
      expect(signals).to eq([])
      expect(ensure_calls).to eq([])
    end

    describe "the work-coordinator socket" do
      def restart_with(args, **options)
        process_table[4242] = {pid: 4242, args: args}
        command.restart(name: "api", **options)
      end

      it "starts the new daemon with the socket the old one was started with" do
        result = restart_with("#{agentd_args} --wc-socket /tmp/wc-dev.sock")

        expect(ensure_calls).to eq([{name: "api", wc_socket: "/tmp/wc-dev.sock"}])
        expect(result).to have_attributes(outcome: "restarted", wc_socket: "/tmp/wc-dev.sock")
      end

      it "reads the --wc-socket=PATH form and a flag that follows the path" do
        restart_with("ruby /opt/bin/workspace agentd --wc-socket=/tmp/wc-dev.sock --name api")
        expect(ensure_calls.last).to eq(name: "api", wc_socket: "/tmp/wc-dev.sock")

        up[0] = true
        alive_pids << 4242
        restart_with("ruby /opt/bin/workspace agentd --wc-socket /tmp/wc-dev.sock --force --name api")
        expect(ensure_calls.last).to eq(name: "api", wc_socket: "/tmp/wc-dev.sock")
      end

      it "does not take a positional workspace name after the path for part of it" do
        restart_with("ruby /opt/bin/workspace agentd --wc-socket /tmp/wc-dev.sock api")

        expect(ensure_calls).to eq([{name: "api", wc_socket: "/tmp/wc-dev.sock"}])
      end

      it "prefers the socket the caller names over the old daemon's" do
        result = restart_with("#{agentd_args} --wc-socket /tmp/old.sock", wc_socket: "/tmp/new.sock")

        expect(ensure_calls).to eq([{name: "api", wc_socket: "/tmp/new.sock"}])
        expect(result.wc_socket).to eq("/tmp/new.sock")
      end

      it "starts the new daemon on the default socket when the old one named none" do
        result = restart_with(agentd_args)

        expect(ensure_calls).to eq([{name: "api", wc_socket: nil}])
        expect(result.wc_socket).to be_nil
      end

      it "refuses, stopping nothing, when the old daemon's socket path can't be read back" do
        {
          "a path with a space" => "#{agentd_args} --wc-socket /tmp/my sockets/wc.sock",
          "a relative path" => "#{agentd_args} --wc-socket wc.sock",
          "no value" => "#{agentd_args} --wc-socket"
        }.each do |label, args|
          result = restart_with(args)

          expect(result).to have_attributes(outcome: "failed", reason: "wc_socket_unknown", old_pid: 4242), label
          expect(result.message).to include("nothing was stopped", "workspace daemon restart api --wc-socket PATH"), label
          expect(result.wc_socket).to be_nil, label
        end
        expect(signals).to eq([])
        expect(ensure_calls).to eq([])
      end

      it "reads the flag in the abbreviations the daemon's own parser takes" do
        ["--wc /tmp/wc-dev.sock", "--wc-sock=/tmp/wc-dev.sock", "--w /tmp/wc-dev.sock"].each do |flag|
          up[0] = true
          alive_pids << 4242 unless alive_pids.include?(4242)
          restart_with("ruby /opt/bin/workspace agentd --name api #{flag}")

          expect(ensure_calls.last).to eq({name: "api", wc_socket: "/tmp/wc-dev.sock"}), flag
        end
      end

      it "reads the last --wc-socket when the flag was given twice, as the daemon did" do
        restart_with("#{agentd_args} --wc-socket /tmp/first.sock --wc-socket /tmp/last.sock")

        expect(ensure_calls).to eq([{name: "api", wc_socket: "/tmp/last.sock"}])
      end

      # ps joins argv with spaces, so these can't be told from the shapes they
      # look like. Documented in docs/README.daemon.md; --wc-socket PATH is the way out.
      it "misreads a path with a space whose tail looks like the workspace name or a flag" do
        restart_with("ruby /opt/bin/workspace agentd api --wc-socket /tmp/wc api")
        expect(ensure_calls.last).to eq(name: "api", wc_socket: "/tmp/wc")

        up[0] = true
        alive_pids << 4242
        restart_with("#{agentd_args} --wc-socket /a -b/wc.sock")
        expect(ensure_calls.last).to eq(name: "api", wc_socket: "/a")
      end

      it "keeps a trailing word that equals the name as part of the path when --name gave the name, and refuses" do
        result = restart_with("#{agentd_args} --wc-socket /tmp/wc api")

        expect(result.reason).to eq("wc_socket_unknown")
        expect(signals).to eq([])
      end

      it "names the socket in the message and the result when the old daemon doesn't stop in time" do
        process_table[4242] = {pid: 4242, args: "#{agentd_args} --wc-socket /tmp/wc-dev.sock"}

        result = build(signaller: ->(*) {}).restart(name: "api")

        expect(result).to have_attributes(outcome: "failed", reason: "not_stopped", wc_socket: "/tmp/wc-dev.sock")
        expect(result.message).to include("workspace daemon restart api --wc-socket /tmp/wc-dev.sock")
      end

      it "names the socket when the old daemon was stopped and the new one didn't start" do
        {invalid_config: "invalid_config", failed: "start_failed"}.each do |status, reason|
          up[0] = true
          alive_pids << 4242 unless alive_pids.include?(4242)
          allow(ensure_agent).to receive(:call).and_return(Workspace::Commands::EnsureAgent::Result.new(status, "no answer"))

          result = restart_with("#{agentd_args} --wc-socket /tmp/wc-dev.sock")

          expect(result).to have_attributes(outcome: "failed", reason: reason, wc_socket: "/tmp/wc-dev.sock"), reason
          expect(result.message).to include("workspace daemon restart api --wc-socket /tmp/wc-dev.sock"), reason
        end
      end

      it "adds no socket hint to a failure when there is no socket to name" do
        result = build(signaller: ->(*) {}).restart(name: "api")

        expect(result).to have_attributes(reason: "not_stopped", wc_socket: nil)
        expect(result.message).not_to include("--wc-socket")
      end

      it "reports no socket when another caller started the daemon between the stop and the start" do
        allow(ensure_agent).to receive(:call) do
          up[0] = true
          Workspace::Commands::EnsureAgent::Result.new(:running)
        end

        result = restart_with("#{agentd_args} --wc-socket /tmp/wc-dev.sock")

        expect(result).to have_attributes(outcome: "restarted", old_pid: 4242, wc_socket: nil)
      end

      it "restarts a daemon whose socket path can't be read back when the caller names one" do
        result = restart_with("#{agentd_args} --wc-socket /tmp/my sockets/wc.sock", wc_socket: "/tmp/my sockets/wc.sock")

        expect(result).to have_attributes(outcome: "restarted", wc_socket: "/tmp/my sockets/wc.sock")
        expect(signals).to eq([["TERM", 4242]])
      end
    end
  end

  describe "finding the socket's processes with lsof" do
    let(:pid_file) { File.join(tmpdir, "lsof.pid") }

    def fake_lsof(body)
      File.join(tmpdir, "lsof").tap do |path|
        File.write(path, "#!/bin/sh\n#{body}\n")
        File.chmod(0o755, path)
      end
    end

    def status_pid(**overrides)
      up[0] = true
      described_class.new(config: config, project_config: project_config, ensure_agent: ensure_agent, output: output, **overrides)
        .status(name: "api", json: true)
      document["pid"]
    end

    it "asks `lsof -t SOCKET` and reads the pid it prints" do
      lsof = fake_lsof(%([ "$1" = "-t" ] && [ "$2" = "#{socket_path}" ] || exit 1\necho 4242))

      expect(status_pid(lsof_command: [lsof, "-t"])).to eq(4242)
    end

    it "takes no output and exit status 1, as lsof gives when no process has the file open, for no pid" do
      expect(status_pid(lsof_command: [fake_lsof("exit 1"), "-t"])).to be_nil
    end

    it "reads every pid when lsof prints several, one per line, and refuses to pick one" do
      lsof = fake_lsof("echo 4242\necho 5000")
      up[0] = true
      command = described_class.new(config: config, project_config: project_config, ensure_agent: ensure_agent, process_tree: process_tree,
        signaller: signaller, lsof_command: [lsof, "-t"], output: output)

      result = command.restart(name: "api")

      expect(result.reason).to eq("not_stopped")
      expect(result.message).to include("2 processes have its socket open")
      expect(signals).to eq([])
    end

    it "takes a missing lsof for no pid" do
      expect(status_pid(lsof_command: [File.join(tmpdir, "no-such-lsof"), "-t"])).to be_nil
    end

    it "gives up on an lsof that hangs, kills it, and reports no pid" do
      lsof = fake_lsof("echo $$ > #{pid_file}\nexec sleep 30")

      expect(status_pid(lsof_command: [lsof, "-t"], lsof_timeout: 0.5)).to be_nil
      expect { Process.kill(0, File.read(pid_file).to_i) }.to raise_error(Errno::ESRCH)
    end
  end
end
