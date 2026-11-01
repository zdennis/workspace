# The pane side of a run, as WorkflowPanes behaves: one binding per pane,
# a bind that raises for a pane that is not the workspace's (`bind_error`),
# a binding that goes stale when its pane is no longer where it was bound
# (`stale`), and a kick that types nothing when it reports a failure.
class FakeWorkflowPanes
  attr_reader :changed, :kicks, :bound, :stale, :idle, :turn_over, :gone, :agents_gone, :rows, :respawns
  attr_accessor :kick_result, :bind_error, :daemon, :respawn_result, :on_row, :session

  def initialize
    @bound = {}
    @kicks = []
    @kick_result = {ok: true}
    @stale = []
    @idle = []
    @turn_over = []
    @gone = []
    @changed = []
    @agents_gone = []
    @daemon = true
    @rows = {}
    @session = true
    @respawns = []
    @respawn_result = {ok: true}
  end

  def run_on(pane)
    run_id = @bound[pane]&.fetch(:run_id)
    @stale.include?(run_id) ? nil : run_id
  end

  def pane_of(run_id) = @bound.find { |_, entry| entry[:run_id] == run_id }&.first

  def alive?(run_id) = !pane_of(run_id).nil? && !@stale.include?(run_id)

  def idle?(_workspace, pane) = @idle.include?(pane)

  def main_turn_over?(_workspace, pane) = @turn_over.include?(pane)

  def locate(_workspace, pane) = pane

  def parkable?(_workspace, _pane) = true

  def pane_gone?(pane) = @gone.include?(pane)

  def agent_gone?(_workspace, pane) = @agents_gone.include?(pane)

  def daemon_running?(_workspace) = @daemon

  # The pane's entry in the daemon's snapshot; +on_row+ runs first, for a spec that changes the run in between.
  def pane_row(_workspace, pane)
    @on_row&.call
    @rows[pane]
  end

  def session_live?(_workspace) = @session

  def respawn_daemon(workspace)
    @respawns << workspace
    @daemon = true if @respawn_result[:ok]
    @respawn_result
  end

  def identity(run_id) = pane_of(run_id) ? {"session" => "app", "pane_slot" => "app:0.1"} : nil

  # A pane in +changed+ is a reused id: tmux has it, in another session.
  def same_pane?(pane, identity) = !identity.nil? && !@gone.include?(pane) && !@changed.include?(pane)

  def bind(workspace:, pane:, **fields)
    raise @bind_error if @bind_error
    @bound[pane] = fields.merge(workspace: workspace)
  end

  def unbind(run_id)
    @bound.delete(pane_of(run_id))
  end

  def kick(**args)
    @kicks << args
    @kick_result
  end
end

# Composes the way InstructionComposer does for a step: one text, the packs it read.
class FakeStepComposer
  attr_reader :calls

  def initialize
    @calls = []
  end

  def compose(**args)
    @calls << args
    raise Workspace::Error.new("No library entry named ghost.", code: "unknown_library_entry") if args[:step]["include"].include?("ghost")
    text = [args[:workflow]["text"], args[:step]["text"], *args[:attempt]].compact.join("\n\n")
    {"packs" => [{"ref" => "play/binding", "sha256" => "b" * 64}] + args[:step]["include"].map { |name| {"ref" => "play/#{name}", "sha256" => Digest::SHA256.hexdigest(name)} }, "text" => "#{text}\n"}
  end
end

# A run is alive while its run file says so; every pid is alive.
class RunFileLiveness
  def initialize(dir) = @runs = Workspace::RunLiveness.new(dir: dir)

  def alive?(pid:, started:) = true

  def start_time(pid = Process.pid) = "start-#{pid}"

  def run_alive?(run_id) = @runs.alive?(run_id)
end

# The daemon's side of one connection: reads a line, answers with the next reply.
class FakeDaemonSocket
  attr_reader :sent

  def initialize(reply)
    @reply = reply
    @sent = []
  end

  def puts(line) = @sent << JSON.parse(line)

  # A reply of :silent is a daemon that took the request and never answers.
  def wait_readable(_timeout) = (@reply == :silent) ? nil : self

  def gets = @reply

  def close = nil
end
