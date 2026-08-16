require "socket"
require "json"
require "fileutils"

# In-process stand-in for the work-coordinator. Listens on real Unix sockets so
# specs exercise the same wire protocol the production client speaks.
class FakeWorkCoordinator
  attr_reader :registrations, :deregistrations, :status_messages
  attr_accessor :reply

  def initialize(socket_path:, status_socket_path: nil, reply: {"ok" => true, "epoch" => "test-wc-epoch"})
    @socket_path = socket_path
    @status_socket_path = status_socket_path
    @reply = reply
    @registrations = []
    @deregistrations = []
    @status_messages = []
    @threads = []
    @servers = []
    @mutex = Mutex.new
  end

  def start
    @servers << listen(@socket_path) { |message| record_main(message) }
    @servers << listen(@status_socket_path) { |message| record_status(message) } if @status_socket_path
    self
  end

  def stop
    @servers.each { |server| server.close unless server.closed? }
    @threads.each { |thread| thread.join(1) }
    @threads.clear
    @servers.clear
    [@socket_path, @status_socket_path].compact.each do |path|
      FileUtils.rm_f(path)
    end
  end

  def last_registration
    @registrations.last
  end

  private

  def listen(path)
    FileUtils.rm_f(path)
    server = UNIXServer.new(path)
    @threads << Thread.new do
      loop do
        client = server.accept
        line = client.gets
        if line
          message = JSON.parse(line)
          @mutex.synchronize { yield message }
          client.puts(@reply.to_json)
        end
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end
    server
  end

  def record_main(message)
    case message["type"]
    when "register" then @registrations << message
    when "deregister" then @deregistrations << message
    end
  end

  def record_status(message)
    @status_messages << message
  end
end
