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

  describe "SEPARATOR" do
    it "is the worktree marker in a workspace name" do
      expect(described_class::SEPARATOR).to eq(".worktree-")
    end
  end

  describe ".split" do
    it "splits at the separator into project and suffix" do
      expect(described_class.split("app.worktree-ticket-1")).to eq(["app", "ticket-1"])
    end

    it "is nil without a separator and for nil" do
      expect(described_class.split("app")).to be_nil
      expect(described_class.split(nil)).to be_nil
    end

    it "keeps an empty suffix and an empty project" do
      expect(described_class.split("app.worktree-")).to eq(["app", ""])
      expect(described_class.split(".worktree-x")).to eq(["", "x"])
    end

    it "splits only at the first separator" do
      expect(described_class.split("app.worktree-a.worktree-b")).to eq(["app", "a.worktree-b"])
    end

    it "keeps the case of both parts" do
      expect(described_class.split("App.worktree-Ticket")).to eq(["App", "Ticket"])
    end
  end

  describe ".worktree?" do
    it "is true only when the name has a separator" do
      expect(described_class.worktree?("app.worktree-x")).to be(true)
      expect(described_class.worktree?("app.worktree-")).to be(true)
      expect(described_class.worktree?("app")).to be(false)
      expect(described_class.worktree?(nil)).to be(false)
    end
  end

  describe ".project_of" do
    it "is the project part of a worktree name" do
      expect(described_class.project_of("App.worktree-x.worktree-y")).to eq("App")
    end

    it "is the name itself otherwise, nil included" do
      expect(described_class.project_of("app")).to eq("app")
      expect(described_class.project_of(nil)).to be_nil
    end
  end

  describe ".join" do
    it "joins project and suffix in lowercase" do
      expect(described_class.join("My.App", "Ticket-1")).to eq("my.app.worktree-ticket-1")
    end

    it "round-trips through split for a lowercase pair" do
      expect(described_class.split(described_class.join("app", "x"))).to eq(["app", "x"])
    end
  end

  describe ".mixed_case?" do
    it "is true when lowercasing would change the name" do
      expect(described_class.mixed_case?("Notes")).to be(true)
      expect(described_class.mixed_case?("app.worktree-X")).to be(true)
    end

    it "is false for a lowercase name, empty and nil" do
      expect(described_class.mixed_case?("notes-1")).to be(false)
      expect(described_class.mixed_case?("")).to be(false)
      expect(described_class.mixed_case?(nil)).to be(false)
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
