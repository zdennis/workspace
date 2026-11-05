require "spec_helper"

RSpec.describe Workspace::WorkflowLint do
  let(:library) { instance_double(Workspace::Library) }
  let(:commands_config) { instance_double(Workspace::CommandsConfig) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:workflow_config) { instance_double(Workspace::WorkflowConfig, default_packs: %w[commits]) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, existing_name: "proj") }
  let(:git_common_dir) { "/repo/.git" }
  subject(:lint) { described_class.new(library: library, commands_config: commands_config, lineage: lineage, workflow_config: workflow_config, project_config: project_config) }

  before do
    allow(lineage).to receive(:resolve).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "proj", path: "/repo", git_common_dir: git_common_dir, is_worktree: false))
    allow(library).to receive(:pack) do |ref, cwd:|
      raise Workspace::UsageError, "bad pack name #{ref}" if ref.match?(/[\/{ ]/)
      (ref == "commits") ? [{}, ""] : raise(Workspace::Error.new("No library entry 'play/#{ref}'", code: "unknown_library_entry"))
    end
    allow(commands_config).to receive(:for_project).with("proj").and_return({test: nil, lint: "rubocop"})
  end

  def definition(yaml) = Workspace::WorkflowDefinition.parse(yaml, id: "demo", source: "file", path: "/d/demo.yml")

  let(:yaml) do
    <<~YAML
      include: [wide]
      steps:
        a:
          prompt: P
          include: [commits, nope]
          status: {command: test}
        b:
          prompt: Q
          include: [later]
          require: [{command: lint}]
        c:
          prompt: R
          require: [{command: test, optional: true}]
    YAML
  end

  it "warns of unknown packs and an unset command inside a project, naming each step" do
    found = lint.call(definition(yaml), cwd: "/repo")
    expect(found["warnings"].map { |w| [w["code"], w["step"]] }).to eq([["unknown_pack", nil], ["unknown_pack", "a"], ["unknown_pack", "b"], ["command_unset", "a"]])
    expect(found["warnings"][1]["message"]).to match(/step a includes pack nope.*proj.*`start` would refuse it/)
    expect(found["not_checked"]).to eq([])
    expect(library).to have_received(:pack).with("commits", cwd: "/repo").at_least(:once)
  end

  it "says a pack missing on a later step stops the run there, since start reads only the first step" do
    message = lint.call(definition(yaml), cwd: "/repo")["warnings"].find { |w| w["step"] == "b" }["message"]
    expect(message).to match(/`start` passes.*stop when it reaches step b \(step 2 of 3\)/)
  end

  it "warns once for a pack the first step also names, with no contradicting later-step text" do
    text = "steps:\n  a:\n    prompt: P\n    gate: approve\n    include: [nope]\n  b:\n    prompt: Q\n    gate: approve\n    include: [nope]\n"
    found = lint.call(definition(text), cwd: "/repo")["warnings"]
    expect(found).to match([include("step" => "a", "message" => /`start` would refuse it/)])
  end

  it "checks the default packs every step gets" do
    allow(workflow_config).to receive(:default_packs).with(workspace: "proj").and_return(%w[commits gone])
    found = lint.call(definition("steps:\n  a:\n    prompt: P\n    gate: approve\n"), cwd: "/repo")
    expect(found["warnings"]).to match([include("code" => "unknown_pack", "step" => nil, "message" => /workflows.defaults.include.*every step.*gone.*`start` would refuse it/)])
  end

  it "gives a hint that works when the project is not a workspace" do
    allow(project_config).to receive(:existing_name).and_return(nil)
    message = lint.call(definition(yaml), cwd: "/repo")["warnings"].find { |w| w["code"] == "command_unset" }["message"]
    expect(message).to include("not a workspace yet", "run `workspace add .`", "`workspace config set commands.test \"COMMAND\"`").and(satisfy { |m| !m.include?("--scope") })
  end

  it "names the workspace in the hint when the project is one" do
    message = lint.call(definition(yaml), cwd: "/repo")["warnings"].find { |w| w["code"] == "command_unset" }["message"]
    expect(message).to include("config set commands.test \"COMMAND\" --name proj")
  end

  it "raises nothing for a definition that uses no pack and no command" do
    found = lint.call(definition("steps:\n  a:\n    prompt: P\n    gate: approve\n"), cwd: "/repo")
    expect(found).to eq({"warnings" => [], "not_checked" => []})
  end

  context "outside a git checkout" do
    let(:git_common_dir) { nil }

    it "searches only the built-in and global library and lists what it could not check" do
      found = lint.call(definition(yaml), cwd: "/tmp/x")
      expect(found["warnings"]).to eq([])
      expect(found["not_checked"].map { |n| [n["code"], n["step"]] }).to eq([["pack_not_checked", nil], ["pack_not_checked", "a"], ["pack_not_checked", "b"], ["commands_not_checked", nil]])
      expect(library).to have_received(:pack).with("wide", cwd: nil)
      expect(commands_config).not_to have_received(:for_project)
    end

    it "still warns of a pack name that is invalid everywhere" do
      found = lint.call(definition("include: [\"{{task}}\"]\nsteps:\n  a:\n    prompt: P\n    gate: approve\n"), cwd: "/tmp/x")
      expect(found["warnings"]).to match([include("code" => "unknown_pack", "message" => /not a valid pack name/)])
      expect(found["not_checked"]).to eq([])
    end

    it "lists no commands_not_checked for a definition that uses no command" do
      found = lint.call(definition("steps:\n  a:\n    prompt: P\n    gate: approve\n"), cwd: "/tmp/x")
      expect(found["not_checked"]).to eq([])
    end

    it "names a command once however many steps use it" do
      found = lint.call(definition("steps:\n  a:\n    prompt: P\n    status: {command: test}\n  b:\n    prompt: Q\n    status: {command: test}\n"), cwd: "/tmp/x")
      expect(found["not_checked"]).to match([include("code" => "commands_not_checked", "message" => /project's test command, which/)])
    end
  end

  describe "require: exec" do
    def exec_def(*lines)
      body = lines.map { |l| "          - exec: #{l.inspect}\n" }.join
      definition("steps:\n  a:\n    prompt: P\n    require:\n#{body}")
    end

    before { allow(commands_config).to receive(:test_files).with("proj").and_return(["spec/**/*_spec.rb"]) }

    it "warns of a bare program not on PATH and clears for one that is" do
      found = lint.call(exec_def("no-such-program-xyz --flag"), cwd: "/repo")
      expect(found["warnings"]).to match([include("code" => "exec_program_missing", "step" => "a", "message" => /no-such-program-xyz.*is not on PATH.*daemon's PATH/)])
      expect(lint.call(exec_def("ls -l"), cwd: "/repo")["warnings"]).to eq([])
    end

    it "resolves a relative program against the checkout" do
      Dir.mktmpdir do |dir|
        allow(lineage).to receive(:resolve).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "proj", path: dir, git_common_dir: "#{dir}/.git", is_worktree: false))
        expect(lint.call(exec_def("script/check"), cwd: dir)["warnings"]).to match([include("code" => "exec_program_missing", "message" => /does not exist/)])
        FileUtils.mkdir_p("#{dir}/script")
        File.write("#{dir}/script/check", "#!/bin/sh\n")
        File.chmod(0o755, "#{dir}/script/check")
        expect(lint.call(exec_def("script/check"), cwd: dir)["warnings"]).to eq([])
      end
    end

    it "warns of a list with no -- before it and clears with one" do
      found = lint.call(exec_def("ls {{changed.files}}"), cwd: "/repo")
      expect(found["warnings"]).to match([include("code" => "exec_list_without_dashes", "step" => "a", "message" => /step a exec ls: .*changed.files.*Put `--`/)])
      expect(lint.call(exec_def("ls -- {{changed.files}}"), cwd: "/repo")["warnings"]).to eq([])
    end

    it "warns when {{changed.tests}} is used and test_files is unset, naming the workspace, and clears when set" do
      allow(commands_config).to receive(:test_files).with("proj").and_return([])
      found = lint.call(exec_def("ls -- {{changed.tests}}"), cwd: "/repo")
      expect(found["warnings"]).to match([include("code" => "test_files_unset", "message" => /--name proj/)])
      allow(commands_config).to receive(:test_files).with("proj").and_return(["a"])
      expect(lint.call(exec_def("ls -- {{changed.tests}}"), cwd: "/repo")["warnings"]).to eq([])
    end

    it "does not read test_files when no step uses {{changed.tests}}" do
      lint.call(exec_def("ls -- {{changed.files}}"), cwd: "/repo")
      expect(commands_config).not_to have_received(:test_files)
    end

    it "lists test_files as not checked when commands.test_files cannot be parsed" do
      allow(commands_config).to receive(:test_files).and_raise(Workspace::ConfigParseError.new("/c.yml", "bad yaml"))
      found = lint.call(exec_def("ls -- {{changed.tests}}"), cwd: "/repo")
      expect(found["not_checked"]).to match([include("code" => "test_files_not_checked", "step" => nil, "message" => /commands.test_files could not be read.*bad yaml/)])
    end

    context "outside a git checkout" do
      let(:git_common_dir) { nil }

      it "lists a relative program and test_files as not checked, and still judges bare programs and lists" do
        found = lint.call(exec_def("script/check -- {{changed.tests}}", "no-such-program-xyz", "ls {{changed.files}}"), cwd: "/tmp/x")
        expect(found["not_checked"].map { |n| n["code"] }).to eq(%w[exec_program_not_checked test_files_not_checked])
        expect(found["warnings"].map { |w| w["code"] }).to eq(%w[exec_program_missing exec_list_without_dashes])
        expect(commands_config).not_to have_received(:test_files)
      end
    end
  end

  it "lists an unreadable config as not checked" do
    allow(commands_config).to receive(:for_project).and_raise(Workspace::ConfigParseError.new("/c.yml", "bad yaml"))
    found = lint.call(definition(yaml), cwd: "/repo")
    expect(found["not_checked"]).to match([include("code" => "commands_not_checked", "message" => /bad yaml/)])
  end
end
