require "tmpdir"
require "timeout"

# A tmux stand-in whose session list is shared across threads, like one tmux server.
class HeadlessRaceTmux
  attr_reader :start_calls

  def initialize(rendezvous: 0)
    @mutex = Mutex.new
    @live = []
    @start_calls = []
    @rendezvous = rendezvous
    @arrived = 0
    @cond = ConditionVariable.new
  end

  def start_server = nil

  def rename_window(*) = nil

  def session_name_for(project) = "tmux-#{project}"

  # The first `rendezvous` callers wait (briefly) for each other, so each
  # has listed the sessions before any of them starts one.
  def sessions
    @mutex.synchronize do
      if @arrived < @rendezvous
        @arrived += 1
        deadline = Time.now + 1
        @cond.broadcast
        @cond.wait(@mutex, deadline - Time.now) while @arrived < @rendezvous && Time.now < deadline
      end
      @live.dup
    end
  end

  # Like tmuxinator: the config was rendered before the session existed, so
  # the second run's new-session fails but the script carries on and exits 0.
  def start_headless(project)
    @mutex.synchronize do
      @start_calls << project
      @live << session_name_for(project)
    end
    nil
  end
end

RSpec.describe "headless launch: concurrency and liveness (adversarial)" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  before do
    allow(config).to receive(:state_file).and_return(File.join(tmpdir, "state.json"))
    allow(config).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
    allow(config).to receive(:agent_running?).and_return(true)
    allow(config).to receive(:state_dir).and_return(File.join(tmpdir, "xdg-state"))
  end

  after { FileUtils.rm_rf(tmpdir) }

  def new_state
    Workspace::State.new(config: config, event_log: Workspace::EventLog.new(config: config))
  end

  def new_launch(tmux:, sleeper: ->(_seconds) {})
    Workspace::Commands::Launch.new(state: new_state, iterm: double("iterm"), window_manager: double("window_manager"),
      tmux: tmux, project_config: double("project_config", exists?: true), window_layout: double("window_layout"),
      config: config, pipeline_config: double("pipeline_config", stages_for: nil, literal_sentinel_warnings: []),
      agent_readiness: instance_double(Workspace::AgentReadiness, deadline_in: 60.0), prompt_timeout: 60,
      sleeper: sleeper, output: output, error_output: error_output)
  end

  it "HC1: a wedged tmuxinator makes start_headless return a failure instead of blocking forever" do
    bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(bin)
    pid_file = File.join(tmpdir, "tmuxinator.pid")
    File.write(File.join(bin, "tmuxinator"), "#!/bin/sh\necho $$ > '#{pid_file}'\nexec sleep 30\n")
    File.chmod(0o755, File.join(bin, "tmuxinator"))
    source = File.join(tmpdir, "workspace.proj.yml")
    File.write(source, "name: proj\ntmux_options: -CC\nwindows:\n  - main: echo hi\n")
    allow(config).to receive(:config_path_for).with("proj").and_return(source)

    accepts_timeout = Workspace::Tmux.instance_method(:initialize).parameters.any? { |_, name| name == :start_timeout }
    tmux = accepts_timeout ? Workspace::Tmux.new(config: config, start_timeout: 0.5) : Workspace::Tmux.new(config: config)

    original_path = ENV["PATH"]
    ENV["PATH"] = "#{bin}:#{original_path}"
    result = nil
    thread = Thread.new { result = tmux.start_headless("proj") }
    begin
      finished = thread.join(1.5)
      expect(finished).not_to be_nil, "start_headless was still blocked on tmuxinator after 1.5s (no timeout)"
      expect(result).to match(/tmuxinator/)
    ensure
      ENV["PATH"] = original_path
      if File.exist?(pid_file)
        pid = File.read(pid_file).to_i
        begin
          Process.kill("KILL", pid) if pid > 1 && pid != Process.pid
        rescue Errno::ESRCH
        end
      end
      thread.join(5) || thread.kill
    end
  end

  it "HC2: two concurrent headless launches of one project start its session only once" do
    tmux = HeadlessRaceTmux.new(rendezvous: 2)
    a = new_launch(tmux: tmux)
    b = new_launch(tmux: tmux)

    # The shared state file can also collide here (see HC5); only the starts matter.
    run = ->(launch) {
      begin
        launch.call(["proj"], headless: true)
      rescue
        SystemCallError
      end
    }
    threads = [Thread.new { run.call(a) }, Thread.new { run.call(b) }]
    threads.each { |t| t.join(5) || t.kill }

    expect(tmux.start_calls).to eq(["proj"]),
      "both launches passed the running-session check and ran tmuxinator (#{tmux.start_calls.size} starts)"
  end

  it "HC3: checks for the session before sleeping, since tmuxinator --no-attach has already created it" do
    slept = []
    tmux = HeadlessRaceTmux.new
    launch = new_launch(tmux: tmux, sleeper: ->(seconds) { slept << seconds })

    result = launch.call(["proj"], headless: true)

    expect(result[:exit_code]).to eq(0)
    expect(slept).to eq([]), "slept #{slept.sum}s before looking for a session that already existed"
  end

  it "HC4: a session that never appears after tmuxinator succeeded is a failure, not a successful launch" do
    tmux = double("tmux", start_server: nil, rename_window: nil, sessions: [], start_headless: nil)
    allow(tmux).to receive(:session_name_for) { |project| "tmux-#{project}" }
    launch = new_launch(tmux: tmux)

    result = launch.call(["proj"], headless: true)

    expect(error_output.string).to include("Timed out waiting for sessions: proj")
    expect(result[:exit_code]).to eq(1)
    expect(output.string).not_to include("Attach with: tmux attach -t tmux-proj")
  end

  it "HC5: two launches saving state at the same moment both succeed" do
    first = new_state.load
    second = new_state.load
    first["proj-a"] = {"headless" => true}
    second["proj-b"] = {"headless" => true}

    interleaved = false
    allow(File).to receive(:rename).and_wrap_original do |original, from, to|
      unless interleaved
        interleaved = true
        second.save
      end
      original.call(from, to)
    end

    expect { first.save }.not_to raise_error
    expect(JSON.parse(File.read(config.state_file)).keys).to contain_exactly("proj-a", "proj-b")
  end
end
