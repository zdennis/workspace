# Stands in for Workspace::Tmux: "opens a window" by spawning the wrapper
# as its own process group leader, as tmux would.
class FakeDevWindowTmux
  attr_reader :windows

  def initialize(spawner)
    @spawner = spawner
    @windows = []
  end

  def session_name_for_pane(_pane) = "app"

  def session_name_for(name) = name

  def sessions = ["app"]

  def server_running? = true

  # The spawned wrapper runs in no real pane, so there is none to close.
  def close_dead_pane(_pane_id, pid:) = nil

  def new_window(session, name:, cwd:, command:, env: {}, remain_on_exit: false)
    @windows << {session: session, name: name, cwd: cwd, command: command}
    @spawner.call(cwd, command.include?("--wait"), env)
  end
end
