require "spec_helper"
require "socket"
require "tmpdir"

RSpec.describe Workspace::AgentSnapshotClient do
  let(:tmpdir) { Dir.mktmpdir }
  let(:socket_path) { File.join(tmpdir, "a.sock") }
  let(:config) { instance_double(Workspace::Config) }
  let(:snapshot) { {"workspace" => "proj", "panes" => [{"pane_id" => "%1", "state" => "idle"}]} }

  subject(:client) { described_class.new(config: config, timeout: 0.5) }

  before { allow(config).to receive(:agent_socket_path).with("proj").and_return(socket_path) }

  after { FileUtils.remove_entry(tmpdir) }

  # Stands in for the daemon: reads the request, then lets the block answer.
  def with_daemon
    server = UNIXServer.new(socket_path)
    received = nil
    listener = Thread.new do
      conn = server.accept
      received = JSON.parse(conn.gets)
      yield conn
    ensure
      conn&.close
    end
    result = yield_client { received }
    listener.join(2)
    result
  ensure
    server&.close
  end

  def yield_client
    outcome = begin
      [:ok, client_call]
    rescue => e
      [:error, e]
    end
    @request = yield
    outcome
  end

  def client_call = client.fetch("proj", timeout: @timeout)

  describe "#fetch" do
    it "sends a sessions request for the workspace and returns the parsed reply" do
      outcome = with_daemon { |conn| conn.puts(JSON.generate(snapshot)) }

      expect(outcome).to eq([:ok, snapshot])
      expect(@request).to eq("type" => "sessions", "workspace" => "proj")
    end

    it "reassembles a reply that arrives in pieces" do
      line = JSON.generate(snapshot)
      outcome = with_daemon do |conn|
        conn.write(line[0, 10])
        conn.flush
        sleep 0.01
        conn.write(line[10..] + "\n")
      end

      expect(outcome).to eq([:ok, snapshot])
    end

    it "accepts a final reply with no trailing newline" do
      outcome = with_daemon { |conn| conn.write(JSON.generate(snapshot)) }

      expect(outcome).to eq([:ok, snapshot])
    end

    it "raises Unavailable (no_daemon) when nothing listens on the socket path" do
      expect { client.fetch("proj") }.to raise_error(described_class::Unavailable, /No agent daemon for 'proj'.*workspace agentd proj/m) { |e|
        expect(e.reason).to eq(:no_daemon)
      }
    end

    it "raises Unavailable (no_daemon) when the socket file exists but refuses connections" do
      File.write(socket_path, "")

      expect { client.fetch("proj") }.to raise_error(described_class::Unavailable) { |e| expect(e.reason).to eq(:no_daemon) }
    end

    it "raises Unavailable (timeout) when the daemon accepts but never replies, within the bound" do
      @timeout = 0.05
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      outcome = with_daemon { |_conn| sleep 0.15 }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(outcome[0]).to eq(:error)
      expect(outcome[1]).to be_a(described_class::Unavailable)
      expect(outcome[1].reason).to eq(:timeout)
      expect(outcome[1].message).to eq("Agent daemon for 'proj' did not answer within 0.05s.")
      expect(elapsed).to be < 0.5
    end

    it "times out on a reply that starts but never finishes" do
      @timeout = 0.05
      outcome = with_daemon do |conn|
        conn.write('{"workspace":')
        conn.flush
        sleep 0.15
      end

      expect(outcome[1]).to be_a(described_class::Unavailable)
      expect(outcome[1].reason).to eq(:timeout)
    end

    it "uses the constructor's timeout when the call gives none" do
      fast = described_class.new(config: config, timeout: 0.03)
      server = UNIXServer.new(socket_path)
      listener = Thread.new do
        conn = server.accept
        conn.gets
        sleep 0.1
        conn.close
      end

      expect { fast.fetch("proj") }.to raise_error(described_class::Unavailable, /within 0.03s/)
      listener.join(2)
      server.close
    end

    it "raises a plain Workspace::Error when the daemon closes without replying" do
      outcome = with_daemon { |_conn| nil }

      expect(outcome[1]).to be_a(Workspace::Error)
      expect(outcome[1]).not_to be_a(described_class::Unavailable)
      expect(outcome[1].message).to eq("Agent for 'proj' closed the connection.")
    end

    it "raises a plain Workspace::Error for a malformed reply" do
      outcome = with_daemon { |conn| conn.puts("not json") }

      expect(outcome[1].message).to eq("Malformed reply from session monitor for 'proj'.")
    end

    it "treats a reply that is not a JSON object as malformed" do
      outcome = with_daemon { |conn| conn.puts("[1,2]") }

      expect(outcome[1].message).to eq("Malformed reply from session monitor for 'proj'.")
    end

    context "with a fake socket and clock" do
      let(:now) { [0.0] }
      let(:clock) { -> { now[0] } }
      let(:fake_socket_class) do
        Class.new do
          attr_reader :written, :closed

          def initialize(clock_now, advance:)
            @now = clock_now
            @advance = advance
            @written = []
            @closed = false
          end

          def puts(line) = @written << line

          def closed? = @closed

          def close = @closed = true

          # Never readable: each wait burns the time it was given.
          def wait_readable(seconds)
            @now[0] += seconds + @advance
            nil
          end
        end
      end

      it "gives up once the deadline passes and still closes the socket" do
        socket = fake_socket_class.new(now, advance: 0)
        fake = described_class.new(config: config, timeout: 2, connector: ->(_path) { socket }, clock: clock)

        expect { fake.fetch("proj") }.to raise_error(described_class::Unavailable, /within 2s/)
        expect(socket.closed).to be(true)
        expect(socket.written.size).to eq(1)
      end

      it "never waits when the deadline has already passed" do
        calls = [0.0, 5.0]
        socket = fake_socket_class.new(now, advance: 0)
        ticking = described_class.new(config: config, timeout: 1, connector: ->(_path) { socket }, clock: -> { calls.shift || 5.0 })

        expect { ticking.fetch("proj") }.to raise_error(described_class::Unavailable) { |e| expect(e.reason).to eq(:timeout) }
      end
    end
  end
end
