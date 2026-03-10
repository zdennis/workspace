require "stringio"
require "tmpdir"

module CLITestHelpers
  class FakeEventLog
    attr_reader :events

    def initialize
      @events = []
    end

    def append(type:, project:, data: {})
      @events << {"type" => type, "project" => project, "data" => data}
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
    def rename_window(_session, _index, _name) = nil
    def resize_pane(_session, _pane, _size) = true
    def capture_layout(_session, **_opts) = "layout-string"
    def apply_layout(_session, _layout, **_opts) = true

    def command_for(_project, **_opts)
      "tmuxinator start test --attach"
    end

    def session_name_for(config)
      config
    end
  end

  class FakeProjectConfig
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

    def project_root_for(_name)
      nil
    end
  end

  class FakeWindowLayout
    def arrange(_ids) = nil
    def tile(_ids) = nil
    def calculate_positions(**_opts) = []
  end

  class FakeDoctor
    def run
    end
  end

  class FakeProjectSettings
    def load(_project_name) = {}
    def save(_project_name, _data) = nil
    def load_global = {}
    def ensure_exists(_project_name) = nil
    def hook_for(_project_name, _event) = nil
    def layouts_for(_project_name) = {}
    def project_config_path(name) = "/tmp/workspace/projects/#{name}.yml"
    def global_config_path = "/tmp/workspace/config.yml"
  end

  class FakeRepairCommand
    def call = nil
    def set_window_id(_project, _wid) = nil
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
