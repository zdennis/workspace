require "tmpdir"

# One fake tmux server shared across threads. A tmuxinator started from an
# iTerm pane makes its session asynchronously, after +pane_start_delay+.
class T9Tmux
  attr_reader :headless_starts

  def initialize(live: [], pane_start_delay: 0.3)
    @mutex = Mutex.new
    @live = live.dup
    @headless_starts = []
    @pane_start_delay = pane_start_delay
    @threads = []
  end

  def start_server = nil

  def custom_socket_option(_project) = nil

  def rename_window(*) = nil

  def session_name_for(project) = "tmux-#{project}"

  def command_for(project, reattach: false) = "tmuxinator start #{project} --attach"

  def reattach_or_start(session, start) = "tmux -CC attach -t #{session} || tmux has-session -t #{session} 2>/dev/null || #{start}"

  def sessions = @mutex.synchronize { @live.dup }

  def add(session) = @mutex.synchronize { @live << session unless @live.include?(session) }

  def remove(session) = @mutex.synchronize { @live.delete(session) }

  def start_headless(project)
    @mutex.synchronize { @headless_starts << project }
    add(session_name_for(project))
    nil
  end

  # Runs +command+ the way a new launcher pane's shell would: `a || b`
  # tries each clause until one succeeds. Returns whether the pane ended up
  # attached to a session.
  def run_in_pane(command)
    command.split("||").map(&:strip).any? do |clause|
      if (m = clause.match(/\Atmux -CC attach -t (\S+)\z/))
        sessions.include?(m[1])
      elsif (m = clause.match(/\Atmux has-session -t (\S+) 2>\/dev\/null\z/))
        sessions.include?(m[1])
      elsif (m = clause.match(/\Atmuxinator start (\S+)/))
        session = session_name_for(m[1])
        @threads << Thread.new do
          sleep @pane_start_delay
          add(session)
        end
        true
      else
        false
      end
    end
  end

  def join_threads = @threads.each { |t| t.join(5) || t.kill }
end

class T9ITerm
  attr_reader :commands

  def initialize(tmux:, uid:, before_create: nil, after_create: nil)
    @tmux = tmux
    @uid = uid
    @before_create = before_create
    @after_create = after_create
    @commands = []
  end

  def session_map = {}

  def find_existing_sessions(_state, live_sessions: nil) = {}

  def find_launcher_window_id(_state, live_sessions: nil) = nil

  def create_launcher_panes(projects, commands, launcher_wid: nil)
    @before_create&.call
    @commands.concat(commands.values)
    commands.each_value { |command| @tmux.run_in_pane(command) }
    @after_create&.call
    projects.to_h { |p| [p, @uid] }
  end
end

