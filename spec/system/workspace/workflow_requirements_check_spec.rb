require "spec_helper"
require "tmpdir"
require "open3"
require "json"
require "rbconfig"

RSpec.describe "the plan step's requirements check in the shipped presets" do
  let(:config) { Workspace::Config.new }
  let(:dir) { Dir.mktmpdir }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }
  let(:artifacts) { File.join(dir, "artifacts").tap { |path| FileUtils.mkdir_p(path) } }
  let(:bin) { File.join(dir, "bin").tap { |path| FileUtils.mkdir_p(path) } }
  let(:home) { File.join(dir, "home").tap { |path| FileUtils.mkdir_p(path) } }
  let(:checkout) { File.join(home, "app").tap { |path| FileUtils.mkdir_p(path) } }
  let(:notes) { File.join(checkout, "tmp", "workspace-notes").tap { |path| FileUtils.mkdir_p(path) } }
  let(:plan_path) { File.join(notes, "IMPLEMENTATION_PLAN.md") }

  before do
    allow(config).to receive(:workflows_dir).and_return(File.join(dir, "none"))
    FileUtils.mkdir_p(File.join(home, ".config", "tmuxinator"))
    File.write(File.join(home, ".config", "tmuxinator", "workspace.app.yml"), "name: app\nroot: #{checkout}\nwindows: []\n")
    File.write(File.join(checkout, ".workspace-project"), "app\n")
    File.symlink(RbConfig.ruby, File.join(bin, "ruby"))
  end

  after { FileUtils.remove_entry(dir) }

  def plan_check(id)
    definition = (id == "deliver-goal") ? deliver_goal : catalog.find(id).to_h
    definition["steps"].find { |step| step["id"] == "plan" }["status"]["run"]
  end

  def deliver_goal
    path = File.join(PROJECT_ROOT, "demo", "calculator2", "workflows", "deliver-goal.yml")
    lookup = lambda do |id, below: nil|
      file = File.join(PROJECT_ROOT, "lib", "workflows", "#{id}.yml")
      {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file) && below.nil?
    end
    Workspace::WorkflowDefinition.parse(File.read(path), id: "deliver-goal", source: "global", path: path, parent_lookup: lookup).to_h
  end

  def write_plan(details)
    write_plan_file(<<~MD)
      # Title

      ## Tasks

      - [ ] T1 First R9
      - [ ] T2 Second

      ## Task details

      #{details}

      ## Notes

      R2 R3
    MD
  end

  def write_plan_file(text)
    File.write(plan_path, text)
    stub_status(exists: true, total: text.scan(/^- \[.\] T\d+/).size)
  end

  def stub_status(exists:, total:)
    status = {"schema_version" => 1, "plans" => [{"path" => plan_path, "exists" => exists, "counts" => {"total" => total}}]}
    File.write(File.join(dir, "status.json"), JSON.generate(status))
  end

  def install_workspace(id)
    stand_in = File.join(bin, "workspace")
    script = if id == "deliver-goal"
      "#!/bin/sh\ncat '#{File.join(dir, "status.json")}'\n"
    else
      "#!/bin/sh\nexec '#{RbConfig.ruby}' '#{File.join(PROJECT_ROOT, "bin", "workspace")}' \"$@\"\n"
    end
    File.write(stand_in, script)
    File.chmod(0o755, stand_in)
  end

  def run_check(id)
    install_workspace(id)
    env = {"PATH" => "#{bin}:#{ENV.fetch("PATH")}", "HOME" => home, "TMPDIR" => home, "WORKSPACE_RUN_ARTIFACTS" => artifacts,
           "TMUX" => nil, "TMUX_PANE" => nil, "XDG_CONFIG_HOME" => nil, "XDG_STATE_HOME" => nil}
    Open3.capture3(env, "sh", "-c", plan_check(id), chdir: checkout)
  end

  %w[rpiv rpiv-auto-approve-v2 rpiv-auto-approve deliver-goal].each do |id|
    context "in #{id}" do
      before { File.write(File.join(artifacts, "requirements.md"), "R1 Export a PDF\nR2 Name it by date\nR3 Keep the old CSV\n\nNo ambiguity.\n") }

      it "fails and names each R that no task in Task details covers" do
        write_plan("### T1 First\n\nCovers R1.\n\n### T2 Second\n\nCovers R10.")

        _out, err, status = run_check(id)

        expect([status.exitstatus, err]).to eq([1, "In no task of ## Task details: R2 R3\n"])
      end

      it "does not take R10 in a task for R1" do
        File.write(File.join(artifacts, "requirements.md"), "R1 Export a PDF\n")
        write_plan("### T1 First\n\nCovers R10.")

        _out, err, status = run_check(id)

        expect([status.exitstatus, err]).to eq([1, "In no task of ## Task details: R1\n"])
      end

      it "lists every R when the plan has no Task details section" do
        write_plan_file("# Title\n\n## Tasks\n\n- [ ] T1 First R1 R2 R3\n")

        _out, err, status = run_check(id)

        expect([status.exitstatus, err]).to eq([1, "In no task of ## Task details: R1 R2 R3\n"])
      end

      it "reads a plan and a requirements.md with CRLF line endings" do
        File.write(File.join(artifacts, "requirements.md"), "R1 Export a PDF\r\nR2 Name it by date\r\nR3 Keep the old CSV\r\n")
        write_plan("### T1 First\n\nCovers R1, R3.\n\n### T2 Second\n\nCovers R2.")
        write_plan_file(File.read(plan_path).gsub("\n", "\r\n"))

        _out, err, status = run_check(id)

        expect([status.exitstatus, err]).to eq([0, ""])
      end

      it "fails a CRLF plan that leaves an R uncovered" do
        File.write(File.join(artifacts, "requirements.md"), "R1 Export a PDF\r\nR2 Name it by date\r\n")
        write_plan("### T1 First\n\nCovers R1.")
        write_plan_file(File.read(plan_path).gsub("\n", "\r\n"))

        _out, err, status = run_check(id)

        expect([status.exitstatus, err]).to eq([1, "In no task of ## Task details: R2\n"])
      end

      it "passes a plan that names an R only to say no task covers it, since it reads numbers, not meaning" do
        write_plan("### T1 First\n\nCovers R1, R3.\n\n### T2 Second\n\nR2 is not covered here.")

        _out, err, status = run_check(id)

        expect([status.exitstatus, err]).to eq([0, ""])
      end

      it "passes when every R appears in Task details" do
        write_plan("### T1 First\n\nCovers R1, R3.\n\n### T2 Second\n\nCovers R2.")

        _out, err, status = run_check(id)

        expect([status.exitstatus, err]).to eq([0, ""])
      end
    end
  end

  it "keeps today's result when the run has no requirements.md" do
    write_plan("### T1 First\n\nNo numbers here.")

    _out, _err, status = run_check("rpiv")

    expect(status.exitstatus).to eq(0)
  end

  it "still fails a plan with no tasks before it reads requirements.md" do
    write_plan_file("# Title\n\n## Tasks\n\n## Task details\n\nR1\n")

    _out, _err, status = run_check("rpiv")

    expect(status.exitstatus).to eq(1)
  end

  %w[rpiv rpiv-auto-approve-v2 rpiv-auto-approve].each do |id|
    it "fails #{id} when the workspace has no plan" do
      File.write(File.join(artifacts, "requirements.md"), "R1 Export a PDF\n")
      FileUtils.rm_f(plan_path)

      _out, err, status = run_check(id)

      expect([status.exitstatus, err]).to eq([1, "check-ids: no plan with tasks at #{plan_path}\n"])
    end
  end
end
