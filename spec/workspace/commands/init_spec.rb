require "tmpdir"

RSpec.describe Workspace::Commands::Init do
  let(:tmpdir) { Dir.mktmpdir }
  let(:workspace_dir) { File.join(tmpdir, "workspace") }
  let(:tmuxinator_dir) { File.join(tmpdir, "tmuxinator") }
  let(:workspace_config_dir) { File.join(tmpdir, "workspace_config") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:config) { Workspace::Config.new(workspace_dir: workspace_dir) }

  subject(:command) do
    described_class.new(config: config, output: output, error_output: error_output)
  end

  before do
    allow(config).to receive(:tmuxinator_dir).and_return(tmuxinator_dir)
    allow(config).to receive(:workspace_config_dir).and_return(workspace_config_dir)
  end

  after { FileUtils.remove_entry(tmpdir) }

  def create_source_templates
    templates_dir = config.templates_dir
    FileUtils.mkdir_p(templates_dir)
    Workspace::Commands::Init::TEMPLATES.each do |template|
      File.write(File.join(templates_dir, template), "#{template} content")
    end
  end

  describe "#call" do
    context "fresh install" do
      it "creates tmuxinator dir and copies templates" do
        create_source_templates

        command.call

        Workspace::Commands::Init::TEMPLATES.each do |template|
          dest = File.join(tmuxinator_dir, template)
          expect(File.exist?(dest)).to be true
          expect(File.read(dest)).to eq("#{template} content")
        end
        expect(output.string).to include("create  #{tmuxinator_dir}")
        expect(output.string).to include("copy    workspace.project-template.yml")
        expect(output.string).to include("Done! Workspace is ready to use.")
      end

      it "creates workspace config dir, projects dir, and global config" do
        create_source_templates

        command.call

        expect(File.directory?(workspace_config_dir)).to be true
        expect(File.directory?(File.join(workspace_config_dir, "projects"))).to be true

        config_path = File.join(workspace_config_dir, "config.yml")
        expect(File.exist?(config_path)).to be true
        data = YAML.safe_load_file(config_path)
        expect(data).to eq({"hooks" => {}, "layouts" => {}})
      end
    end

    context "when tmuxinator dir already exists" do
      it "reports exists instead of create" do
        create_source_templates
        FileUtils.mkdir_p(tmuxinator_dir)

        command.call

        expect(output.string).to include("exists  #{tmuxinator_dir}")
        expect(output.string).not_to include("create  #{tmuxinator_dir}")
      end
    end

    context "when workspace config dir and global config already exist" do
      it "reports exists and skips config.yml" do
        create_source_templates
        FileUtils.mkdir_p(File.join(workspace_config_dir, "projects"))
        File.write(File.join(workspace_config_dir, "config.yml"), YAML.dump({"hooks" => {}}))

        command.call

        expect(output.string).to include("exists  #{workspace_config_dir}")
        expect(output.string).to include("exists  #{File.join(workspace_config_dir, "projects")}")
        expect(output.string).to include("skip    config.yml (already exists)")
      end
    end

    context "when templates already exist and are identical" do
      it "skips them" do
        create_source_templates
        FileUtils.mkdir_p(tmuxinator_dir)
        Workspace::Commands::Init::TEMPLATES.each do |template|
          FileUtils.cp(File.join(config.templates_dir, template), File.join(tmuxinator_dir, template))
        end

        command.call

        expect(output.string).to include("skip    workspace.project-template.yml (already up to date)")
      end
    end

    context "when templates already exist and differ" do
      it "skips without --force" do
        create_source_templates
        FileUtils.mkdir_p(tmuxinator_dir)
        File.write(File.join(tmuxinator_dir, "workspace.project-template.yml"), "old content")

        command.call

        expect(output.string).to include("skip    workspace.project-template.yml (already exists, use --force to overwrite)")
        expect(File.read(File.join(tmuxinator_dir, "workspace.project-template.yml"))).to eq("old content")
      end

      it "overwrites with --force" do
        create_source_templates
        FileUtils.mkdir_p(tmuxinator_dir)
        File.write(File.join(tmuxinator_dir, "workspace.project-template.yml"), "old content")

        command.call(force: true)

        expect(output.string).to include("update  workspace.project-template.yml")
        expect(File.read(File.join(tmuxinator_dir, "workspace.project-template.yml"))).to eq("workspace.project-template.yml content")
      end
    end

    context "with --dry-run" do
      it "does not create directories or copy files" do
        create_source_templates

        command.call(dry_run: true)

        expect(File.directory?(tmuxinator_dir)).to be false
        expect(File.directory?(workspace_config_dir)).to be false
        expect(output.string).to include("workspace init (dry run)")
        expect(output.string).to include("create  #{tmuxinator_dir}")
        expect(output.string).to include("copy    workspace.project-template.yml")
        expect(output.string).to include("create  #{workspace_config_dir}")
        expect(output.string).to include("create  config.yml")
        expect(output.string).to include("No changes made (dry run).")
      end

      it "does not overwrite with --force and --dry-run" do
        create_source_templates
        FileUtils.mkdir_p(tmuxinator_dir)
        File.write(File.join(tmuxinator_dir, "workspace.project-template.yml"), "old content")

        command.call(dry_run: true, force: true)

        expect(File.read(File.join(tmuxinator_dir, "workspace.project-template.yml"))).to eq("old content")
        expect(output.string).to include("update  workspace.project-template.yml")
      end
    end

    context "when source template is missing" do
      it "reports error and continues" do
        templates_dir = config.templates_dir
        FileUtils.mkdir_p(templates_dir)
        File.write(File.join(templates_dir, "workspace.project-worktree-template.yml"), "content")

        command.call

        expect(error_output.string).to include("error   workspace.project-template.yml not found")
        expect(output.string).to include("copy    workspace.project-worktree-template.yml")
      end
    end
  end
end
