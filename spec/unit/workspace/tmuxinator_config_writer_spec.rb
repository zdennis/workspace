require "tmpdir"
require "json"
require "digest"

RSpec.describe Workspace::TmuxinatorConfigWriter do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:render_dir) { File.join(tmpdir, "state", ".render") }
  let(:inputs) { {workspace_name: "myapp", project_root: "/src/myapp", task_id: nil, agent_kind: "claude", agent_command: "claude"} }
  subject(:writer) { described_class.new(config: config) }

  before do
    allow(config).to receive(:config_path_for) { |name| File.join(tmpdir, "workspace.#{name}.yml") }
    allow(config).to receive(:render_state_dir).and_return(render_dir)
  end

  after { FileUtils.remove_entry(tmpdir) }

  def path = File.join(tmpdir, "workspace.myapp.yml")

  def sidecar = JSON.parse(File.read(File.join(render_dir, "myapp.json")))

  def write(text = "name: myapp\n", **options)
    writer.write("myapp", text, kind: :project, template: "default", template_sha: "abc", inputs: inputs, **options)
  end

  describe "#write" do
    it "writes the config and a sidecar saying what it was rendered from" do
      write

      expect(File.read(path)).to eq("name: myapp\n")
      expect(sidecar).to eq(
        "schema" => 1, "kind" => "project", "template" => "default", "template_sha" => "abc",
        "inputs" => {"workspace_name" => "myapp", "project_root" => "/src/myapp", "task_id" => nil,
                     "agent_kind" => "claude", "agent_command" => "claude"},
        "rendered_sha" => Digest::SHA256.hexdigest("name: myapp\n")
      )
    end

    it "gives a new config the mode File.write gives under the umask" do
      control = File.join(tmpdir, "control")
      File.write(control, "x")

      write

      expect(File.stat(path).mode).to eq(File.stat(control).mode)
    end

    it "keeps the mode of a config that exists" do
      File.write(path, "old\n")
      File.chmod(0o640, path)

      write

      expect(File.stat(path).mode & 0o7777).to eq(0o640)
      expect(File.read(path)).to eq("name: myapp\n")
    end

    it "leaves the old file and no temp file when the write fails" do
      File.write(path, "old\n")
      allow(File).to receive(:rename).and_call_original
      allow(File).to receive(:rename).with(a_string_starting_with("#{path}."), path).and_raise(Errno::EACCES)

      expect { write }.to raise_error(Errno::EACCES)
      expect(File.read(path)).to eq("old\n")
      expect(Dir.glob("#{path}.*")).to be_empty
      expect(File.exist?(File.join(render_dir, "myapp.json"))).to be(false)
    end

    context "when the sidecar write fails after the config is written" do
      before do
        allow(Workspace::AtomicFile).to receive(:write).and_call_original
        allow(Workspace::AtomicFile).to receive(:write).with(File.join(render_dir, "myapp.json"), anything).and_raise(Errno::ENOSPC)
      end

      it "leaves the new config with no record" do
        expect { write }.to raise_error(Errno::ENOSPC)

        expect(File.read(path)).to eq("name: myapp\n")
        expect(writer.record("myapp")).to be_nil
        expect(writer.current?("myapp")).to be(false)
      end

      it "leaves the new config with the old record, which no longer matches it" do
        FileUtils.mkdir_p(render_dir)
        old = {"schema" => 1, "kind" => "project", "template" => "default", "template_sha" => "abc", "inputs" => {"workspace_name" => "myapp"}, "rendered_sha" => "old"}
        File.write(File.join(render_dir, "myapp.json"), JSON.generate(old))

        expect { write }.to raise_error(Errno::ENOSPC)

        expect(File.read(path)).to eq("name: myapp\n")
        expect(writer.record("myapp").rendered_sha).to eq("old")
        expect(writer.current?("myapp")).to be(false)
      end
    end
  end

  describe "#record" do
    it "reads the sidecar back with a Symbol kind and Symbol-keyed inputs, nil values kept" do
      write

      record = writer.record("myapp")
      expect(record.kind).to eq(:project)
      expect(record.template).to eq("default")
      expect(record.template_sha).to eq("abc")
      expect(record.inputs).to eq(inputs)
      expect(record.rendered_sha).to eq(Digest::SHA256.hexdigest("name: myapp\n"))
    end

    it "is nil with no sidecar" do
      expect(writer.record("myapp")).to be_nil
    end

    it "is nil for a corrupt sidecar, one of another schema, or one whose inputs are not an object" do
      FileUtils.mkdir_p(render_dir)
      sidecar_path = File.join(render_dir, "myapp.json")

      good = {"schema" => 1, "kind" => "project", "template" => "default", "template_sha" => "abc", "inputs" => {"workspace_name" => "myapp"}, "rendered_sha" => "def"}
      File.write(sidecar_path, JSON.generate(good))
      expect(writer.record("myapp")).not_to be_nil

      bad = ["{not json", "[]"] + [
        {"schema" => 2}, {"inputs" => []}, {"kind" => "other"}, {"kind" => nil},
        {"template" => 1}, {"template_sha" => nil}, {"rendered_sha" => ["x"]}
      ].map { |change| JSON.generate(good.merge(change)) }
      bad.each do |text|
        File.write(sidecar_path, text)
        expect(writer.record("myapp")).to be_nil, text
      end
    end

    it "is nil for a sidecar that can't be read" do
      FileUtils.mkdir_p(File.join(render_dir, "myapp.json"))

      expect(writer.record("myapp")).to be_nil
    end

    it "is nil for a sidecar whose inputs name another workspace, as a rename stopped part way leaves one" do
      write
      FileUtils.mv(File.join(render_dir, "myapp.json"), File.join(render_dir, "other.json"))

      expect(writer.record("other")).to be_nil
    end
  end

  describe "#carry_record" do
    def moved
      FileUtils.mv(File.join(render_dir, "myapp.json"), File.join(render_dir, "other.json"))
    end

    def carry(before: "name: myapp\n", after: "name: other\n")
      writer.carry_record("other", from: "myapp", before: before, after: after) { |given| given.merge(workspace_name: "other") }
    end

    it "rewrites the inputs of a moved sidecar and follows a config that was current" do
      write
      moved

      expect(carry).to be(true)
      record = writer.record("other")
      expect(record.inputs).to eq(inputs.merge(workspace_name: "other"))
      expect(record.rendered_sha).to eq(Digest::SHA256.hexdigest("name: other\n"))
      expect(record.template_sha).to eq("abc")
    end

    it "keeps the old rendered_sha of a config edited by hand" do
      write
      moved

      carry(before: "name: myapp\n# mine\n")

      expect(writer.record("other").rendered_sha).to eq(Digest::SHA256.hexdigest("name: myapp\n"))
    end

    it "leaves a sidecar already carried, or none, alone" do
      expect(carry).to be(false)

      write
      moved
      carry
      written = File.read(File.join(render_dir, "other.json"))

      expect(carry(before: "name: other\n", after: "name: other\n")).to be(false)
      expect(File.read(File.join(render_dir, "other.json"))).to eq(written)
    end
  end

  describe "#remove_record" do
    it "deletes the sidecar and is quiet with none" do
      write

      writer.remove_record("myapp")
      writer.remove_record("myapp")

      expect(File.exist?(File.join(render_dir, "myapp.json"))).to be(false)
    end

    it "leaves a sidecar listed under another case of the name" do
      writer.write("MyApp", "name: MyApp\n", kind: :project, template: "default", template_sha: "abc", inputs: inputs.merge(workspace_name: "MyApp"))

      writer.remove_record("myapp")

      expect(Dir.children(render_dir)).to eq(["MyApp.json"])
    end
  end

  describe "#patch" do
    it "rewrites the config, refreshes rendered_sha and merges the inputs given" do
      write

      result = writer.patch("myapp", inputs: {agent_command: "claude-dev"}) { |text| text.sub("myapp", "other") }

      expect(result).to eq("name: other\n")
      expect(File.read(path)).to eq("name: other\n")
      record = writer.record("myapp")
      expect(record.rendered_sha).to eq(Digest::SHA256.hexdigest("name: other\n"))
      expect(record.inputs).to eq(inputs.merge(agent_command: "claude-dev"))
      expect(record.template_sha).to eq("abc")
      expect(writer.current?("myapp")).to be(true)
    end

    it "takes inputs from a callable given the new text" do
      write

      writer.patch("myapp", inputs: ->(text) { {agent_command: text.strip} }) { "new\n" }

      expect(writer.record("myapp").inputs).to include(agent_command: "new")
    end

    it "keeps the config's mode" do
      write
      File.chmod(0o640, path)

      writer.patch("myapp") { |text| "#{text}# more\n" }

      expect(File.stat(path).mode & 0o7777).to eq(0o640)
    end

    it "writes the config alone when there is no sidecar" do
      File.write(path, "old\n")

      writer.patch("myapp") { "new\n" }

      expect(File.read(path)).to eq("new\n")
      expect(File.exist?(render_dir)).to be(false)
    end

    it "writes the config alone and leaves a corrupt sidecar as it is" do
      write
      sidecar_path = File.join(render_dir, "myapp.json")
      File.write(sidecar_path, "{not json")

      writer.patch("myapp") { "new\n" }

      expect(File.read(path)).to eq("new\n")
      expect(File.read(sidecar_path)).to eq("{not json")
      expect(writer.current?("myapp")).to be(false)
    end

    it "writes nothing when the block returns nil" do
      write

      expect(writer.patch("myapp") { nil }).to be_nil
      expect(File.read(path)).to eq("name: myapp\n")
    end
  end

  describe "#current?" do
    it "is true for the file as written and false once it is edited" do
      write
      expect(writer.current?("myapp")).to be(true)

      File.write(path, "name: edited\n")
      expect(writer.current?("myapp")).to be(false)
    end

    it "is false with no sidecar or no config" do
      File.write(path, "name: myapp\n")
      expect(writer.current?("myapp")).to be(false)

      write
      File.delete(path)
      expect(writer.current?("myapp")).to be(false)
    end
  end
end
