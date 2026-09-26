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

  def new_window(session, name:, cwd:, command:, env: {})
    @windows << {session: session, name: name, cwd: cwd, command: command}
    @spawner.call(cwd, command.include?("--wait"), env)
  end
end
