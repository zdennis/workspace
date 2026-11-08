require "tmpdir"
require "json"

RSpec.describe Workspace::LockedJsonFile do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "data.json") }
  let(:parse) do
    lambda do |text|
      return [] if text.nil? || text.strip.empty?
      JSON.parse(text)
    rescue JSON::ParserError
      raise Workspace::Error, "corrupt"
    end
  end

  subject(:file) { described_class.new(path, parse: parse) }

  after { FileUtils.remove_entry(dir) }

  def leftovers = Dir.children(dir) - ["data.json", "data.json.lock"]

  describe "#exclusive" do
    it "passes parse's empty value for no file, writes the change pretty and returns the block's result" do
      result = file.exclusive { |data| (data << "a") && :done }
      expect(result).to eq(:done)
      expect(File.read(path)).to eq(JSON.pretty_generate(["a"]))
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(leftovers).to be_empty
    end

    it "reads what an earlier call wrote" do
      file.exclusive { |data| data << 1 }
      expect(file.exclusive { |data| data.dup }).to eq([1])
    end

    it "writes even an unchanged document by default" do
      File.write(path, "[ ]")
      file.exclusive { |_| }
      expect(File.read(path)).to eq("[]")
    end

    it "skips the write with write: :if_changed when the data is equal" do
      File.write(path, "[ 1 ]")
      file.exclusive(write: :if_changed) { |_| }
      expect(File.read(path)).to eq("[ 1 ]")
      file.exclusive(write: :if_changed) { |data| data << 2 }
      expect(JSON.parse(File.read(path))).to eq([1, 2])
    end

    it "writes with write: :if_true only when the block returns a true value" do
      file.exclusive(write: :if_true) { |data| (data << 1) && false }
      expect(File.exist?(path)).to be(false)
      expect(file.exclusive(write: :if_true) { |data| (data << 1) && true }).to be(true)
      expect(JSON.parse(File.read(path))).to eq([1])
    end

    it "runs after_write under the lock whether or not it wrote" do
      lock = Workspace::FileLock.new("#{path}.lock")
      calls = []
      locked = described_class.new(path, parse: parse, lock: lock)
      after = -> { calls << lock.hold(nonblocking: true) { :got } }
      locked.exclusive(write: :if_changed, after_write: after) { |_| }
      locked.exclusive(after_write: after) { |data| data << 1 }
      expect(calls).to eq([nil, nil])
    end

    it "leaves a corrupt file untouched when parse raises, and never yields" do
      File.write(path, "{nope")
      yielded = false
      expect { file.exclusive { yielded = true } }.to raise_error(Workspace::Error, "corrupt")
      expect(yielded).to be(false)
      expect(File.read(path)).to eq("{nope")
      expect(leftovers).to be_empty
    end

    it "writes nothing when the block raises" do
      File.write(path, "[1]")
      expect { file.exclusive { |data| data << 2 && raise("boom") } }.to raise_error("boom")
      expect(File.read(path)).to eq("[1]")
      expect(leftovers).to be_empty
    end

    it "keeps the old file and no temp when the rename fails" do
      File.write(path, "[1]")
      renamer = ->(_from, _to) { raise Errno::EXDEV }
      failing = described_class.new(path, parse: parse, renamer: renamer)
      expect { failing.exclusive { |data| data << 2 } }.to raise_error(Errno::EXDEV)
      expect(File.read(path)).to eq("[1]")
      expect(leftovers).to be_empty
    end

    it "turns a system error into the store's own error through access_error" do
      renamer = ->(_from, _to) { raise Errno::EACCES }
      mapped = ->(e) { Workspace::Error.new("Could not access: errno #{e.errno}") }
      failing = described_class.new(path, parse: parse, renamer: renamer, access_error: mapped)
      expect { failing.exclusive { |data| data << 1 } }.to raise_error(Workspace::Error, /Could not access: errno #{Errno::EACCES::Errno}/o)
    end

    it "raises read_error's exception, ahead of access_error, when the document can't be read" do
      File.write(path, "[]")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(path, anything).and_raise(Errno::EACCES)
      failing = described_class.new(path, parse: parse, read_error: ->(_) { Workspace::Error.new("cannot read") },
        access_error: ->(_) { Workspace::Error.new("no access") })
      expect { failing.exclusive { |data| data << 1 } }.to raise_error(Workspace::Error, "cannot read")
    end

    it "returns nil without yielding when nonblocking and another process holds the lock" do
      other = File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600)
      other.flock(File::LOCK_EX)
      yielded = false
      expect(file.exclusive(nonblocking: true) { yielded = true }).to be_nil
      expect(yielded).to be(false)
    ensure
      other&.close
    end

    it "excludes a second writer while it runs" do
      file.exclusive do
        expect(file.exclusive(nonblocking: true) { :never }).to be_nil
        expect(file.shared(nonblocking: true) { :never }).to be_nil
      end
    end

    it "uses generate:, fsync:, tag: and perm:" do
      seen = nil
      renamer = ->(from, to) {
        seen = from
        File.rename(from, to)
      }
      custom = described_class.new(path, parse: parse, generate: ->(d) { JSON.generate(d) }, fsync: false,
        tag: "x", perm: 0o644, renamer: renamer)
      custom.exclusive { |data| data << 1 }
      expect(File.read(path)).to eq("[1]")
      expect(File.stat(path).mode & 0o777).to eq(0o644)
      expect(seen).to eq("#{path}.#{Process.pid}.x.tmp")
    end

    it "locks on lock_path" do
      other = described_class.new(path, parse: parse, lock_path: File.join(dir, "elsewhere.lock"))
      other.exclusive { |data| data << 1 }
      expect(File.exist?(File.join(dir, "elsewhere.lock"))).to be(true)
    end
  end

  describe "#shared" do
    it "yields the parsed data, writes nothing and lets other readers in" do
      File.write(path, "[ 1 ]")
      other = File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600)
      other.flock(File::LOCK_SH)
      expect(file.shared(nonblocking: true) { |data| data.sum }).to eq(1)
      expect(File.read(path)).to eq("[ 1 ]")
    ensure
      other&.close
    end

    it "does not write a change the block makes" do
      File.write(path, "[1]")
      file.shared { |data| data << 2 }
      expect(File.read(path)).to eq("[1]")
    end

    it "returns nil without yielding when nonblocking and a writer holds the lock" do
      other = File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600)
      other.flock(File::LOCK_EX)
      expect(file.shared(nonblocking: true) { :never }).to be_nil
    ensure
      other&.close
    end

    it "lets parse decide what a corrupt file reads as" do
      File.write(path, "{nope")
      lenient = described_class.new(path, parse: ->(_) { [] })
      expect(lenient.shared { |data| data }).to eq([])
      expect(File.read(path)).to eq("{nope")
    end

    it "runs after_write" do
      called = false
      file.shared(after_write: -> { called = true }) { |_| }
      expect(called).to be(true)
    end

    it "passes the system error through access_error" do
      lock = Workspace::FileLock.new("#{path}.lock", opener: ->(*, &_) { raise Errno::EACCES })
      mapped = described_class.new(path, parse: parse, lock: lock, access_error: ->(_) { Workspace::Error.new("no access") })
      expect { mapped.shared { |_| } }.to raise_error(Workspace::Error, "no access")
    end
  end
end
