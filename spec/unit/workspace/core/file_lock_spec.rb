require "tmpdir"

RSpec.describe Workspace::FileLock do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "sub", "data.json.lock") }

  after { FileUtils.remove_entry(dir) }

  def hold_elsewhere(mode)
    FileUtils.mkdir_p(File.dirname(path))
    other = File.open(path, File::RDWR | File::CREAT, 0o600)
    other.flock(mode)
    other
  end

  describe "#hold" do
    it "makes the lock file and its directory (0700) and returns the block's result" do
      lock = described_class.new(path)
      expect(lock.hold { |held| [held, :done] }).to eq([true, :done])
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
    end

    it "sets the directory mode on an existing directory only with chmod_dir" do
      FileUtils.mkdir_p(File.dirname(path), mode: 0o755)
      described_class.new(path).hold {}
      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o755)
      described_class.new(path, chmod_dir: true).hold {}
      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
    end

    it "makes the directory without a mode when dir_mode is nil" do
      described_class.new(path, dir_mode: nil).hold {}
      expect(File.directory?(File.dirname(path))).to be(true)
    end

    it "lets shared holders in together" do
      other = hold_elsewhere(File::LOCK_SH)
      expect(described_class.new(path).hold(shared: true, nonblocking: true) { :read }).to eq(:read)
    ensure
      other&.close
    end

    it "keeps a writer out while a shared hold is open" do
      lock = described_class.new(path)
      lock.hold(shared: true) do
        expect(lock.hold(nonblocking: true) { :never }).to be_nil
      end
    end

    it "keeps a reader out while an exclusive hold is open" do
      lock = described_class.new(path)
      lock.hold do
        expect(lock.hold(shared: true, nonblocking: true) { :never }).to be_nil
      end
    end

    it "releases the lock after the block, and when the block raises" do
      lock = described_class.new(path)
      expect { lock.hold { raise "boom" } }.to raise_error("boom")
      expect(lock.hold(nonblocking: true) { :free }).to eq(:free)
    end

    it "returns nil without yielding when nonblocking and the lock is taken" do
      other = hold_elsewhere(File::LOCK_EX)
      yielded = false
      expect(described_class.new(path).hold(nonblocking: true) { yielded = true }).to be_nil
      expect(yielded).to be(false)
    ensure
      other&.close
    end

    it "opens the lock file read-only for a shared hold with open_readonly" do
      flags = []
      opener = lambda do |p, f, perm, &block|
        flags << (f & 3)
        File.open(p, f, perm, &block)
      end
      lock = described_class.new(path, open_readonly: true, opener: opener)
      lock.hold(shared: true) {}
      lock.hold {}
      expect(flags).to eq([File::RDONLY, File::RDWR])
    end

    it "raises the system error when the lock file can't be opened" do
      opener = ->(*, &_) { raise Errno::EACCES }
      expect { described_class.new(path, opener: opener).hold {} }.to raise_error(Errno::EACCES)
    end

    context "with wait:" do
      it "yields held true when the lock is free" do
        expect(described_class.new(path).hold(wait: 1) { |held| held }).to be(true)
      end

      it "yields held false when the wait runs out, sleeping between tries" do
        other = hold_elsewhere(File::LOCK_EX)
        now = 0.0
        sleeps = []
        lock = described_class.new(path, clock: -> { now }, sleeper: ->(s) {
          sleeps << s
          now += 0.5
        })
        expect(lock.hold(wait: 1) { |held| held }).to be(false)
        expect(sleeps.size).to eq(2)
      ensure
        other&.close
      end

      it "gets the lock when it is freed during the wait" do
        other = hold_elsewhere(File::LOCK_EX)
        lock = described_class.new(path, sleeper: ->(_) { other.close })
        expect(lock.hold(wait: 1) { |held| held }).to be(true)
      end

      it "yields held false when the lock file can't be opened" do
        opener = ->(*, &_) { raise Errno::EACCES }
        expect(described_class.new(path, opener: opener).hold(wait: 1) { |held| held }).to be(false)
      end

      it "reports the open failure to on_unavailable:" do
        opener = ->(*, &_) { raise Errno::EACCES }
        seen = []
        lock = described_class.new(path, opener: opener, on_unavailable: ->(step, error) { seen << [step, error.class] })
        lock.hold(wait: 1) {}
        expect(seen).to eq([[:open, Errno::EACCES]])
      end

      it "reports a failed flock to on_unavailable:" do
        seen = []
        file = instance_double(File, close: nil)
        allow(file).to receive(:flock).and_raise(Errno::ENOLCK)
        lock = described_class.new(path, opener: ->(*, &_) { file }, on_unavailable: ->(step, _) { seen << step })
        expect(lock.hold(wait: 1) { |held| held }).to be(false)
        expect(seen).to eq([:lock])
      end

      it "leaves a missing directory alone with make_dir: false" do
        expect(described_class.new(path, make_dir: false).hold(wait: 1) { |held| held }).to be(false)
        expect(File.exist?(File.dirname(path))).to be(false)
      end

      it "does not catch a system error raised by the block" do
        expect { described_class.new(path).hold(wait: 1) { raise Errno::EACCES } }.to raise_error(Errno::EACCES)
      end
    end
  end
end
