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

  describe "#update" do
    let(:old_text) { "title: Old\nsteps:\n  plan:\n    prompt: Old.\n" }
    let(:old_sha) { Digest::SHA256.hexdigest(old_text) }

    before do
      FileUtils.mkdir_p(global_dir)
      File.write(target, old_text)
    end

    it "replaces the file when the sha256 matches, answering the new sha256" do
      expect(files.update("flow", text, if_sha256: old_sha)).to eq("path" => target, "sha256" => Digest::SHA256.hexdigest(text))
      expect(File.binread(target)).to eq(text)
      expect(strays).to eq([])
    end

    it "keeps the mode a written file gets" do
      previous = File.umask(0o022)
      begin
        files.update("flow", text, if_sha256: old_sha)
      ensure
        File.umask(previous)
      end

      expect(File.stat(target).mode & 0o777).to eq(0o644)
    end

    it "writes nothing under dry_run" do
      expect(files.update("flow", text, if_sha256: old_sha, dry_run: true)).to eq("path" => target, "sha256" => Digest::SHA256.hexdigest(text))
      expect(File.binread(target)).to eq(old_text)
      expect { files.update("flow", text, if_sha256: "0" * 64, dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("stale_workflow") }
    end

    it "refuses stale_workflow for another sha, naming the current one and leaving the bytes" do
      before = File.binread(target)

      expect { files.update("flow", text, if_sha256: "0" * 64) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("stale_workflow")
        expect(e.message).to include("changed").and include("Nothing was changed")
        expect(e.details).to eq("workflow" => "flow", "path" => target, "sha256" => old_sha)
      }
      expect(File.binread(target)).to eq(before)
      expect(strays).to eq([])
    end

    it "takes an uppercase sha256" do
      expect(files.update("flow", text, if_sha256: old_sha.upcase)["sha256"]).to eq(Digest::SHA256.hexdigest(text))
    end

    it "ignores whitespace around the sha256" do
      expect(files.update("flow", text, if_sha256: " #{old_sha}\n")["sha256"]).to eq(Digest::SHA256.hexdigest(text))
    end

    it "replaces a file that is not valid YAML or UTF-8, hashing its raw bytes" do
      bytes = (+"title: \xFF\xFE: [").b
      File.binwrite(target, bytes)

      files.update("flow", text, if_sha256: Digest::SHA256.hexdigest(bytes))

      expect(File.binread(target)).to eq(text)
    end

    it "refuses builtin_workflow when only a preset has the id, leaving it alone" do
      FileUtils.mkdir_p(File.join(dir, "builtin"))
      preset = File.join(dir, "builtin", "rpiv.yml")
      File.write(preset, old_text)

      expect { files.update("rpiv", text, if_sha256: old_sha) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("builtin_workflow")
        expect(e.details).to eq("workflow" => "rpiv")
      }
      expect(File.binread(preset)).to eq(old_text)
      expect(File.exist?(File.join(global_dir, "rpiv.yml"))).to be(false)
    end

    it "refuses unknown_workflow when nothing has the id" do
      expect { files.update("nope", text, if_sha256: old_sha) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workflow") }
      expect(File.exist?(File.join(global_dir, "nope.yml"))).to be(false)
    end

    it "counts a link to a file that is gone as there but stale, and never writes through it" do
      File.delete(target)
      gone = File.join(dir, "gone.yml")
      File.symlink(gone, target)

      expect { files.update("flow", text, if_sha256: old_sha) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("stale_workflow")
        expect(e.details["sha256"]).to be_nil
        expect(e.message).to include("workflow remove flow").and include("by hand")
      }
      expect(File.exist?(gone)).to be(false)
    end

    it "refuses a bad id before any path is built" do
      expect { files.update("../evil", text, if_sha256: old_sha) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_workflow") }
    end

    it "leaves the file and no temp file when the write fails" do
      allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

      expect { files.update("flow", text, if_sha256: old_sha) }.to raise_error(Errno::ENOSPC)
      expect(File.binread(target)).to eq(old_text)
      expect(strays).to eq([])
    end

    it "checks under the lock: an update that waited on a rewrite fails stale_workflow and the rewrite stays" do
      other = "title: Other\nsteps:\n  plan:\n    prompt: Other.\n"
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        thread = Thread.new { files.update("flow", text, if_sha256: old_sha) }
        thread.report_on_exception = false
        wait_until_blocked(thread)
        expect(File.binread(target)).to eq(old_text)

        File.write(target, other)
        lock.flock(File::LOCK_UN)

        expect { joined(thread).value }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("stale_workflow")
          expect(e.details["sha256"]).to eq(Digest::SHA256.hexdigest(other))
        }
      end
      expect(File.read(target)).to eq(other)
    end

    it "lets exactly one of two updates from one sha256 at once write" do
      texts = %w[One Two].map { |title| "title: #{title}\nsteps:\n  plan:\n    prompt: #{title}.\n" }
      gate = Queue.new
      threads = texts.map do |each|
        Thread.new do
          gate.pop
          files.update("flow", each, if_sha256: old_sha)
          [:updated, each]
        rescue Workspace::Error => e
          [e.code, each]
        end
      end
      2.times { gate << :go }

      results = threads.map { |thread| joined(thread).value }

      expect(results.map(&:first)).to contain_exactly(:updated, "stale_workflow")
      expect(File.read(target)).to eq(results.find { |outcome, _| outcome == :updated }.last)
      expect(strays).to eq([])
    end
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
