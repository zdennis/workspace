require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AgentDaemonStopper do
  let(:tmpdir) { Dir.mktmpdir }
  let(:answering) { [] }
  let(:holders) { {} }
  let(:table) { {} }
  let(:alive) { [] }
  let(:stuck) { [] }
  let(:signals) { [] }
  let(:signal_error) { [] }
  let(:now) { [0.0] }
  let(:config) do
    dir = tmpdir
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:agent_socket_path) { |name| File.join(dir, "workspace-#{name}.sock") }
      allow(c).to receive(:agent_running?) { |name| answering.include?(name) }
    end
  end
  let(:process_tree) do
    rows = table
    snapshot = Struct.new(:rows) { def find(pid) = rows[pid] }.new(rows)
    double("process_tree", snapshot: snapshot)
  end
  let(:signaller) do
    ->(signal, pid) {
      raise signal_error.first if signal_error.any? && signal == "TERM"
      raise Errno::ESRCH unless alive.include?(pid)
      next if signal == 0

      signals << [signal, pid]
      next if stuck.include?(pid)

      alive.delete(pid)
      holders.delete_if { |_, held| held == pid }
      answering.reject! { |name| !holders.key?(name) }
    }
  end
  let(:pid_finder) do
    ->(path) {
      name = File.basename(path)[/workspace-(.*)\.sock/, 1]
      [holders[name]].compact
    }
  end
  let(:stopper) do
    described_class.new(config: config, process_tree: process_tree, pid_finder: pid_finder, signaller: signaller,
      sleeper: ->(s) { now[0] += s }, clock: -> { now[0] }, stop_timeout: 1)
  end

  def run_daemon(name, pid, args: "/usr/bin/ruby /opt/workspace/bin/workspace agentd --name #{name}", answers: true)
    holders[name] = pid
    table[pid] = {pid: pid, args: args}
    alive << pid
    answering << name if answers
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    it "terminates the daemon and reports it stopped" do
      run_daemon("api", 4242)

      result = stopper.call(name: "api")

      expect(result.status).to eq(:stopped)
      expect(result.pid).to eq(4242)
      expect(result).to be_frozen
      expect(result).to be_ok
      expect(signals).to eq([["TERM", 4242]])
    end

    it "stops a hung daemon that holds the socket but no longer answers" do
      run_daemon("api", 4242, answers: false)

      expect(stopper.call(name: "api").status).to eq(:stopped)
    end

    it "needs no config for the workspace, only its name" do
      run_daemon("gone", 7)

      expect(stopper.call(name: "gone").status).to eq(:stopped)
    end

    it "counts ESRCH after TERM as stopped" do
      run_daemon("api", 4242)
      signal_error << Errno::ESRCH
      alive.delete(4242)
      answering.delete("api")

      expect(stopper.call(name: "api").status).to eq(:stopped)
    end

    it "reports not_running when nothing holds the socket and nothing answers" do
      result = stopper.call(name: "api")

      expect(result.status).to eq(:not_running)
      expect(result.pid).to be_nil
      expect(result).to be_ok
      expect(signals).to be_empty
    end

    it "reports timed_out when the daemon is still there at the stop timeout" do
      run_daemon("api", 4242)
      stuck << 4242

      result = stopper.call(name: "api")

      expect(result.status).to eq(:timed_out)
      expect(result.pid).to eq(4242)
      expect(now[0]).to be >= 1.0
      expect(result).not_to be_ok
    end

    it "refuses without signalling when lsof does not answer" do
      run_daemon("api", 4242)
      stopper = described_class.new(config: config, process_tree: process_tree, pid_finder: ->(_) {}, signaller: signaller)

      result = stopper.call(name: "api")

      expect(result.status).to eq(:refused)
      expect(result.message).to include("lsof did not answer")
      expect(signals).to be_empty
    end

    it "refuses when more than one process holds the socket" do
      run_daemon("api", 1)
      run_daemon("api", 2)
      stopper = described_class.new(config: config, process_tree: process_tree, pid_finder: ->(_) { [1, 2] }, signaller: signaller)

      result = stopper.call(name: "api")

      expect(result.status).to eq(:refused)
      expect(result.message).to include("2 processes")
      expect(signals).to be_empty
    end

    it "refuses when lsof finds none but the socket answers" do
      answering << "api"
      stopper = described_class.new(config: config, process_tree: process_tree, pid_finder: ->(_) { [] }, signaller: signaller)

      result = stopper.call(name: "api")

      expect(result.status).to eq(:refused)
      expect(result.message).to include("lsof found none")
      expect(signals).to be_empty
    end

    it "refuses a holder that is not agentd, such as a reused pid" do
      run_daemon("api", 4242, args: "/usr/bin/vim notes.md")

      result = stopper.call(name: "api")

      expect(result.status).to eq(:refused)
      expect(result.message).to include("not `workspace agentd`")
      expect(signals).to be_empty
    end

    it "refuses a holder missing from the process table" do
      run_daemon("api", 4242)
      table.clear

      result = stopper.call(name: "api")

      expect(result.status).to eq(:refused)
      expect(result.message).to include("is not in the process table")
    end

    it "refuses when the process table can't be read" do
      run_daemon("api", 4242)
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps timed out")

      result = stopper.call(name: "api")

      expect(result.status).to eq(:refused)
      expect(result.message).to include("ps timed out")
      expect(signals).to be_empty
    end

    it "refuses a holder whose --name is another workspace" do
      run_daemon("api", 4242, args: "workspace agentd --name web")

      result = stopper.call(name: "api")

      expect(result.status).to eq(:refused)
      expect(result.message).to include("agentd for web")
      expect(signals).to be_empty
    end

    it "refuses a holder whose --name=VALUE is another workspace" do
      run_daemon("api", 4242, args: "workspace agentd --name=web")

      expect(stopper.call(name: "api").status).to eq(:refused)
    end

    it "refuses a holder whose positional name is another workspace" do
      run_daemon("api", 4242, args: "workspace agentd web")

      expect(stopper.call(name: "api").status).to eq(:refused)
    end

    it "accepts the --name=VALUE form" do
      run_daemon("api", 4242, args: "workspace agentd --name=api")

      expect(stopper.call(name: "api").status).to eq(:stopped)
    end

    it "accepts the positional-name form" do
      run_daemon("api", 4242, args: "workspace agentd api")

      expect(stopper.call(name: "api").status).to eq(:stopped)
    end

    it "accepts a positional name after a work-coordinator socket" do
      run_daemon("api", 4242, args: "workspace agentd --wc-socket /tmp/wc.sock api")

      expect(stopper.call(name: "api").status).to eq(:stopped)
    end

    it "reads a positional name after a flag that takes no value" do
      run_daemon("api", 4242, args: "workspace agentd --debug web")

      expect(stopper.call(name: "api").status).to eq(:refused)
    end

    it "matches the name the way WorkspaceName.same? does" do
      run_daemon("Api", 4242, args: "workspace agentd --name api")

      expect(stopper.call(name: "Api").status).to eq(:stopped)
    end

    it "accepts a daemon whose command line names no workspace" do
      run_daemon("api", 4242, args: "workspace agentd --wc-socket /tmp/wc.sock")

      expect(stopper.call(name: "api").status).to eq(:stopped)
    end

    it "refuses when the signal can't be sent" do
      run_daemon("api", 4242)
      signal_error << Errno::EPERM

      result = stopper.call(name: "api")

      expect(result.status).to eq(:refused)
      expect(result.message).to include("couldn't stop the daemon for api (pid 4242)")
    end

    it "never signals this process, even when the finder names it" do
      stopper = described_class.new(config: config, process_tree: process_tree, pid_finder: ->(_) { [Process.pid] }, signaller: signaller)

      result = stopper.call(name: "api")

      expect(result.status).to eq(:not_running)
      expect(signals).to be_empty
    end

    it "never signals this process when asked to terminate it directly" do
      expect(stopper.terminate("api", Process.pid).status).to eq(:refused)
      expect(signals).to be_empty
    end
  end

  describe Workspace::AgentDaemonStopper::Result do
    it "gives a notice only for a stopped daemon" do
      expect(described_class.new(:stopped, 42, "x").notice("api")).to eq("Stopped agent daemon for api (pid 42)")
      expect(described_class.new(:not_running, nil, "x").notice("api")).to be_nil
      expect(described_class.new(:refused, 42, "x").notice("api")).to be_nil
    end

    it "gives a warning naming daemon status for a refusal or timeout" do
      %i[refused timed_out].each do |status|
        expect(described_class.new(status, 42, "it would not go").warning("api"))
          .to eq("Warning: it would not go. Check it with: workspace daemon status api")
      end
      expect(described_class.new(:stopped, 42, "x").warning("api")).to be_nil
      expect(described_class.new(:not_running, nil, "x").warning("api")).to be_nil
    end
  end

  describe "#find_pid" do
    it "returns the one holder's pid" do
      run_daemon("api", 4242)

      expect(stopper.find_pid("api")).to eq(4242)
    end

    it "is nil when none, several, or lsof didn't answer" do
      expect(stopper.find_pid("api")).to be_nil
      expect(described_class.new(config: config, pid_finder: ->(_) { [1, 2] }).find_pid("api")).to be_nil
      expect(described_class.new(config: config, pid_finder: ->(_) {}).find_pid("api")).to be_nil
    end
  end

  describe "#socket_pids" do
    it "leaves this process out and drops duplicates" do
      stopper = described_class.new(config: config, pid_finder: ->(_) { [5, Process.pid, 5, 0] })

      expect(stopper.socket_pids("api")).to eq([5])
    end

    it "asks about the socket file as the file system spells it" do
      File.write(File.join(tmpdir, "workspace-Api.sock"), "")
      asked = []
      allow(config).to receive(:agent_socket_path).with("api").and_return(File.join(tmpdir, "workspace-api.sock"))
      stopper = described_class.new(config: config, pid_finder: ->(path) {
        asked << path
        []
      })

      stopper.socket_pids("api")

      expect(asked).to eq([File.join(tmpdir, "workspace-Api.sock")])
    end
  end
end

RSpec.describe Workspace::AgentDaemonStopper, ".served_name" do
  it "reads the name from a string or words, in every form" do
    expect(described_class.served_name("ruby workspace agentd --name a")).to eq("a")
    expect(described_class.served_name(%w[ruby workspace agentd --name=b])).to eq("b")
    expect(described_class.served_name("ruby workspace agentd c")).to eq("c")
    expect(described_class.served_name("ruby workspace agentd")).to be_nil
    expect(described_class.served_name("vim notes")).to be_nil
  end
end
