require "spec_helper"

RSpec.describe "lib/skills" do
  let(:root) { File.join(PROJECT_ROOT, "lib", "skills") }
  let(:skill_dirs) { Dir.children(root).map { |d| File.join(root, d) }.select { |d| File.directory?(d) }.sort }

  it "ships the six workspace skills" do
    expect(skill_dirs.map { |d| File.basename(d) }).to eq(%w[workspace workspace-agent-run workspace-inbox workspace-lifecycle workspace-template workspace-workflow])
  end

  it "gives each SKILL.md a name equal to its directory and a description" do
    skill_dirs.each do |dir|
      front = File.read(File.join(dir, "SKILL.md"))[/\A---\n(.*?)\n---/m, 1]
      expect(front).not_to be_nil, "#{dir}: no frontmatter"
      data = YAML.safe_load(front)
      expect(data["name"]).to eq(File.basename(dir))
      expect(data["description"].to_s.strip).not_to be_empty
    end
  end

  it "links exactly the skills that ship" do
    expect(Workspace::SkillSource::NAMES.sort).to eq(skill_dirs.map { |d| File.basename(d) })
  end

  it "keeps each description under 400 characters" do
    skill_dirs.each do |dir|
      data = YAML.safe_load(File.read(File.join(dir, "SKILL.md"))[/\A---\n(.*?)\n---/m, 1])
      expect(data["description"].length).to be < 400, "#{dir}: #{data["description"].length} characters"
    end
  end

  it "has script/check-skills read every SKILL.md" do
    script = File.read(File.join(PROJECT_ROOT, "script", "check-skills"))
    skill_dirs.each do |dir|
      expect(script).to include("#{File.basename(dir)}/SKILL.md")
    end
  end

  describe "workspace-workflow" do
    let(:body) { File.read(File.join(root, "workspace-workflow", "SKILL.md")) }

    it "keeps the gate safety rule and points at skill workspace for the table" do
      expect(body).to include("`workflow approve`", "`workflow reject`", "skill `workspace`")
      expect(body).not_to include("dev down --force")
    end

    it "tells the agent what a parked answer means" do
      expect(body).to include("`parked`")
    end
  end

  it "names go in the parked row of the machine contract" do
    contract = File.read(File.join(root, "workspace", "references", "machine-contract.md"))
    expect(contract[/^\|.*outcome `parked`.*$/]).to include("`go`")
  end

  it "resolves every relative markdown link" do
    Dir.glob(File.join(root, "**/*.md")).each do |file|
      File.read(file).scan(/\]\((\.\.?\/[^)#\s]*)/).flatten.each do |link|
        expect(File.exist?(File.expand_path(link, File.dirname(file)))).to be(true), "#{file}: #{link} does not resolve"
      end
    end
  end
end
