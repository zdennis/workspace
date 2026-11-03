require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Workspace::RenameJournal do
  let(:home) { File.realpath(Dir.mktmpdir("ws-journal", "/tmp")) }
  let(:config) { Workspace::Config.new(workspace_dir: home) }
  let(:journal) { described_class.new(config: config) }
  let(:old) { "api.worktree-feat-a" }
  let(:new) { "api.worktree-feat-b" }
  let(:notes) { Workspace::RenamePlan::NotesMove.new(action: "stays", from: "/n", to: "/n") }
  let(:plan) do
    Workspace::RenamePlan::Plan.new(project: "api", workspace: old, new_workspace: new, branch: "feat/a", new_branch: "feat/b", path: "/r/feat-a",
      new_path: "/r/feat-b", session: "api-wt-feat-a", new_session: "api-wt-feat-b", notes: notes, warnings: [], resume: false)
  end
  let(:path) { config.rename_journal_path(old) }

  around do |example|
    saved = ENV.to_h.slice("HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME")
    ENV["HOME"] = home
    ENV.delete("XDG_STATE_HOME")
    ENV.delete("XDG_CONFIG_HOME")
    example.run
  ensure
    %w[HOME XDG_STATE_HOME XDG_CONFIG_HOME].each { |key| ENV.delete(key) }
    saved.each { |key, value| ENV[key] = value }
    FileUtils.remove_entry(home)
  end

  describe "#write" do
    it "writes the file 0600 in a 0700 directory" do
      journal.write(plan)

      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
      expect(JSON.parse(File.read(path))).to include("workspace" => old, "new_workspace" => new, "new_branch" => "feat/b")
    end

    it "leaves no temporary file when the rename fails" do
      allow(File).to receive(:rename).and_raise(Errno::EACCES)

      expect { journal.write(plan) }.to raise_error(Errno::EACCES)

      expect(Dir.children(File.dirname(path))).to eq([])
    end
  end

  describe "#read" do
    it "finds a journal by its new name, and leaves out one it can't read" do
      FileUtils.mkdir_p(config.rename_journal_dir)
      File.write(config.rename_journal_path("other"), "{")
      File.write(path, JSON.generate("workspace" => old, "new_workspace" => new))

      expect(journal.read(new)).to include("workspace" => old)
      expect(journal.read("nobody")).to be_nil
      expect(journal.read("../x")).to be_nil
    end

    it "says a workspace's own unreadable journal is a rename in progress" do
      FileUtils.mkdir_p(config.rename_journal_dir)
      File.write(path, "{")

      expect { journal.read(old) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("rename_in_progress")
        expect(e.details).to include("path" => path, "rerun" => false, "fix" => "rm #{path}")
      }
    end
  end
end
