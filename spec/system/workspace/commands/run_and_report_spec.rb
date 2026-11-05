require "tmpdir"

RSpec.describe Workspace::Commands::RunAndReport do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config) }
  let(:run_result_store) { Workspace::RunResultStore.new(config: config) }

  subject(:command) { described_class.new(run_result_store: run_result_store) }

  before do
    allow(config).to receive(:run_results_dir).and_return(tmpdir)
    allow(config).to receive(:run_result_path) { |uuid| File.join(tmpdir, "#{uuid}.json") }
    allow(config).to receive(:run_stdout_path) { |uuid| File.join(tmpdir, "#{uuid}.stdout") }
    allow(config).to receive(:run_stderr_path) { |uuid| File.join(tmpdir, "#{uuid}.stderr") }
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#call" do
    it "captures stdout" do
      result = command.call("echo hello")
      expect(result.stdout.strip).to eq("hello")
      expect(result.status).to eq(0)
    end

    it "captures stderr" do
      result = command.call("echo oops >&2")
      expect(result.stderr.strip).to eq("oops")
    end

    it "captures non-zero exit code" do
      result = command.call("exit 42")
      expect(result.status).to eq(42)
    end

    it "generates a unique UUID for each call" do
      r1 = command.call("echo a")
      r2 = command.call("echo b")
      expect(r1.uuid).not_to eq(r2.uuid)
    end

    it "persists the result to disk" do
      result = command.call("echo stored")
      expect(run_result_store.exist?(result.uuid)).to be true
    end

    it "records started_at and finished_at" do
      result = command.call("echo t")
      expect(result.started_at).not_to be_nil
      expect(result.finished_at).not_to be_nil
    end

    it "attaches the project label when given" do
      result = command.call("echo x", project: "myjob")
      expect(result.project).to eq("myjob")
    end

    it "runs in the specified dir when dir: is given" do
      Dir.mktmpdir do |dir|
        result = command.call("pwd", dir: dir)
        expect(result.stdout.strip).to start_with(File.realpath(dir))
      end
    end

    it "raises Workspace::Error when dir: does not exist" do
      expect {
        command.call("pwd", dir: File.join(tmpdir, "no-such-dir"))
      }.to raise_error(Workspace::Error, /directory does not exist/)
    end

    it "reports 128 + signal number when the process is killed by a signal" do
      status = instance_double(Process::Status, exitstatus: nil, termsig: 9)
      allow(Open3).to receive(:capture3).and_return(["", "", status])

      result = command.call("sleep 100")

      expect(result.status).to eq(137)
    end
  end
end
