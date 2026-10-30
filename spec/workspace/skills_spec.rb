require "spec_helper"

RSpec.describe "lib/skills" do
  let(:root) { File.expand_path("../../lib/skills", __dir__) }
  let(:skill_dirs) { Dir.children(root).map { |d| File.join(root, d) }.select { |d| File.directory?(d) }.sort }

  it "ships the four workspace skills" do
    expect(skill_dirs.map { |d| File.basename(d) }).to eq(%w[workspace workspace-agent-run workspace-inbox workspace-lifecycle])
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

  it "resolves every relative markdown link" do
    Dir.glob(File.join(root, "**/*.md")).each do |file|
      File.read(file).scan(/\]\((\.\.?\/[^)#\s]*)/).flatten.each do |link|
        expect(File.exist?(File.expand_path(link, File.dirname(file)))).to be(true), "#{file}: #{link} does not resolve"
      end
    end
  end
end
