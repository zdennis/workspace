require "tmpdir"

RSpec.describe Workspace::RunResultStore do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config) }

  subject(:store) { described_class.new(config: config) }

  before do
    allow(config).to receive(:run_results_dir).and_return(tmpdir)
    allow(config).to receive(:run_result_path) { |uuid| File.join(tmpdir, "#{uuid}.json") }
    allow(config).to receive(:run_stdout_path) { |uuid| File.join(tmpdir, "#{uuid}.stdout") }
    allow(config).to receive(:run_stderr_path) { |uuid| File.join(tmpdir, "#{uuid}.stderr") }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def build_result(uuid: "test-uuid", status: 0, stdout: "out\n", stderr: "")
    Workspace::RunResult.new(
      uuid: uuid, project: "proj", command: "echo hi",
      status: status, stdout: stdout, stderr: stderr,
      started_at: "2024-01-01T00:00:00Z", finished_at: "2024-01-01T00:00:01Z"
    )
  end

  describe "#write and #read" do
    it "persists and retrieves a RunResult" do
      store.write(build_result)
      read_back = store.read("test-uuid")

      expect(read_back).not_to be_nil
      expect(read_back.uuid).to eq("test-uuid")
      expect(read_back.status).to eq(0)
      expect(read_back.stdout).to eq("out\n")
    end

    it "uses tmp-then-rename (no .tmp file left behind)" do
      store.write(build_result)
      expect(Dir[File.join(tmpdir, "*.tmp")]).to be_empty
    end
  end

  describe "#exist?" do
    it "returns false before write" do
      expect(store.exist?("missing")).to be false
    end

    it "returns true after write" do
      store.write(build_result)
      expect(store.exist?("test-uuid")).to be true
    end
  end

  describe "#read" do
    it "returns nil when file does not exist" do
      expect(store.read("no-such-uuid")).to be_nil
    end
  end

  describe "#read_stdout / #read_stderr" do
    it "returns empty string when side-car files do not exist" do
      expect(store.read_stdout("x")).to eq("")
      expect(store.read_stderr("x")).to eq("")
    end

    it "returns file contents when side-car files exist" do
      File.write(File.join(tmpdir, "x.stdout"), "hello\n")
      File.write(File.join(tmpdir, "x.stderr"), "warn\n")

      expect(store.read_stdout("x")).to eq("hello\n")
      expect(store.read_stderr("x")).to eq("warn\n")
    end
  end

  describe "#wait" do
    it "returns the result when the file already exists" do
      store.write(build_result(uuid: "ready"))
      result = store.wait("ready", poll_interval: 0.01)
      expect(result.uuid).to eq("ready")
    end

    it "polls until the file appears" do
      uuid = "delayed"
      thread = Thread.new do
        sleep 0.05
        store.write(build_result(uuid: uuid))
      end

      result = store.wait(uuid, timeout: 5, poll_interval: 0.01)
      thread.join

      expect(result.uuid).to eq(uuid)
    end

    it "raises Workspace::Error when timeout is exceeded" do
      expect {
        store.wait("never", timeout: 0.05, poll_interval: 0.01)
      }.to raise_error(Workspace::Error, /Timed out/)
    end

    it "mentions the PATH requirement in the timeout message" do
      expect {
        store.wait("never", timeout: 0.05, poll_interval: 0.01)
      }.to raise_error(Workspace::Error, /on PATH in the tmux pane/)
    end

    it "raises Workspace::Error when the result file disappears before it is read" do
      allow(store).to receive(:exist?).with("vanishing").and_return(true)
      allow(store).to receive(:read).with("vanishing").and_return(nil)

      expect {
        store.wait("vanishing", poll_interval: 0.01)
      }.to raise_error(Workspace::Error, /disappeared/)
    end
  end

  describe "#ensure_dir" do
    it "creates the directory when absent" do
      new_dir = File.join(tmpdir, "nested", "runs")
      allow(config).to receive(:run_results_dir).and_return(new_dir)
      store.ensure_dir
      expect(File.directory?(new_dir)).to be true
    end
  end
end