RSpec.describe "T9 windowed launch reuse: concurrency and liveness (adversarial)" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:threads) { [] }

  before do
    allow(config).to receive(:state_file).and_return(File.join(tmpdir, "state.json"))
    allow(config).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
    allow(config).to receive(:agent_running?).and_return(true)
    allow(config).to receive(:state_dir).and_return(File.join(tmpdir, "xdg-state"))
  end

  after do
    threads.each { |t| t.join(5) || t.kill }
    FileUtils.rm_rf(tmpdir)
  end

  def new_state
    Workspace::State.new(config: config, event_log: Workspace::EventLog.new(config: config))
  end

  def new_launch(tmux:, iterm: double("iterm"), state: new_state,
    window_manager: double("window_manager", iterm_windows: {101 => "workspace-tmux-proj"}, close_window: true))
    Workspace::Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager,
      tmux: tmux, project_config: double("project_config", exists?: true),
      window_layout: double("window_layout", arrange: nil), config: config,
      pipeline_config: double("pipeline_config", stages_for: nil, literal_sentinel_warnings: []),
      agent_readiness: instance_double(Workspace::AgentReadiness, deadline_in: 60.0), prompt_timeout: 60,
      sleeper: ->(_seconds) { sleep 0.02 }, output: output, error_output: error_output)
  end

  def start_lock_path(project)
    dir = File.join(config.state_dir, "launch")
    FileUtils.mkdir_p(dir)
    File.join(dir, "#{project}.lock")
  end

  it "TC1: a windowed launch waits for a headless start holding the project's start lock instead of running tmuxinator alongside it" do
    tmux = T9Tmux.new
    iterm = T9ITerm.new(tmux: tmux, uid: "uid-w")
    launch = new_launch(tmux: tmux, iterm: iterm)

    File.open(start_lock_path("proj"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      threads << Thread.new { launch.call(["proj"]) }
      sleep 0.3
      # The headless start holding the lock has now made the session.
      tmux.add("tmux-proj")
    end
    threads.each { |t| t.join(10) }
    tmux.join_threads

    expect(iterm.commands).to eq(["tmux -CC attach -t tmux-proj || tmux has-session -t tmux-proj 2>/dev/null || tmuxinator start proj --attach"]),
      "the windowed launch ignored the start lock and ran #{iterm.commands.inspect} into a session being started"
  end

  it "TC2: two concurrent windowed launches of one untracked project run tmuxinator only once" do
    tmux = T9Tmux.new(pane_start_delay: 0.3)
    a = T9ITerm.new(tmux: tmux, uid: "uid-a")
    b = T9ITerm.new(tmux: tmux, uid: "uid-b")

    threads << Thread.new { new_launch(tmux: tmux, iterm: a).call(["proj"]) }
    threads << Thread.new { new_launch(tmux: tmux, iterm: b).call(["proj"]) }
    threads.each { |t| t.join(10) }
    tmux.join_threads

    starts = (a.commands + b.commands).grep(/\Atmuxinator start/)
    expect(starts.size).to eq(1),
      "both windowed launches saw no session and ran tmuxinator (#{starts.size} starts)"
  end

  it "TC3: a headless start while a windowed launch's tmuxinator is still starting reuses that session" do
    tmux = T9Tmux.new(pane_start_delay: 0.3)
    headless = new_launch(tmux: tmux, iterm: T9ITerm.new(tmux: tmux, uid: "unused"))
    iterm = T9ITerm.new(tmux: tmux, uid: "uid-w",
      after_create: -> { threads << Thread.new { headless.call(["proj"], headless: true) } })

    new_launch(tmux: tmux, iterm: iterm).call(["proj"])
    threads.each { |t| t.join(10) }
    tmux.join_threads

    expect(iterm.commands.grep(/\Atmuxinator start/).size).to eq(1)
    expect(tmux.headless_starts).to eq([]),
      "the headless start took the free lock and ran tmuxinator into the session the windowed pane was starting"
  end

  it "TC4: a session killed between the running check and pane creation is started, not attached to and lost" do
    tmux = T9Tmux.new(live: ["tmux-proj"], pane_start_delay: 0.01)
    iterm = T9ITerm.new(tmux: tmux, uid: "uid-w", before_create: -> { tmux.remove("tmux-proj") })
    launch = new_launch(tmux: tmux, iterm: iterm)

    launch.call(["proj"])
    tmux.join_threads

    expect(tmux.sessions).to include("tmux-proj"),
      "the pane ran #{iterm.commands.inspect}; with the session gone it attached to nothing and the project has no session"
    expect(error_output.string).not_to include("Timed out waiting for sessions")
  end

  it "TC5: a windowed launch interleaved with a headless start never leaves an entry both headless and windowed" do
    tmux = T9Tmux.new
    windowed_iterm = T9ITerm.new(tmux: tmux, uid: "uid-w")
    windowed = new_launch(tmux: tmux, iterm: windowed_iterm)
    headless = new_launch(tmux: tmux, iterm: T9ITerm.new(tmux: tmux, uid: "unused"))

    allow(tmux).to receive(:start_headless).and_wrap_original do |m, project|
      result = m.call(project)
      # The windowed launch runs after the headless one loaded state but
      # before it records the project; it may wait on the start lock.
      threads << Thread.new { windowed.call(["proj"]) }
      threads.last.join(2)
      result
    end

    headless.call(["proj"], headless: true)
    threads.each { |t| t.join(10) }
    tmux.join_threads

    entry = new_state.load["proj"]
    expect(entry.key?("headless") && entry.key?("unique_id")).to be(false),
      "state merged both launches into #{entry.inspect}: marked headless while tracking launcher pane uid-w"
  end

  it "TC7: a headless start closes the launcher window of a windowed launch recorded after it loaded state" do
    tmux = T9Tmux.new
    iterm = double("iterm", session_map: {"uid-w" => 7})
    allow(iterm).to receive(:find_existing_sessions) do |state, **|
      state.to_h.filter_map { |project, info| [project, info["unique_id"]] if info["unique_id"] }.to_h
    end
    window_manager = double("window_manager", close_window: true)
    headless = new_launch(tmux: tmux, iterm: iterm, window_manager: window_manager)

    allow(tmux).to receive(:start_headless).and_wrap_original do |m, project|
      # A windowed launch records its pane after the headless one loaded state.
      new_state.load["proj"] = {"unique_id" => "uid-w", "iterm_window_id" => 7}
      m.call(project)
    end

    headless.call(["proj"], headless: true)

    expect(window_manager).to have_received(:close_window).with(7)
    expect(new_state.load["proj"]).to eq({"headless" => true})
  end

  it "TC8: a --reattach pane whose session is killed just before the attach starts the session instead of attaching to nothing" do
    config_path = config.config_path_for("proj")
    FileUtils.mkdir_p(File.dirname(config_path))
    File.write(config_path, "name: proj\nroot: /tmp\n")
    real_tmux = Workspace::Tmux.new(config: config)
    allow(real_tmux).to receive(:sessions).and_return(["proj"])

    command = real_tmux.command_for("proj", reattach: true)
    pane_tmux = T9Tmux.new(live: [], pane_start_delay: 0.01)

    expect(pane_tmux.run_in_pane(command)).to be(true),
      "the pane ran #{command.inspect}; with the session gone it attached to nothing and never started it"
    pane_tmux.join_threads
  end

  it "TC9: a --reattach pane whose attach client exits nonzero for another reason, with the session still alive, never restarts tmuxinator" do
    config_path = config.config_path_for("proj")
    FileUtils.mkdir_p(File.dirname(config_path))
    File.write(config_path, "name: proj\nroot: /tmp\n")
    real_tmux = Workspace::Tmux.new(config: config)
    allow(real_tmux).to receive(:sessions).and_return(["proj"])

    command = real_tmux.command_for("proj", reattach: true)
    # Session is still live even though the attach client itself failed
    # (e.g. a detach keybinding, terminal resize race, etc).
    pane_tmux = T9Tmux.new(live: ["proj"], pane_start_delay: 0.01)

    pane_tmux.run_in_pane(command)
    pane_tmux.join_threads

    expect(pane_tmux.headless_starts).to eq([]),
      "tmuxinator was restarted even though the session was still alive: #{command.inspect}"
  end

  it "TC6: listing sessions on a wedged tmux server gives up instead of blocking launch forever" do
    bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(bin)
    pid_file = File.join(tmpdir, "tmux.pid")
    File.write(File.join(bin, "tmux"), "#!/bin/sh\necho $$ > '#{pid_file}'\nexec sleep 30\n")
    File.chmod(0o755, File.join(bin, "tmux"))
    tmux = Workspace::Tmux.new(config: config, command_timeout: 0.5)

    original_path = ENV["PATH"]
    ENV["PATH"] = "#{bin}:#{original_path}"
    thread = Thread.new do
      tmux.sessions
    rescue Workspace::Error => e
      e
    end
    begin
      expect(thread.join(4)).not_to be_nil, "Tmux#sessions was still blocked on `tmux list-sessions` after 4s (no timeout)"
      expect(thread.value).to be_a(Workspace::Error)
      expect(thread.value.message).to match(/tmux list-sessions did not respond within 0.5s/)
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
end
