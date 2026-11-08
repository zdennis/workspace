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

    it "compares with fingerprint: when given, so a key reorder with equal values writes" do
      File.write(path, '{"a":1,"b":2}')
      generate = ->(data) { JSON.generate(data) }
      hashes = described_class.new(path, parse: ->(text) { text ? JSON.parse(text) : {} }, fingerprint: generate)
      hashes.exclusive(write: :if_changed) { |_| }
      expect(File.read(path)).to eq('{"a":1,"b":2}')
      hashes.exclusive(write: :if_changed) { |data| data.replace(data.slice("b", "a")) }
      expect(JSON.parse(File.read(path)).keys).to eq(%w[b a])
    end

    it "calls a callable tag at each write" do
      calls = 0
      tagged = described_class.new(path, parse: parse, tag: -> { calls += 1 })
      2.times { tagged.exclusive { |data| data << 1 } }
      expect(calls).to eq(2)
      expect(leftovers).to be_empty
    end

    it "writes with write: :if_true only when the block returns a true value" do
      file.exclusive(write: :if_true) { |data| (data << 1) && false }
      expect(File.exist?(path)).to be(false)
      expect(file.exclusive(write: :if_true) { |data| (data << 1) && true }).to be(true)
      expect(JSON.parse(File.read(path))).to eq([1])
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

    it "turns a system error into the store's own error through access_error" do
      blocker = File.join(dir, "file")
      File.write(blocker, "")
      mapped = ->(e) { Workspace::Error.new("Could not access: #{e.class}") }
      failing = described_class.new(File.join(blocker, "data.json"), parse: parse, access_error: mapped)
      expect { failing.exclusive { |data| data << 1 } }.to raise_error(Workspace::Error, /Could not access: Errno::/)
    end

    it "raises read_error's exception, ahead of access_error, when the document can't be read" do
      File.write(path, "[]")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(path, anything).and_raise(Errno::EACCES)
      failing = described_class.new(path, parse: parse, read_error: ->(_) { Workspace::Error.new("cannot read") },
        access_error: ->(_) { Workspace::Error.new("no access") })
      expect { failing.exclusive { |data| data << 1 } }.to raise_error(Workspace::Error, "cannot read")
    end
  end

  describe "#shared" do
    it "yields the parsed data, writes nothing and lets other readers in" do
      File.write(path, "[ 1 ]")
      other = File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600)
      other.flock(File::LOCK_SH)
      expect(file.shared { |data| data.sum }).to eq(1)
      expect(File.read(path)).to eq("[ 1 ]")
    ensure
      other&.close
    end

    it "does not write a change the block makes" do
      File.write(path, "[1]")
      file.shared { |data| data << 2 }
      expect(File.read(path)).to eq("[1]")
    end

    it "lets parse decide what a corrupt file reads as" do
      File.write(path, "{nope")
      lenient = described_class.new(path, parse: ->(_) { [] })
      expect(lenient.shared { |data| data }).to eq([])
      expect(File.read(path)).to eq("{nope")
    end

    it "passes the system error through access_error" do
      blocker = File.join(dir, "file")
      File.write(blocker, "")
      mapped = described_class.new(File.join(blocker, "data.json"), parse: parse, access_error: ->(_) { Workspace::Error.new("no access") })
      expect { mapped.shared { |_| } }.to raise_error(Workspace::Error, "no access")
    end
  end
end
