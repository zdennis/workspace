require "tmpdir"

RSpec.describe Workspace::FileBackup do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:clock) { double(now: Time.new(2026, 9, 26, 10, 22, 21)) }
  let(:path) { File.join(tmpdir, "settings.json") }

  subject(:backup) { described_class.new(output: output, clock: clock) }

  after { FileUtils.remove_entry(tmpdir) }

  describe "#backup" do
    it "copies the file aside and reports where" do
      File.write(path, "original")

      destination = backup.backup(path)

      expect(destination).to eq("#{path}.workspace-backup-20260926102221")
      expect(File.read(destination)).to eq("original")
      expect(output.string).to include(destination)
    end

    it "does nothing when the file does not exist" do
      expect(backup.backup(path)).to be_nil
      expect(output.string).to eq("")
    end

    it "does not overwrite an earlier backup taken the same second" do
      File.write(path, "first")
      first = backup.backup(path)
      File.write(path, "second")

      second = backup.backup(path)

      expect(second).not_to eq(first)
      expect(File.read(first)).to eq("first")
      expect(File.read(second)).to eq("second")
    end

    it "reports the path without writing it on a dry run" do
      File.write(path, "original")

      destination = backup.backup(path, dry_run: true)

      expect(File.exist?(destination)).to be false
      expect(output.string).to include(destination)
    end
  end
end
