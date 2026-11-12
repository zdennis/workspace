require "stringio"
require "tmpdir"

module CLITestHelpers
  # The named overrides only Workspace.build_cli takes.
  BUILD_CLI_OVERRIDES = %i[launchctl tmux task_store skill_source workflow_source_runner osascript ui_osascript].freeze
  # The keywords Workspace.build_cli and Workspace::CLI.new both take.
  STREAM_KEYWORDS = %i[output error_output input env logger exit_handler].freeze
  # The commands .cli_parts gives the CLI::Agent family instead of Workspace::CLI.new.
  AGENT_FAMILY_KEYWORDS = %i[agent_command ensure_agent_command daemon_command sessions_command review_command agent_status_command agent_executables_command].freeze

  # The one way a spec builds a CLI, so a change to the CLI's keywords touches this builder and
  # not every spec. Given only the streams and Workspace.build_cli's named overrides
  # (osascript:, ui_osascript:, workflow_source_runner:, tmux:, ...), it builds the production
  # graph through Workspace.build_cli, forwarding each. Given any other keyword (+lineage:+, a
  # command, ...), it builds Workspace::CLI.new from the keywords given, with the parts
  # build_cli would make from them (see .cli_parts). A Workspace.build_cli override beside a
  # Workspace::CLI.new keyword is an ArgumentError, since one of them would be dropped.
  def self.build_cli(**keywords)
    return Workspace.build_cli(**keywords) if (keywords.keys - STREAM_KEYWORDS - BUILD_CLI_OVERRIDES).empty?

    overrides = keywords.keys & BUILD_CLI_OVERRIDES
    raise ArgumentError, "Workspace::CLI.new does not take #{overrides.join(", ")}" if overrides.any?

    cli = nil
    cli = Workspace::CLI.new(**cli_parts(agent_run: ->(args, _invocation) { cli.agent_run_prompt(args) }, **keywords))
  end

  # The keywords given, as Workspace::CLI.new takes them: +lineage:+ goes to the CLI::Names it
  # builds, +workflow_command:+ and +workflow_project:+ to the CLI::Workflow family, and the agent
  # family's commands (AGENT_FAMILY_KEYWORDS) and +agent_run:+ to CLI::Agent, as build_cli wires
  # them; CLI::Common and CLI::Launcher are built over the same keywords.
  def self.cli_parts(lineage: nil, workflow_command: nil, workflow_project: nil, agent_run: nil, **keywords)
    agent_commands = AGENT_FAMILY_KEYWORDS.to_h { |key| [key, keywords.delete(key)] }
    keywords[:working_dir] ||= Dir.pwd
    keywords[:launch_mode] ||= Workspace::LaunchMode.new(project_settings: keywords[:project_settings])
    keywords[:input] ||= $stdin
    common = Workspace::CLI::Common.new
    names = Workspace::CLI::Names.new(project_config: keywords[:project_config], project_detector: keywords[:project_detector], lineage: lineage,
      working_dir: keywords[:working_dir], workspace_name: keywords[:workspace_name])
    launcher = Workspace::CLI::Launcher.new(project_config: keywords[:project_config], launch_command: keywords[:launch_command], launch_mode: keywords[:launch_mode],
      state: keywords[:state], project_settings: keywords[:project_settings], hook_runner: keywords[:hook_runner], common: common, working_dir: keywords[:working_dir],
      library: keywords[:library], instruction_composer: keywords[:instruction_composer], name_migration: keywords[:name_migration])
    workflow = Workspace::CLI::Workflow.new(workflow_command: workflow_command, workflow_start_command: keywords[:workflow_start_command], workflow_project: workflow_project,
      status_scope: keywords[:status_scope], config: keywords[:config], project_config: keywords[:project_config], project_detector: keywords[:project_detector],
      git: keywords[:git], launch_mode: keywords[:launch_mode], common: common, names: names, input: keywords[:input], working_dir: keywords[:working_dir])
    agent = Workspace::CLI::Agent.new(**agent_commands, agent_run: agent_run, project_detector: keywords[:project_detector], common: common, names: names,
      working_dir: keywords[:working_dir])
    keywords.merge(common: common, names: names, launcher: launcher, families: {workflow: workflow, agent: agent})
  end

  # A LaunchMode whose automatic choice is fixed, so specs never depend on the
  # machine (platform, osascript, CI) or on a real ~/.config.
  def self.launch_mode(headless:, global: {})
    settings = FakeProjectSettings.new(global: global)
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
    config = UnwritableEventLogConfig.new(File.join(blocker, "events.jsonl"), workspace_dir: dir)
    Workspace::EventLog.new(config: config, error_output: error_output)
  end

  # A Config whose event log file is somewhere unwritable.
  class UnwritableEventLogConfig < Workspace::Config
    attr_reader :event_log_file

    def initialize(event_log_file, **opts)
      super(**opts)
      @event_log_file = event_log_file
    end
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
    def last_call_timed_out? = false
    def applescript_timeout = 5
    def find_existing_sessions(_state, **_opts) = {}
    def find_launcher_window_id(_state, **_opts) = nil
    def create_launcher_panes(_projects, _commands, **_opts) = {}
    def relaunch_in_session(_uid, _cmd) = "ok"
  end

  class FakeWindowManager
    attr_reader :live_window_ids_calls

    def initialize(live_window_ids: Set.new)
      @live_window_ids = live_window_ids
      @live_window_ids_calls = 0
    end

    def window_exists?(_wid) = false
    def find_window_by_title(_title) = nil
    def find_window_for_project(_project) = nil
    def iterm_windows = {}
    def focus_by_id(_wid) = true
    def run_focus_steps(_wid, _steps) = nil
    def highlight_by_id(_wid, _color) = true
    def shake_by_id(_wid) = true

    def live_window_ids
      @live_window_ids_calls += 1
      @live_window_ids
    end

    def window_ids_front_to_back = []
    def set_window_bounds(_wid, _x, _y, _w, _h) = nil
    def all_window_bounds(_wids) = {}
    def close_window(_wid) = nil
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

  # Names one project for every directory (none by default), as WorkspaceLineage#resolve does.
  class FakeLineage
    def initialize(name = nil, is_worktree: false, git_common_dir: :default)
      @name = name
      @is_worktree = is_worktree
      @git_common_dir = git_common_dir
    end

    def resolve(cwd:)
      common = (@git_common_dir == :default) ? (@name && "#{cwd}/.git") : @git_common_dir
      Workspace::WorkspaceLineage::Lineage.new(name: @name, path: cwd, git_common_dir: common, is_worktree: @is_worktree)
    end
  end

  # A catalog with no projects: `find` is always an unknown workspace.
  class FakeStatusCatalog
    def all = []

    def member_at(_project, _path) = nil

    def find(token)
      raise Workspace::Error.new("Unknown project or workspace '#{token}'", code: "unknown_workspace", details: {"name" => token})
    end
  end

  class FakeProjectConfig
    # +resolutions+ maps an argument to the [name, root] it resolves to (default [arg, nil]);
    # +created+ and +root_lookups+ record what was asked.
    attr_reader :resolutions, :created, :root_lookups

    def initialize(roots = {})
      @roots = roots
      @resolutions = {}
      @created = []
      @root_lookups = []
    end

    def resolve_project_arg(arg)
      @resolutions.fetch(arg) { [arg, nil] }
    end

    def create(name, root)
      @created << [name, root]
      name
    end

    def existing_name(name)
      name
    end

    def settle_worktree_name(project, dir, _path)
      "#{project}.worktree-#{dir}"
    end

    def settle_new_name(name, _root)
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
      @root_lookups << name
      @roots[name]
    end
  end

  class FakeWindowLayout
    def arrange(_ids, quiet: false) = nil
    def tile(_ids) = nil
    def calculate_positions(**_opts) = []
  end

  class FakeDoctor
    attr_reader :headless, :fix, :run_count
    attr_writer :result
    attr_accessor :run_error

    def run(headless: nil, fix: false)
      @run_count = run_count.to_i + 1
      @headless = headless
      @fix = fix
      raise @run_error if @run_error
    end

    def report(headless: nil, fix: false)
      @headless = headless
      @fix = fix
      @result || {mode: {"headless" => false, "reason" => "test"}, rows: [], issues: 0}
    end
  end

  class FakeProjectSettings
    # +loader+ answers #load per project name; +global+ is what #load_global returns.
    def initialize(loader: nil, global: {})
      @loader = loader
      @global = global
    end

    def load(project_name) = @loader ? @loader.call(project_name) : {}
    def save(_project_name, _data) = nil
    def load_global = @global
    def ensure_exists(_project_name) = nil
    def hook_for(_project_name, _event) = nil
    def layouts_for(_project_name) = {}
    def remove(_project_name) = nil
    def project_config_path(name) = "/tmp/workspace/projects/#{name}.yml"
    def global_config_path = "/tmp/workspace/config.yml"

    def with_global_lock
      @global = yield(@global)
    end
  end

  class FakeClaudeCommand
    CONTROL_METHODS = [].freeze

    def deactivate(_projects) = {}
    def reactivate(_projects) = {}
  end

  class FakeRepairCommand
    CONTROL_METHODS = [].freeze

    def call = []
    def set_window_id(_project, _wid) = nil
  end

  class FakeUpdatePaneCommand
    CONTROL_METHODS = [].freeze

    def call(project:, command:, pane_index:) = nil
  end

  class FakeRunCommand
    CONTROL_METHODS = %i[calls raise_on_call returning].freeze

    attr_reader :calls

    def initialize
      @error = nil
      @calls = []
    end

    def raise_on_call(error)
      @error = error
    end

    def returning(pane_id)
      @pane_id = pane_id
    end

    def call(project, command, **opts)
      @calls << {project: project, command: command, **opts}
      raise @error if @error
      @pane_id
    end
  end

  class FakeRunAndReportCommand
    CONTROL_METHODS = %i[calls stub_result].freeze

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
    CONTROL_METHODS = %i[calls].freeze

    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(project, pane: :bottom, lines: 100, all: false)
      @calls << {project: project, pane: pane, lines: lines, all: all}
    end
  end

  class FakeWaitUntilContentCommand
    CONTROL_METHODS = %i[calls next_status next_status=].freeze

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
    CONTROL_METHODS = %i[calls result result=].freeze

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

  # Stands in for Commands::EnsureAgent so a Launch built without one never
  # spawns a daemon or waits out its 5s socket timeout.
  class FakeAgentEnsurer
    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = Workspace::Commands::EnsureAgent::Result.new(:started)
    end

    def call(name:, wc_socket: nil)
      @calls << name
      @result
    end
  end

  class FakeLockCommand
    CONTROL_METHODS = %i[calls result result= working_dirs].freeze

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
    CONTROL_METHODS = %i[calls result result= up_error up_error= working_dirs].freeze

    attr_reader :calls, :working_dirs
    attr_accessor :result, :up_error

    def initialize
      @calls = []
      @working_dirs = []
      @result = {exit_code: 0}
    end

    def up(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :up, **opts.except(:working_dir)}
      raise @up_error if @up_error
      @result
    end

    def down(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :down, **opts.except(:working_dir)}
      @result
    end

    def wait(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :wait, **opts.except(:working_dir)}
      @result
    end

    def leave(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :leave, **opts.except(:working_dir)}
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

    def release_for_session(**opts)
      @working_dirs << opts[:working_dir]
      @calls << {action: :release, **opts.except(:working_dir)}
      @result
    end
  end

  class FakeGroupsCommand
    CONTROL_METHODS = %i[calls].freeze

    attr_reader :calls

    def initialize
      @calls = []
    end

    def create(name:, json: false)
      @calls << {create: name, json: json}
      {exit_code: 0}
    end

    def add(group:, path:, json: false)
      @calls << {add: group, path: path, json: json}
      {exit_code: 0}
    end

    def list(json: false)
      @calls << {list: true, json: json}
      {exit_code: 0}
    end

    def show(group:, json: false, agents: true, git: true, timeout: nil)
      @calls << {show: group, json: json, agents: agents, git: git, timeout: timeout}
      {exit_code: 0}
    end
  end

  class FakeProjectsCommand
    CONTROL_METHODS = %i[calls result result=].freeze

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

    def show(name: nil, json: false, agents: true, git: true, timeout: nil, cwd: nil)
      @calls << {show: name, json: json, agents: agents, git: git, timeout: timeout}
      @result
    end

    def members(name: nil, path: false, all: false, json: false, timeout: nil, cwd: nil)
      @calls << {members: name, path: path, all: all, json: json, timeout: timeout}
      @result
    end
  end

  class FakeSnapshotCommand
    CONTROL_METHODS = %i[calls result result=].freeze

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
    CONTROL_METHODS = %i[calls error error= restart_all_results restart_all_results= restart_result restart_result= result result=].freeze

    attr_reader :calls
    attr_accessor :result, :restart_result, :restart_all_results, :error

    def initialize
      @calls = []
      @restart_all_results = []
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
      raise @error if @error
      @restart_result
    end

    def list(json: false)
      @calls << {list: true, json: json}
      raise @error if @error
      @result
    end

    def restart_all
      @calls << {restart_all: true}
      raise @error if @error
      @restart_all_results
    end
  end

  class FakeUiCommand
    CONTROL_METHODS = %i[calls error error= result result= status_doc status_doc=].freeze

    attr_reader :calls
    attr_accessor :result, :error

    def initialize
      @calls = []
      @result = Workspace::Commands::Ui::Result.new("opened", "task", "workspace-ui://task/app")
    end

    attr_accessor :status_doc

    def status
      @calls << {status: true}
      raise @error if @error
      @status_doc ||= {"running" => false, "pids" => [], "handler" => nil,
                       "links" => {"revision" => nil, "reason" => "no_handler"}, "probe" => nil, "warnings" => []}
    end

    def status_lines(_doc)
      ["running: no", "handler: none", "links: no revision (no_handler)"]
    end

    def open(view:, workspace: nil, print_only: false, pane: nil, path: nil)
      @calls << {view: view, workspace: workspace, print_only: print_only}.tap { |call|
        call[:pane] = pane if pane
        call[:path] = path if path
      }
      raise @error if @error
      @result
    end
  end

  class FakeBindingCommand
    CONTROL_METHODS = %i[calls error error=].freeze

    attr_reader :calls
    attr_accessor :error

    def initialize
      @calls = []
    end

    def set(workspace:, pane:, **fields)
      record(:set, {workspace: workspace, pane: pane}.merge(fields))
    end

    def show(pane:)
      record(:show, {pane: pane})
    end

    def clear(pane:)
      record(:clear, {pane: pane})
    end

    private

    def record(name, args)
      @calls << [name, args]
      raise @error if @error
      {"kind" => "run", "id" => "wr_1", "workspace" => "app", "pane_id" => args[:pane]}
    end
  end

  # Records each library verb with its keyword arguments; writes return a
  # Commands::Library::Result like the real command, reads print a line.
  class FakeLibraryCommand
    CONTROL_METHODS = %i[calls error error= result result=].freeze

    attr_reader :calls
    attr_accessor :error, :result

    def initialize
      @calls = []
      @entry = {"kind" => "play", "name" => "kickoff", "ref" => "play/kickoff", "scope" => "global", "project" => nil}
      @result = Workspace::Commands::Library::Result.new("added", nil, @entry, "Added play/kickoff in the global library.")
    end

    def list(**kw) = record(:list, kw)

    def show(ref, **kw) = record(:show, {ref: ref}.merge(kw))

    def info(ref, **kw) = record(:info, {ref: ref}.merge(kw))

    def add(**kw) = record(:add, kw)

    def update(ref, **kw) = record(:update, {ref: ref}.merge(kw))

    def remove(ref, **kw) = record(:remove, {ref: ref}.merge(kw))

    def install(ref, **kw) = record(:install, {ref: ref}.merge(kw))

    def uninstall(ref, **kw) = record(:uninstall, {ref: ref}.merge(kw))

    def installed(**kw) = record(:installed, kw)

    private

    def record(name, args)
      @calls << [name, args]
      raise @error if @error
      @result
    end
  end

  class FakeInstructionsCommand
    CONTROL_METHODS = %i[calls error error=].freeze

    attr_reader :calls
    attr_accessor :error

    def initialize
      @calls = []
    end

    def compose(**kw)
      @calls << [:compose, kw]
      raise @error if @error
    end
  end

  # Records each `workflow`/`step` call; mutations return the row the real command returns.
  class FakeWorkflowCommand
    CONTROL_METHODS = %i[calls error error= row row= status_result status_result=].freeze

    attr_reader :calls
    attr_accessor :error, :row, :status_result

    def initialize
      @calls = []
      @row = {"workspace" => "app", "outcome" => "started", "reason" => nil, "message" => nil, "run" => {"id" => "wr_1", "state" => "running"}}
    end

    %i[show validate render simulate status events files attempts advance step_status].each do |name|
      define_method(name) do |**kw|
        @calls << [name, kw]
        raise @error if @error
        (name == :status) ? @status_result : nil
      end
    end

    def list(json: false, project: nil)
      @calls << [:list, {json: json, project: project}]
      raise @error if @error
    end

    def install(source: nil)
      @calls << [:install, {source: source}]
      raise @error if @error
    end

    # Answers nil when the prompt was declined, like the real uninstall does.
    def uninstall(yes: false, dry_run: false, json: false)
      @calls << [:uninstall, {yes: yes, dry_run: dry_run, json: json}]
      raise @error if @error
      (yes || dry_run) ? @row : nil
    end

    def check(**kw)
      @calls << [:check, kw]
      {exit_code: 0}
    end

    %i[stats compare audit].each do |name|
      define_method(name) do |**kw|
        @calls << [name, kw]
        {exit_code: 0}
      end
    end

    def check_removable(**kw)
      @calls << [:check_removable, kw]
      raise @error if @error
    end

    %i[add update remove run resume cancel approve reject step_done].each do |name|
      define_method(name) do |**kw|
        @calls << [name, kw]
        raise @error if @error
        @row
      end
    end
  end

  # Records each `workflow start` call and answers with a canned row.
  class FakeWorkflowStartCommand
    CONTROL_METHODS = %i[calls error error= row row=].freeze

    attr_reader :calls
    attr_accessor :error, :row

    def initialize
      @calls = []
      @row = {"workspace" => "app.worktree-x", "outcome" => "started", "reason" => nil, "message" => nil}
    end

    def call(**kw)
      @calls << kw
      raise @error if @error
      @row
    end
  end

  # Records each `go` call and answers with a canned row.
  class FakeGoCommand
    CONTROL_METHODS = %i[calls error error= row row=].freeze

    attr_reader :calls
    attr_accessor :error, :row

    def initialize
      @calls = []
      @row = {"workspace" => "app.worktree-x", "outcome" => "started", "decision" => {"workflow" => "rpiv", "route" => "start"}, "warnings" => []}
    end

    def call(**kw)
      @calls << kw
      raise @error if @error
      @row
    end
  end

  class FakeReviewCommand
    CONTROL_METHODS = %i[calls result result=].freeze

    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = {exit_code: 0}
    end

    def show(name:, json: false, **extra)
      @calls << {show: name, json: json}.merge(extra)
      @result
    end

    def list(project: nil, json: false, cwd: nil)
      @calls << {list: project, json: json}
      @result
    end
  end

  class FakeProjectActionsCommand
    CONTROL_METHODS = %i[calls result result=].freeze

    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = {exit_code: 0}
    end

    def stop(name: nil, dry_run: false, json: false, cwd: nil)
      @calls << {stop: name, dry_run: dry_run, json: json}
      @result
    end

    def kill(name:, dry_run: false, yes: false, force: false, discard_unsaved: false, json: false, git_timeout: nil)
      @calls << {kill: name, dry_run: dry_run, yes: yes, force: force, discard_unsaved: discard_unsaved, json: json, git_timeout: git_timeout}
      @result
    end
  end

  class FakeParentCommand
    CONTROL_METHODS = %i[calls result result=].freeze

    attr_reader :calls
    attr_accessor :result

    def initialize
      @calls = []
      @result = nil
    end

    def call(name = nil, path: false, json: false, envelope: false)
      @calls << {name: name, path: path, json: json, envelope: envelope}
      @result
    end
  end

  class FakeCapabilitiesCommand
    CONTROL_METHODS = %i[calls].freeze

    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(json: false)
      @calls << {json: json}
    end
  end

  class FakeAskCommand
    CONTROL_METHODS = %i[calls].freeze

    attr_reader :calls

    def initialize(result: {exit_code: 0})
      @calls = []
      @result = result
    end

    def call(question: nil, default: nil, context: nil, working_dir: Dir.pwd, json: false)
      @calls << {action: :call, question: question, default: default, context: context, working_dir: working_dir, json: json}
      @result
    end

    def list(working_dir: Dir.pwd, json: false, all: false)
      @calls << {action: :list, working_dir: working_dir, json: json, all: all}
      @result
    end

    def deliver(id, pane: nil, working_dir: Dir.pwd, json: false)
      @calls << {action: :deliver, id: id, pane: pane, working_dir: working_dir, json: json}
      @result
    end

    def withdraw(id, working_dir: Dir.pwd, json: false)
      @calls << {action: :withdraw, id: id, working_dir: working_dir, json: json}
      @result
    end

    def answer(id, answer, working_dir: Dir.pwd, json: false, deliver: false)
      @calls << {action: :answer, id: id, answer: answer, working_dir: working_dir, json: json, deliver: deliver}
      @result
    end
  end

  class FakeConfigCommand
    CONTROL_METHODS = %i[calls handlers].freeze

    # +handlers+ maps an action (:set, :unset, :edit) to a callable that answers it instead
    # of the canned result; it gets the same arguments as the action.
    attr_reader :calls, :handlers

    def initialize(get_returns: true)
      @calls = []
      @get_returns = get_returns
      @handlers = {}
    end

    def set(key, value, project: nil, scope: nil, cwd: Dir.pwd)
      @calls << {action: :set, key: key, value: value, project: project, scope: scope, cwd: cwd}
      return @handlers[:set].call(key, value, project: project, scope: scope, cwd: cwd) if @handlers.key?(:set)
      result(key, project, scope)
    end

    def get(key, project: nil, scope: nil, cwd: Dir.pwd)
      @calls << {action: :get, key: key, project: project, scope: scope, cwd: cwd}
      @get_returns
    end

    def unset(key, project: nil, scope: nil, cwd: Dir.pwd)
      @calls << {action: :unset, key: key, project: project, scope: scope, cwd: cwd}
      return @handlers[:unset].call(key, project: project, scope: scope, cwd: cwd) if @handlers.key?(:unset)
      result(key, project, scope)
    end

    def keys(query: nil, settable: false, json: false)
      @calls << {action: :keys, query: query, settable: settable, json: json}
      []
    end

    def edit(project: nil, scope: nil, cwd: Dir.pwd)
      @calls << {action: :edit, project: project, scope: scope, cwd: cwd}
      return @handlers[:edit].call(project: project, scope: scope, cwd: cwd) if @handlers.key?(:edit)
      layer = (scope == "global") ? "global" : "project"
      Workspace::Commands::Config::EditResult.new(workspace: (layer == "global") ? nil : project, layer: layer, scope: layer,
        path: "/cfg/#{project || "config"}.yml", created: true)
    end

    private

    def result(key, project, scope)
      layer = (scope == "global") ? "global" : "project"
      Workspace::Commands::Config::Result.new(key: key, workspace: (layer == "global") ? nil : project, layer: layer, scope: layer,
        path: "/cfg/#{project || "config"}.yml", comments_preserved: true, backup: nil, affects: [])
    end
  end

  class FakeStatuslineCommand
    CONTROL_METHODS = %i[calls].freeze

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

  # Sets the named keys on the real ENV (nil deletes) until the example ends; nothing else is
  # touched. Include it in a group that needs it.
  module EnvStub
    def self.included(group)
      group.after do
        (@saved_env || {}).each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
    end

    def stub_env(vars)
      @saved_env ||= {}
      vars.each do |key, value|
        @saved_env[key] = ENV[key] unless @saved_env.key?(key)
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
  end

  # The workflow family's CLI over fake commands, shared by the workflow CLI specs. Include it
  # in a group that needs it.
  module WorkflowFamilyCli
    # A CLI with only the workflow family's collaborators: the commands no workflow verb reaches are nil.
    def build_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, **overrides)
      state = CLITestHelpers::FakeState.new
      project_config = overrides[:project_config] || CLITestHelpers::FakeProjectConfig.new
      project_detector = overrides[:project_detector] || Workspace::ProjectDetector.new(state: state, project_config: project_config)
      status_scope = Workspace::StatusScope.new(project_detector: project_detector, catalog: overrides[:project_catalog] || CLITestHelpers::FakeStatusCatalog.new)
      unused = %i[launch_command kill_command finish_command start_command stop_command focus_command tile_command layout_command resize_command
        init_command repair_command cleanup_command prune_command claude_command lookup_command update_pane_command run_command run_result_store
        run_and_report_command capture_command wait_until_content_command lock_command dev_command parent_command agent_command sessions_command
        session_event_command config_command statusline_command ask_command].to_h { |key| [key, nil] }

      cli = CLITestHelpers.build_cli(
        config: Workspace::Config.new,
        state: state,
        project_config: project_config,
        git: Workspace::Git.new(output: output, input: input),
        window_manager: CLITestHelpers::FakeWindowManager.new,
        doctor: CLITestHelpers::FakeDoctor.new,
        project_settings: CLITestHelpers::FakeProjectSettings.new,
        hook_runner: CLITestHelpers::FakeHookRunner.new,
        project_detector: project_detector,
        status_scope: status_scope,
        lineage: CLITestHelpers::FakeLineage.new,
        workflow_command: overrides[:workflow_command],
        workflow_start_command: overrides[:workflow_start_command],
        logger: Workspace::Logger.new(output: error_output),
        output: output,
        error_output: error_output,
        exit_handler: FakeExitHandler,
        input: input,
        working_dir: overrides[:working_dir] || Dir.tmpdir,
        sleeper: ->(_) {},
        launch_mode: CLITestHelpers.launch_mode(headless: false),
        env: {},
        **unused
      )
      [cli, output, error_output]
    end
  end

  # The agent family's CLI over fake commands, shared by the agent CLI specs. Include it in a
  # group that needs it.
  module AgentFamilyCli
    # A CLI with only the agent family's collaborators: the commands no agent verb reaches are nil.
    def build_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, **overrides)
      config = overrides[:config] || Workspace::Config.new
      state = CLITestHelpers::FakeState.new
      project_config = overrides[:project_config] || CLITestHelpers::FakeProjectConfig.new
      project_detector = overrides[:project_detector] || Workspace::ProjectDetector.new(state: state, project_config: project_config)
      unused = %i[launch_command kill_command finish_command start_command stop_command focus_command tile_command layout_command resize_command
        init_command repair_command cleanup_command prune_command claude_command lookup_command update_pane_command run_command run_result_store
        run_and_report_command capture_command wait_until_content_command lock_command dev_command parent_command session_event_command
        config_command statusline_command ask_command].to_h { |key| [key, nil] }

      cli = CLITestHelpers.build_cli(
        config: config,
        state: state,
        project_config: project_config,
        git: FakeGit.new,
        window_manager: CLITestHelpers::FakeWindowManager.new,
        doctor: CLITestHelpers::FakeDoctor.new,
        project_settings: CLITestHelpers::FakeProjectSettings.new,
        hook_runner: CLITestHelpers::FakeHookRunner.new,
        project_detector: project_detector,
        workspace_name: overrides[:workspace_name],
        lineage: CLITestHelpers::FakeLineage.new,
        agent_command: overrides[:agent_command] || CLITestHelpers::FakeAgentCommand.new,
        ensure_agent_command: overrides[:ensure_agent_command],
        daemon_command: overrides[:daemon_command],
        sessions_command: overrides[:sessions_command] || Workspace::Commands::Sessions.new(config: config, output: output, error_output: error_output),
        review_command: overrides[:review_command],
        agent_status_command: overrides[:agent_status_command],
        agent_executables_command: overrides[:agent_executables_command],
        logger: Workspace::Logger.new(output: error_output),
        output: output,
        error_output: error_output,
        exit_handler: FakeExitHandler,
        input: input,
        working_dir: overrides[:working_dir] || Dir.tmpdir,
        sleeper: ->(_) {},
        launch_mode: CLITestHelpers.launch_mode(headless: false),
        env: {},
        **unused
      )
      [cli, output, error_output]
    end
  end
end
