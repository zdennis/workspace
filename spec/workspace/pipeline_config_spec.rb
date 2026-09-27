require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::PipelineConfig do
  let(:tmpdir) { Dir.mktmpdir("ws-pipeline-config") }
  let(:path) { File.join(tmpdir, "myapp.yml") }
  let(:config) { instance_double(Workspace::Config, project_config_path: path) }

  subject(:pipeline_config) { described_class.new(config: config) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def write(yaml)
    File.write(path, yaml)
  end

  it "maps each pane to a stage by position" do
    write(<<~YAML)
      pipeline:
        panes:
          - role: researcher
          - role: implementer
    YAML

    expect(pipeline_config.stages_for("myapp")).to eq([
      {role: "researcher", pane_index: 0, timeout: nil},
      {role: "implementer", pane_index: 1, timeout: nil}
    ])
  end

  it "reads a per-stage timeout as seconds" do
    write(<<~YAML)
      pipeline:
        panes:
          - role: researcher
            timeout: 30m
          - role: implementer
            timeout: 90
    YAML

    expect(pipeline_config.stages_for("myapp").map { |stage| stage[:timeout] }).to eq([1800.0, 90.0])
  end

  it "names the stage and the file when a timeout is not a duration" do
    write(<<~YAML)
      pipeline:
        panes:
          - role: researcher
          - role: implementer
            timeout: soon
    YAML

    expect { pipeline_config.stages_for("myapp") }
      .to raise_error(Workspace::Error, /pipeline\.panes\[1\]\.timeout in #{Regexp.escape(path)}/)
  end

  it "refuses a zero timeout rather than failing every stage at once" do
    write(<<~YAML)
      pipeline:
        panes:
          - role: researcher
            timeout: 0
    YAML

    expect { pipeline_config.stages_for("myapp") }.to raise_error(Workspace::Error, /greater than 0/)
  end

  it "has no pipeline when the project file is missing" do
    expect(pipeline_config.stages_for("myapp")).to be_nil
    expect(pipeline_config.pipeline?("myapp")).to be(false)
  end

  it "refuses a stage that names the bare completion sentinel in its own text" do
    write(<<~YAML)
      pipeline:
        panes:
          - role: "implementer: print WORKSPACE_DONE: when finished"
    YAML

    expect { pipeline_config.stages_for("myapp") }
      .to raise_error(Workspace::Error, /pipeline\.panes\[0\]\.role in #{Regexp.escape(path)}.*bare WORKSPACE_DONE: marker/)
  end

  it "accepts a stage whose text mentions the sentinel with a token glued to it" do
    write(<<~YAML)
      pipeline:
        panes:
          - role: "researcher (echoes WORKSPACE_DONE:abc123 itself)"
    YAML

    expect { pipeline_config.stages_for("myapp") }.not_to raise_error
  end

  describe "#declared_but_empty?" do
    it "is true when the pipeline block has no panes" do
      write(<<~YAML)
        pipeline: {}
      YAML

      expect(pipeline_config.declared_but_empty?("myapp")).to be(true)
    end

    it "is true when panes is an empty list" do
      write(<<~YAML)
        pipeline:
          panes: []
      YAML

      expect(pipeline_config.declared_but_empty?("myapp")).to be(true)
    end

    it "is false when the pipeline has stages" do
      write(<<~YAML)
        pipeline:
          panes:
            - role: researcher
      YAML

      expect(pipeline_config.declared_but_empty?("myapp")).to be(false)
    end

    it "is false when there is no pipeline block" do
      write(<<~YAML)
        root: /tmp
      YAML

      expect(pipeline_config.declared_but_empty?("myapp")).to be(false)
    end

    it "is false when the project file is missing" do
      expect(pipeline_config.declared_but_empty?("myapp")).to be(false)
    end
  end
end
