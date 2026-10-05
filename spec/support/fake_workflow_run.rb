# The pane side of a run, as WorkflowPanes behaves: one binding per pane,
# a bind that raises for a pane that is not the workspace's (`bind_error`),
# a binding that goes stale when its pane is no longer where it was bound
# (`stale`), and a kick that types nothing when it reports a failure.
class FakeWorkflowPanes
  attr_reader :kicks, :bound, :stale, :idle
  attr_accessor :kick_result, :bind_error, :daemon

  def initialize
    @bound = {}
    @kicks = []
    @kick_result = {ok: true}
    @stale = []
    @idle = []
    @daemon = true
  end

  def run_on(pane)
    run_id = @bound[pane]&.fetch(:run_id)
    @stale.include?(run_id) ? nil : run_id
  end

  def pane_of(run_id) = @bound.find { |_, entry| entry[:run_id] == run_id }&.first

  def alive?(run_id) = !pane_of(run_id).nil? && !@stale.include?(run_id)

  def idle?(_workspace, pane) = @idle.include?(pane)

  def daemon_running?(_workspace) = @daemon

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
    {"packs" => [{"ref" => "play/binding"}] + args[:step]["include"].map { |name| {"ref" => "play/#{name}"} }, "text" => "#{text}\n"}
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
