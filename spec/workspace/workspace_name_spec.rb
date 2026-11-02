require "spec_helper"

RSpec.describe Workspace::WorkspaceName do
  let(:projects) { ["Notes", "api"] }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: projects) }
  subject(:names) { described_class.new(project_config: project_config) }

  describe ".normalize" do
    it "lowercases and leaves nil alone" do
      expect(described_class.normalize("Notes")).to eq("notes")
      expect(described_class.normalize(nil)).to be_nil
    end
  end

  describe ".same?" do
    it "ignores case" do
      expect(described_class.same?("notes", "Notes")).to be(true)
      expect(described_class.same?("notes", "api")).to be(false)
    end

    it "is false when either side is nil" do
      expect(described_class.same?(nil, "notes")).to be(false)
      expect(described_class.same?("notes", nil)).to be(false)
    end
  end

  describe "#resolve" do
    it "gives the on-disk name for a name that matches a config ignoring case" do
      expect(names.resolve("notes")).to eq("Notes")
      expect(names.resolve("NOTES")).to eq("Notes")
      expect(names.resolve("Notes")).to eq("Notes")
    end

    it "gives the lowercase name when no config matches" do
      expect(names.resolve("Fresh")).to eq("fresh")
    end

    it "keeps nil" do
      expect(names.resolve(nil)).to be_nil
    end

    it "prefers the exact spelling when configs differ only in case" do
      projects.replace(["notes", "Notes"])
      expect(names.resolve("Notes")).to eq("Notes")
      expect(names.resolve("notes")).to eq("notes")
    end
  end

  describe "#match" do
    it "is nil when no config matches, or for nil" do
      expect(names.match("fresh")).to be_nil
      expect(names.match(nil)).to be_nil
    end

    it "finds the config ignoring case" do
      expect(names.match("nOtEs")).to eq("Notes")
    end
  end

  describe "#for_input" do
    let(:state_keys) { [] }
    let(:state) { instance_double(Workspace::State, load: nil, keys: state_keys) }
    let(:projects) { ["workspace", "workspace.worktree-workspace", "b.worktree-foo", "Notes.worktree-Fix", "a.worktree-"] }
    subject(:names) { described_class.new(project_config: project_config, state: state) }

    it "prefers the exact name to a suffix" do
      expect(names.for_input("workspace")).to eq("workspace")
    end

    it "prefers a case-insensitive exact name to a suffix" do
      expect(names.for_input("WORKSPACE")).to eq("workspace")
    end

    it "answers the config whose suffix matches, in any case" do
      expect(names.for_input("foo")).to eq("b.worktree-foo")
      expect(names.for_input("FIX")).to eq("Notes.worktree-Fix")
    end

    it "is nil for the project alone or part of a suffix" do
      expect(names.for_input("b")).to be_nil
      expect(names.for_input("fo")).to be_nil
    end

    it "raises with sorted matches on a tie" do
      projects.push("a.worktree-foo")
      expect { names.for_input("foo") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("ambiguous_workspace")
        expect(e.details).to eq("name" => "foo", "matches" => ["a.worktree-foo", "b.worktree-foo"])
      }
    end

    it "is nil for nil and empty, and an empty suffix is no hit" do
      expect(names.for_input(nil)).to be_nil
      expect(names.for_input("")).to be_nil
    end

    context "with an active workspace named foo and no config" do
      let(:state_keys) { ["foo"] }

      it "keeps the name, also on a tie" do
        expect(names.for_input("foo")).to be_nil
        projects.push("a.worktree-foo")
        expect(names.for_input("foo")).to be_nil
      end
    end

    it "answers a suffix hit with no state" do
      expect(described_class.new(project_config: project_config).for_input("foo")).to eq("b.worktree-foo")
    end

    it "raises on a tie with no state" do
      projects.push("a.worktree-foo")
      expect { described_class.new(project_config: project_config).for_input("foo") }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("ambiguous_workspace") }
    end

    it "raises on a tie between suffixes that differ only in case" do
      projects.push("a.worktree-Foo")
      expect { names.for_input("foo") }.to raise_error(Workspace::Error) { |e|
        expect(e.details["matches"]).to eq(["a.worktree-Foo", "b.worktree-foo"])
      }
    end

    it "does not load state when nothing hits" do
      names.for_input("zzz")
      expect(state).not_to have_received(:load)
    end

    it "leaves match and resolve alone for a bare suffix" do
      expect(names.match("foo")).to be_nil
      expect(names.resolve("foo")).to eq("foo")
    end
  end
end
