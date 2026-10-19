require "spec_helper"

RSpec.describe Workspace::LibraryInstallDirs do
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global) }
  let(:global) { {} }
  let(:resolver) { Workspace::ConfigResolver.new(project_settings: project_settings) }
  subject(:dirs) { described_class.new(config_resolver: resolver, home: "/home/me") }

  def project(value)
    allow(project_settings).to receive(:load).with("app").and_return(value)
  end

  it "answers the defaults when nothing is set, or when no resolver is given" do
    project({})

    expect(dirs.relative("skill", project: "app")).to eq(".claude/skills")
    expect(dirs.relative("agent", project: "app")).to eq(".claude/agents")
    expect(dirs.user("skill")).to eq("/home/me/.claude/skills")
    expect(dirs.user("agent")).to eq("/home/me/.claude/agents")
    bare = described_class.new(home: "/home/me")
    expect(bare.relative("skill", project: "app")).to eq(".claude/skills")
    expect(bare.user("agent")).to eq("/home/me/.claude/agents")
  end

  context "with a global value" do
    let(:global) { {"library" => {"install" => {"skills_dir" => ".agents/skills", "user_skills_dir" => "~/.agents/skills"}}} }

    it "uses it for every project, and for --user" do
      project({})

      expect(dirs.relative("skill", project: "app")).to eq(".agents/skills")
      expect(dirs.relative("agent", project: "app")).to eq(".claude/agents")
      expect(dirs.user("skill")).to eq("/home/me/.agents/skills")
    end

    it "lets the project's value win" do
      project("library" => {"install" => {"skills_dir" => ".claude/skills"}})

      expect(dirs.relative("skill", project: "app")).to eq(".claude/skills")
    end

    it "reads a worktree's parent project" do
      allow(project_settings).to receive(:load).with("app.worktree-x").and_return({})
      project("library" => {"install" => {"skills_dir" => "vendor/skills/"}})

      expect(dirs.relative("skill", project: "app.worktree-x")).to eq("vendor/skills")
    end
  end

  it "leaves an absolute user directory as it is" do
    allow(project_settings).to receive(:load_global).and_return("library" => {"install" => {"user_agents_dir" => "/srv/agents"}})

    expect(dirs.user("agent")).to eq("/srv/agents")
  end

  it "names the key when a hand-edited value is not valid" do
    project("library" => {"install" => {"skills_dir" => "../shared"}})

    expect { dirs.relative("skill", project: "app") }
      .to raise_error(Workspace::Error) { |e| expect([e.code, e.details]).to eq(["invalid_library_install_dir", {"key" => "library.install.skills_dir"}]) }
  end
end
