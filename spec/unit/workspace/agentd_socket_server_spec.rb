require "spec_helper"
require "socket"
require "tmpdir"

# One accepted connection: the line it sends, and whether it was closed.
class SocketServerSpecConnection
  def initialize(line)
    @line = line
    @closed = false
  end

  def gets = @line

  def close = @closed = true

  def closed? = @closed
end

# A listening server: accept hands out the given connections, then raises IOError as a closed server does.
class SocketServerSpecListener
  attr_reader :path

  def initialize(path, connections = [], on_empty: nil)
    @path = path
    @connections = connections
    @on_empty = on_empty
    @closed = false
  end

  def accept
    return @connections.shift unless @connections.empty?
    @on_empty&.call
    raise IOError, "closed stream"
  end

  def close = @closed = true

  def closed? = @closed
end

RSpec.describe Workspace::AgentdSocketServer do
  # Unix socket paths cap at 104 bytes on macOS, so stay under /tmp directly.
  let(:tmpdir) { Dir.mktmpdir("ws-sock", "/tmp") }
  let(:socket_path) { File.join(tmpdir, "agent.sock") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:log_output) { StringIO.new }
  let(:bound) { [] }
  let(:connections) { [] }

  after { FileUtils.remove_entry(tmpdir) }

  def server(bind: nil, **given)
    bind ||= ->(path) { SocketServerSpecListener.new(path, connections, on_empty: -> { subject_server.shut_down! }).tap { |l| bound << l } }
    @subject_server = described_class.new(bind: bind, logger: Workspace::Logger.new(output: log_output, enabled: true),
      output: output, error_output: error_output, **given)
  end

  attr_reader :subject_server

  describe "#claim" do
    it "claims a path with nothing on it" do
      expect(server.claim("myapp", socket_path)).to be(true)
    end

    it "removes a stale socket no one answers on, and claims the path" do
      UNIXServer.new(socket_path).close

      expect(server.claim("myapp", socket_path)).to be(true)
      expect(File.exist?(socket_path)).to be(false)
    end

    it "refuses a path a running daemon answers on" do
      running = UNIXServer.new(socket_path)

      expect(server.claim("myapp", socket_path)).to be(false)
      expect(error_output.string).to eq("workspace agent 'myapp' is already running\n")
      expect(File.socket?(socket_path)).to be(true)
    ensure
      running&.close
    end
  end

  describe "#listen" do
    it "binds the path through bind and is then listening" do
      subject = server
      expect(subject.listening?).to be(false)

      subject.listen(socket_path)

      expect(bound.map(&:path)).to eq([socket_path])
      expect(subject.listening?).to be(true)
    end
  end

  describe "#serve" do
    it "hands each connection's line to the router, parsed, and closes the connection" do
      connection = SocketServerSpecConnection.new(%({"type":"version","workspace":"myapp"}\n))
      connections << connection
      router = RecordingRouter.new
      subject = server
      subject.listen(socket_path)

      subject.serve(router)

      expect(router.calls).to eq([[:handle, {"type" => "version", "workspace" => "myapp"}, connection]])
      expect(connection).to be_closed
    end

    it "leaves a connection open that the router handed to a worker" do
      connection = SocketServerSpecConnection.new(%({"type":"status_request"}\n))
      connections << connection
      subject = server
      subject.listen(socket_path)

      subject.serve(RecordingRouter.new(answer: :handed_off))

      expect(connection).not_to be_closed
    end

    it "closes a connection that sent nothing, routing nothing" do
      connection = SocketServerSpecConnection.new(nil)
      connections << connection
      router = RecordingRouter.new
      subject = server
      subject.listen(socket_path)

      subject.serve(router)

      expect(router.calls).to be_empty
      expect(connection).to be_closed
    end

    it "answers malformed_message through the router for a line that is not JSON" do
      connection = SocketServerSpecConnection.new("not json\n")
      connections << connection
      router = RecordingRouter.new
      subject = server
      subject.listen(socket_path)

      subject.serve(router)

      expect(router.replies).to eq([[connection, {"ok" => false, "error" => "malformed_message"}]])
      expect(connection).to be_closed
    end

    it "answers internal_error and keeps serving when the router raises" do
      first = SocketServerSpecConnection.new(%({"type":"command"}\n))
      second = SocketServerSpecConnection.new(%({"type":"command"}\n))
      connections.push(first, second)
      router = RecordingRouter.new(fail_with: RuntimeError.new("tmux wedged"))
      subject = server
      subject.listen(socket_path)

      subject.serve(router)

      expect(router.replies).to eq([[first, {"ok" => false, "error" => "internal_error"}], [second, {"ok" => false, "error" => "internal_error"}]])
      expect(error_output.string).to eq("workspace agent: dropped a message: tmux wedged\n" * 2)
    end

    it "goes round on the server a rebind put in place when the old one is closed under the accept" do
      fresh = SocketServerSpecConnection.new(%({"type":"version"}\n))
      listeners = [
        # Swapped out while its accept waits, as the watcher's rebind does: the accept then raises IOError.
        SocketServerSpecListener.new(socket_path, on_empty: -> { subject_server.listen(socket_path) }),
        SocketServerSpecListener.new(socket_path, [fresh], on_empty: -> { subject_server.shut_down! })
      ]
      router = RecordingRouter.new
      subject = server(bind: ->(_path) { listeners.shift })
      subject.listen(socket_path)

      subject.serve(router)

      expect(router.calls).to eq([[:handle, {"type" => "version"}, fresh]])
    end

    it "stops at once once shut down" do
      router = RecordingRouter.new
      subject = server
      subject.listen(socket_path)
      subject.shut_down!

      subject.serve(router)

      expect(router.calls).to be_empty
    end
  end

  describe "#watch" do
    let(:ticks) { Queue.new }

    it "calls on_tick every tick_passes passes and ends once shut down and woken" do
      subject = server(poll_interval: 0.01, tick_passes: 2)
      running = UNIXServer.new(socket_path)

      watcher = subject.watch(socket_path, needs_registration: false, on_tick: -> { ticks << :tick }, re_register: -> { raise "not called" })
      2.times { ticks.pop(timeout: 2) }
      subject.shut_down!
      subject.wake

      expect(watcher.join(2)).to eq(watcher)
    ensure
      running&.close
    end

    it "binds the socket again when its file is gone, closes the old server, and re-registers until that succeeds" do
      answers = [false, true]
      registered = Queue.new
      subject = server(poll_interval: 0.01, tick_passes: 1_000)
      subject.listen(socket_path)
      old = bound.first

      watcher = subject.watch(socket_path, needs_registration: false, on_tick: -> {},
        re_register: -> { answers.shift.tap { |ok| registered << ok } })
      expect([registered.pop(timeout: 2), registered.pop(timeout: 2)]).to eq([false, true])
      subject.shut_down!
      subject.wake
      watcher.join(2)

      expect(old).to be_closed
      expect(bound.size).to be >= 2
      expect(log_output.string).to include("agent socket at #{socket_path} has disappeared; rebinding")
    end

    it "reports a rebind that fails and keeps watching" do
      failures = Queue.new
      subject = server(poll_interval: 0.01, bind: ->(_path) {
        failures << :failed
        raise Errno::EACCES, socket_path
      })

      watcher = subject.watch(socket_path, needs_registration: false, on_tick: -> {}, re_register: -> { true })
      2.times { failures.pop(timeout: 2) }
      subject.shut_down!
      subject.wake
      watcher.join(2)

      expect(error_output.string).to include("workspace agent: could not rebind its socket: Permission denied")
    end
  end

  describe "#close and #close_and_remove" do
    it "closes nothing before it listens" do
      expect { server.close }.not_to raise_error
    end

    it "closes the listening server" do
      subject = server
      subject.listen(socket_path)

      subject.close

      expect(bound.first).to be_closed
    end

    it "closes a server still open and removes the socket file" do
      real = nil
      subject = server(bind: ->(path) { real = UNIXServer.new(path) })
      subject.listen(socket_path)

      subject.close_and_remove(socket_path)

      expect(real).to be_closed
      expect(File.exist?(socket_path)).to be(false)
    end
  end
end
