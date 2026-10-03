require "stringio"
require "tmpdir"

module CLITestHelpers
  # A LaunchMode whose automatic choice is fixed, so specs never depend on the
  # machine (platform, osascript, CI) or on a real ~/.config.
  def self.launch_mode(headless:, global: {})
    settings = FakeProjectSettings.new
    settings.define_singleton_method(:load_global) { global }
    Workspace::LaunchMode.new(project_settings: settings, platform: headless ? "x86_64-linux" : "arm64-darwin",
      env: {}, which: ->(_exe) { true })
  end

  class FakeEventLog
    attr_reader :events

    def initialize
      @events = []
    end

    def append(type:, project:, data: {})
      @events << {"type" => type, "project" => project, "data" => data}
    end

    # Like EventLog#record: the write is reported, never raised.
    def record(type:, project:, data: {})
      append(type: type, project: project, data: data)
      true
    end

    def reconstruct
      state = {}
      @events.each do |event|
        case event["type"]
        when "state_set", "launched", "window_discovered", "repaired", "migrated", "compacted"
          state[event["project"]] ||= {}
          state[event["project"]].merge!(event["data"]) if event["data"]
        when "state_removed", "killed", "stopped", "pruned"
          state.delete(event["project"])
        end
      end
      state
    end

    def exists? = false
    def size = 0
    def warn_if_large = nil
    def compact = reconstruct
  end

  # A real EventLog whose file can't be written (its directory is a regular
  # file), to prove an emitter never fails the command that calls it.
  def self.unwritable_event_log(dir, error_output: StringIO.new)
    blocker = File.join(dir, "not-a-directory")
    File.write(blocker, "")
    config = Workspace::Config.new(workspace_dir: dir)
    config.define_singleton_method(:event_log_file) { File.join(blocker, "events.jsonl") }
    Workspace::EventLog.new(config: config, error_output: error_output)
  end

  class FakeState
    def initialize
      @data = {}
    end

    def event_log
      @event_log ||= FakeEventLog.new
    end

    def load
      self
    end

    def save
    end

    def [](key)
      @data[key]
    end

    def []=(key, value)
      @data[key] = value
    end

    def delete(key)
      @data.delete(key)
    end

    def keys
      @data.keys
    end

    def empty?
      @data.empty?
    end

    def each(&block)
      @data.each(&block)
    end

    def dig(*keys)
      @data.dig(*keys)
    end

    def to_h
      @data.dup
    end

    def prune(live_ids)
      pruned = []
      @data.each_key do |project|
        wid = @data[project]["iterm_window_id"]
        unless wid && live_ids.include?(wid.to_i)
          pruned << project
        end
      end
      pruned.each { |p| @data.delete(p) }
      pruned
    end
  end

  class FakeITerm
    def session_map = {}
    def find_existing_sessions(_state, **_opts) = {}
    def find_launcher_window_id(_state, **_opts) = nil
    def create_launcher_panes(_projects, _commands, **_opts) = {}
    def relaunch_in_session(_uid, _cmd) = "ok"
  end

  class FakeWindowManager
    def window_exists?(_wid) = false
    def find_window_by_title(_title) = nil
    def find_window_for_project(_project) = nil
    def iterm_windows = {}
    def focus_by_id(_wid, highlight: nil) = true
    def shake_by_id(_wid) = true
    def live_window_ids = Set.new
    def set_window_bounds(_wid, _x, _y, _w, _h) = nil
    def all_window_bounds(_wids) = {}
    def close_window(_wid) = nil
  end

  class FakeTmux
    def sessions = []
    def start_server = nil
    def kill_session(_name) = nil
    def custom_socket_option(_config_name) = nil
    def rename_window(_session, _index, _name) = nil
    def resize_pane(_session, _pane, _size) = true
    def capture_layout(_session, **_opts) = "layout-string"
    def apply_layout(_session, _layout, **_opts) = true

    attr_reader :sent_keys, :sent_key_names
    attr_accessor :captured_output, :pane_indexes, :delivery_status

    def initialize
      @sent_keys = []
      @sent_key_names = []
      @captured_output = ""
      @pane_indexes = [0, 1, 2]
      @delivery_status = :submitted
    end

    def send_key(session, pane, key_name)
      sent_key_names << {session: session, pane: pane, key: key_name}
      true
    end

    def capture_pane(_session, _pane, **_opts)
      @captured_output
    end

    def send_keys(session, pane, text, enter: true)
      deliver(session, pane, text, enter: enter).ok?
    end

    # Records the send; the outcome is whatever delivery_status says.
    def deliver(session, pane, text, enter: true)
      sent_keys << {session: session, pane: pane, text: text, enter: enter}
      Workspace::Tmux::Delivery.new(status: delivery_status, message: "fake #{delivery_status}")
    end

    def panes(_session, **_opts)
      @pane_indexes
    end

    def find_pane_by_title(_session, _pattern, **_opts)
      nil
    end

    def find_claude_pane(_session, **_opts)
      1
    end

    def split_window(_session, **_opts)
      3
    end

    def command_for(_project, **_opts)
      "tmuxinator start test --attach"
    end

    def session_name_for(config)
      config
    end

    def reattach_or_start(session, start)
      "tmux -CC attach -t #{session} || tmux has-session -t #{session} 2>/dev/null || #{start}"
    end
  end

  # A tmux server with named sessions and panes, answering the way real tmux
  # does: `pane_details(session, window: nil)` lists the whole session, a pane
  # id that doesn't exist makes `session_name_for_pane` return nil, and a
  # delivery or key to a pane that isn't there fails.
  class FakeTmuxServer
    attr_reader :deliveries, :keys_sent, :selected
    attr_accessor :delivery_status, :select_ok, :server_pid

    # @param sessions [Hash{String=>Array<Hash>}] session name to panes (`:id`, `:window`, `:index`)
    def initialize(sessions)
      @sessions = sessions
      @deliveries = []
      @keys_sent = []
      @selected = []
      @delivery_status = :submitted
      @select_ok = true
      @server_pid = "4242"
    end

    def session_name_for(project) = project

    def sessions = @sessions.keys

    def pane_details(session, window: "0")
      panes = @sessions.fetch(session, [])
      panes = panes.select { |p| p[:window] == window.to_i } unless window.nil?
      panes.map { |p| {pid: 1, command: "zsh", cwd: "/", title: ""}.merge(p) }
    end

    def session_name_for_pane(pane_id)
      @sessions.find { |_, panes| panes.any? { |p| p[:id] == pane_id } }&.first
    end

    def deliver(session, pane, text, enter: true)
      return Workspace::Tmux::Delivery.new(status: :failed, message: "can't find pane: #{pane}") unless pane_at?(session, pane)
      @deliveries << {session: session, pane: pane, text: text, enter: enter}
      Workspace::Tmux::Delivery.new(status: @delivery_status, message: "fake #{@delivery_status}")
    end

    def send_key(session, pane, key)
      return false unless pane_at?(session, pane)
      @keys_sent << {session: session, pane: pane, key: key}
      true
    end

    def server_pid_for_pane(pane_id)
      session_name_for_pane(pane_id) && @server_pid
    end

    def select_pane(session, detail)
      @selected << {session: session, id: detail[:id], window: detail[:window]}
      @select_ok
    end

    private

    # A pane id is a target on its own, anywhere on the server; anything else is looked up in the session.
    def pane_at?(session, pane)
      return @sessions.values.flatten.any? { |p| p[:id] == pane } if pane.start_with?("%")
      window, index = pane.split(".").map(&:to_i)
      @sessions.fetch(session, []).any? { |p| p[:window] == window && p[:index] == index }
    end
  end

  class FakeProjectConfig
    def initialize(roots = {})
      @roots = roots
    end

    def resolve_project_arg(arg)
      [arg, nil]
    end

    def create(name, _root)
      name
    end

    def create_worktree(_pn, _wn, _wp, _bn)
      "test-config"
    end

    def config_path_for(name)
      "~/.config/tmuxinator/workspace.#{name}.yml"
    end

    def exists?(_name)
      true
    end

    def available_projects
      ["project-a", "project-b"]
    end

    def project_root_for(name)
      @roots[name]
    end
  end

  class FakeWindowLayout
    def arrange(_ids, quiet: false) = nil
    def tile(_ids) = nil
    def calculate_positions(**_opts) = []
  end

  class FakeDoctor
    attr_reader :headless, :fix

    def run(headless: nil, fix: false)
      @headless = headless
      @fix = fix
    end
  end

  class FakeProjectSettings
    def load(_project_name) = {}
    def save(_project_name, _data) = nil
    def load_global = {}
    def ensure_exists(_project_name) = nil
    def hook_for(_project_name, _event) = nil
    def layouts_for(_project_name) = {}
    def remove(_project_name) = nil
    def project_config_path(name) = "/tmp/workspace/projects/#{name}.yml"
    def global_config_path = "/tmp/workspace/config.yml"

    def with_global_lock
      @global ||= {}
      @global = yield(@global)
    end
  end

  class FakeClaudeCommand
    def deactivate(_projects) = {}
    def reactivate(_projects) = {}
  end

  class FakeRepairCommand
    def call = []
    def set_window_id(_project, _wid) = nil
  end

  class FakeUpdatePaneCommand
    def call(project:, command:, pane_index:) = nil
  end

  class FakeRunCommand
    attr_reader :calls

    def initialize
      @error = nil
      @calls = []
    end

    def raise_on_call(error)
      @error = error
    end

    def call(project, command, **opts)
      @calls << {project: project, command: command, **opts}
      raise @error if @error
    end
  end

  class FakeRunAndReportCommand
    attr_reader :calls

    def initialize
      @calls = []
      @next_result = nil
    end

    def stub_result(result)
      @next_result = result
    end

    def call(command, project: nil, dir: nil)
      @calls << {command: command, project: project, dir: dir}
      @next_result || Workspace::RunResult.new(
        uuid: "fake-uuid", project: project, command: command,
        status: 0, stdout: "", stderr: "",
        started_at: "2024-01-01T00:00:00Z", finished_at: "2024-01-01T00:00:01Z"
      )
    end
  end

  class FakeCaptureCommand
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(project, pane: :bottom, lines: 100, all: false)
      @calls << {project: project, pane: pane, lines: lines, all: all}
    end
  end

  class FakeWaitUntilContentCommand
    attr_reader :calls
    attr_accessor :next_status

    def initialize
      @calls = []
      @next_status = 0
    end

    def call(project, content, **opts)
      @calls << {project: project, content: content, **opts}
      @next_status
    end
  end

  class FakeRunResultStore
    attr_reader :written

    def initialize
      @written = []
      @results = {}
    end

    def ensure_dir = nil

    def write(result)
      @written << result
      @results[result.uuid] = result
    end

    def read(uuid)
      @results[uuid]
    end

    def exist?(uuid)
      @results.key?(uuid)
    end

    def read_stdout(_uuid) = ""

    def read_stderr(_uuid) = ""

    def wait(uuid, timeout: 300, poll_interval: 0.1)
      @results[uuid] || raise(Workspace::Error, "Timed out waiting for run #{uuid}")
    end
  end

  class FakeAgentCommand
    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = true
    end

    def call(name:, wc_socket: nil, force: false)
      @calls << {name: name, wc_socket: wc_socket}
      @result
    end
  end

  class FakeLockCommand
    attr_reader :calls, :working_dirs
    attr_accessor :result

    def initialize
      @calls = []
      @working_dirs = []
      @result = {exit_code: 0}
    end

    def acquire(name, task: nil, wait: false, poll: nil, max_wait: nil, working_dir: nil)
      @working_dirs << working_dir
      @calls << {action: :acquire, name: name, task: task, wait: wait, poll: poll, max_wait: max_wait}
      @result
    end

    def release(name, all: false, working_dir: nil)
      @working_dirs << working_dir
      @calls << {action: :release, name: name, all: all}
      @result
    end

    def status(name = nil, working_dir: nil, json: false)
      @working_dirs << working_dir
      @calls << {action: :status, name: name, json: json}
      @result
    end

    def clear(name, all: false, working_dir: nil, json: false)
      @working_dirs << working_dir
      @calls << {action: :clear, name: name, all: all, json: json}
      @result
    end

    def instructions(name = "edit")
      @calls << {action: :instructions, name: name}
      @result
    end
  end

  class FakeDevCommand
    attr_reader :calls, :working_dirs
    attr_accessor :result

    def initialize
      @calls = []
      @working_dirs = []
      @result = {exit_code: 0}
    end

    def up(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :up, **opts.except(:working_dir)}
      @result
    end

    def down(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :down, **opts.except(:working_dir)}
      @result
    end

    def status(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :status, **opts.except(:working_dir)}
      @result
    end

    def run(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :run, **opts.except(:working_dir)}
      @result
    end
  end

  class FakeProjectsCommand
    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = {exit_code: 0}
    end

    def list(running_only: false, json: false, git: false)
      @calls << {running_only: running_only, json: json, git: git}
      @result
    end

    def show(name: nil, json: false, agents: true, git: true, timeout: nil)
      @calls << {show: name, json: json, agents: agents, git: git, timeout: timeout}
      @result
    end

    def members(name: nil, path: false, all: false, json: false, timeout: nil)
      @calls << {members: name, path: path, all: all, json: json, timeout: timeout}
      @result
    end
  end

  class FakeSnapshotCommand
    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = {exit_code: 0}
    end

    def call(names: [], pr: false)
      @calls << {names: names, pr: pr}
      @result
    end
  end

  class FakeDaemonCommand
    attr_reader :calls
    attr_accessor :result, :restart_result, :error

    def initialize
      @calls = []
      @result = {exit_code: 0}
      @restart_result = Workspace::Commands::Daemon::Result.new("restarted", 11, 22)
    end

    def status(name:, json: false)
      @calls << {status: name, json: json}
      raise @error if @error
      @result
    end

    def log(name:, lines: nil, json: false)
      @calls << {log: name, lines: lines, json: json}
      raise @error if @error
      @result
    end

    def restart(name:, wc_socket: nil)
      @calls << {restart: name, wc_socket: wc_socket}
      @restart_result
    end
  end

  class FakeUiCommand
    attr_reader :calls
    attr_accessor :result, :error

    def initialize
      @calls = []
      @result = Workspace::Commands::Ui::Result.new("opened", "task", "workspace-ui://task/app")
    end

    def open(view:, workspace: nil, print_only: false)
      @calls << {view: view, workspace: workspace, print_only: print_only}
      raise @error if @error
      @result
    end
  end

  class FakeReviewCommand
    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = {exit_code: 0}
    end

    def show(name:, json: false)
      @calls << {show: name, json: json}
      @result
    end

    def list(project: nil, json: false)
      @calls << {list: project, json: json}
      @result
    end
  end

  class FakeProjectActionsCommand
    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = {exit_code: 0}
    end

    def stop(name: nil, dry_run: false, json: false)
      @calls << {stop: name, dry_run: dry_run, json: json}
      @result
    end

    def kill(name:, dry_run: false, yes: false, force: false, discard_unsaved: false, json: false, git_timeout: nil)
      @calls << {kill: name, dry_run: dry_run, yes: yes, force: force, discard_unsaved: discard_unsaved, json: json, git_timeout: git_timeout}
      @result
    end
  end

  class FakeParentCommand
    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = nil
    end

    def call(name = nil, path: false, json: false)
      @calls << {name: name, path: path, json: json}
      @result
    end
  end

  class FakeCapabilitiesCommand
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(json: false)
      @calls << {json: json}
    end
  end

  class FakeAskCommand
    attr_reader :calls

    def initialize(result: {exit_code: 0})
      @calls = []
      @result = result
    end

    def call(question: nil, default: nil, context: nil, working_dir: Dir.pwd, json: false)
      @calls << {action: :call, question: question, default: default, context: context, working_dir: working_dir, json: json}
      @result
    end

    def list(working_dir: Dir.pwd, json: false)
      @calls << {action: :list, working_dir: working_dir, json: json}
      @result
    end

    def answer(id, answer, working_dir: Dir.pwd, json: false, deliver: false)
      @calls << {action: :answer, id: id, answer: answer, working_dir: working_dir, json: json, deliver: deliver}
      @result
    end
  end

  class FakeConfigCommand
    attr_reader :calls

    def initialize(get_returns: true)
      @calls = []
      @get_returns = get_returns
    end

    def set(key, value, project: nil, cwd: Dir.pwd)
      @calls << {action: :set, key: key, value: value, project: project, cwd: cwd}
    end

    def get(key, project: nil, cwd: Dir.pwd)
      @calls << {action: :get, key: key, project: project, cwd: cwd}
      @get_returns
    end

    def unset(key, project: nil, cwd: Dir.pwd)
      @calls << {action: :unset, key: key, project: project, cwd: cwd}
    end
  end

  class FakeStatuslineCommand
    attr_reader :calls

    def initialize(result: {exit_code: 0})
      @calls = []
      @result = result
    end

    def call
      @calls << {action: :call}
      @result
    end
  end

  class FakeHookRunner
    attr_reader :runs

    def initialize
      @runs = []
    end

    def run(project, event, env: {})
      @runs << {project: project, event: event, env: env}
      true
    end
  end
end
