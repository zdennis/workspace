require "spec_helper"
require "tmpdir"
require "digest"

RSpec.describe Workspace::WorkflowFiles do
  let(:dir) { Dir.mktmpdir }
  let(:global_dir) { File.join(dir, "home", ".config", "workspace", "workflows") }
  let(:config) { instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: File.join(dir, "builtin")) }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }
  let(:target) { File.join(global_dir, "flow.yml") }
  let(:lock_path) { File.join(global_dir, ".flow.yml.lock") }
  let(:text) { "title: Flow\nsteps:\n  plan:\n    prompt: Plan.\n" }
  subject(:files) { described_class.new(config: config, catalog: catalog) }

  after { FileUtils.remove_entry(dir) }

  # Waits, a bounded time, for +thread+ to be blocked (on the lock); fails rather than hangs.
  def wait_until_blocked(thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until thread.status == "sleep"
      raise "the thread finished without blocking" unless thread.alive?
      raise "the thread never blocked" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
  end

  def joined(thread)
    thread.join(5) || raise("the thread did not finish")
  end

  def strays
    Dir.children(global_dir) - ["flow.yml", ".flow.yml.lock"]
  end

  describe "#add" do
    it "writes the text to ID.yml, making the directory, and answers its path and sha256" do
      expect(files.add("flow", text)).to eq("path" => target, "sha256" => Digest::SHA256.hexdigest(text))
      expect(File.binread(target)).to eq(text)
      expect(strays).to eq([])
    end

    it "writes nothing under dry_run, after taking the lock and checking" do
      expect(files.add("flow", text, dry_run: true)).to eq("path" => target, "sha256" => Digest::SHA256.hexdigest(text))
      expect(File.exist?(target)).to be(false)
      expect(File.exist?(lock_path)).to be(true)
      FileUtils.touch(target)
      expect { files.add("flow", text, dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_exists") }
    end

    it "refuses workflow_exists over a file there, leaving its bytes" do
      FileUtils.mkdir_p(global_dir)
      File.write(target, "mine\n")

      expect { files.add("flow", text) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workflow_exists")
        expect(e.details).to eq("workflow" => "flow", "path" => target)
      }
      expect(File.read(target)).to eq("mine\n")
    end

    it "counts a link to a file that is gone, and never writes through it" do
      FileUtils.mkdir_p(global_dir)
      gone = File.join(dir, "gone.yml")
      File.symlink(gone, target)

      expect { files.add("flow", text) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_exists") }
      expect(File.exist?(gone)).to be(false)
    end

    it "refuses a bad id before any path is built: no directory, no lock file" do
      expect(File).not_to receive(:open)

      expect { files.add("../evil", text) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_workflow") }
      expect(File.exist?(global_dir)).to be(false)
      expect(Dir.glob(File.join(dir, "**", "*evil*"), File::FNM_DOTMATCH)).to eq([])
    end

    it "leaves no temp file when the write fails" do
      allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

      expect { files.add("flow", text) }.to raise_error(Errno::ENOSPC)
      expect(File.exist?(target)).to be(false)
      expect(strays).to eq([])
    end

    it "checks under the lock: an add that waited on another sees its file and refuses" do
      FileUtils.mkdir_p(global_dir)
      other = "title: Other\nsteps:\n  plan:\n    prompt: Other.\n"
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        thread = Thread.new { files.add("flow", text) }
        thread.report_on_exception = false
        wait_until_blocked(thread)
        expect(File.exist?(target)).to be(false)

        File.write(target, other)
        lock.flock(File::LOCK_UN)

        expect { joined(thread).value }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_exists") }
      end
      expect(File.read(target)).to eq(other)
    end

    it "lets exactly one of two adds of one id at once write" do
      texts = %w[One Two].map { |title| "title: #{title}\nsteps:\n  plan:\n    prompt: #{title}.\n" }
      gate = Queue.new
      threads = texts.map do |each|
        Thread.new do
          gate.pop
          files.add("flow", each)
          [:added, each]
        rescue Workspace::Error => e
          [e.code, each]
        end
      end
      2.times { gate << :go }

      results = threads.map { |thread| joined(thread).value }

      expect(results.map(&:first)).to contain_exactly(:added, "workflow_exists")
      winner = results.find { |outcome, _| outcome == :added }.last
      expect(File.read(target)).to eq(winner)
      expect(strays).to eq([])
    end
  end
end
