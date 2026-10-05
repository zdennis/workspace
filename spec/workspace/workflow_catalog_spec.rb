require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowCatalog do
  around do |example|
    Dir.mktmpdir("wf-catalog") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:global_dir) { File.join(@dir, "global") }
  let(:builtin_dir) { File.join(@dir, "builtin") }
  let(:config) { instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: builtin_dir) }
  subject(:catalog) { described_class.new(config: config) }

  def write(dir, id, yaml)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.yml"), yaml)
  end

  before { write(builtin_dir, "rpiv", "title: Shipped\nsteps:\n  a:\n    prompt: P\n") }

  it "finds a preset that ships with workspace" do
    definition = catalog.find("rpiv")

    expect([definition.source, definition.path, definition.to_h["title"]]).to eq(["builtin", File.join(builtin_dir, "rpiv.yml"), "Shipped"])
  end

  it "prefers the user's file of the same id" do
    write(global_dir, "rpiv", "title: Mine\nsteps:\n  a:\n    prompt: P\n")

    expect(catalog.find("rpiv").source).to eq("global")
    expect(catalog.find("rpiv").to_h["title"]).to eq("Mine")
  end

  it "raises unknown_workflow, naming the ids it has" do
    write(global_dir, "ship", "steps:\n  a:\n    prompt: P\n")

    expect { catalog.find("nope") }.to raise_error(Workspace::Error, 'No workflow named "nope". Known: rpiv, ship.') { |error|
      expect(error.code).to eq("unknown_workflow")
      expect(error.details).to eq("workflow" => "nope", "known" => %w[rpiv ship])
    }
  end

  it "does not look outside its directories for an id that is a path" do
    write(@dir, "outside", "steps:\n  a:\n    prompt: P\n")

    expect { catalog.find("../outside") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_workflow") }
  end

  it "raises invalid_workflow for a file that doesn't pass the checks" do
    write(global_dir, "bad", "steps: {}\n")

    expect { catalog.find("bad") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("invalid_workflow") }
  end

  it "lists every definition by id, a user's file hiding the preset, and an invalid file with its problems" do
    write(global_dir, "rpiv", "title: Mine\ndescription: My copy.\nsteps:\n  a:\n    prompt: P\n")
    write(global_dir, "bad", "steps: {}\n")
    write(builtin_dir, "ship", "steps:\n  a:\n    prompt: P\n")

    list = catalog.list

    expect(list.map { |entry| entry.values_at("id", "source", "title") }).to eq([%w[bad global bad], %w[rpiv global Mine], %w[ship builtin ship]])
    expect(list[0]).to include("problems" => ["steps must be a mapping of step id to step, with at least one step"], "sha256" => nil)
    expect(list[1]).to include("description" => "My copy.", "path" => File.join(global_dir, "rpiv.yml"), "problems" => [])
    expect(list[1]["sha256"]).to match(/\A\h{64}\z/)
  end

  it "lists an entry that can't be a definition with why, beside the valid ones, and no id finds it" do
    write(global_dir, "Bad", "steps:\n  a:\n    prompt: P\n")
    write(global_dir, "rpiv.v2", "steps:\n  a:\n    prompt: P\n")
    FileUtils.mkdir_p(File.join(global_dir, "dir.yml"))

    list = catalog.list

    name_problem = "the file's name must be a workflow id: lowercase letters, digits, '-' and '_', at most 40 characters"
    expect(list.map { |entry| entry.values_at("id", "source", "problems") }).to eq([
      ["Bad", "global", [name_problem]],
      ["dir", "global", ["#{File.join(global_dir, "dir.yml")} is not a file"]],
      ["rpiv", "builtin", []],
      ["rpiv.v2", "global", [name_problem]]
    ])
    expect(list.first).to include("path" => File.join(global_dir, "Bad.yml"), "sha256" => nil, "title" => "Bad")
    expect { catalog.find("Bad") }.to raise_error(Workspace::Error, 'No workflow named "Bad". Known: rpiv.') { |error|
      expect(error.details).to eq("workflow" => "Bad", "known" => ["rpiv"])
    }
    expect { catalog.find("dir") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_workflow") }
  end

  it "lists a link to a file that is gone with why, and does not find it" do
    FileUtils.mkdir_p(global_dir)
    File.symlink(File.join(@dir, "nowhere.yml"), File.join(global_dir, "mine.yml"))

    entry = catalog.list.find { |each| each["id"] == "mine" }

    expect(entry).to eq("id" => "mine", "title" => "mine", "description" => nil, "source" => "global", "path" => File.join(global_dir, "mine.yml"),
      "sha256" => nil, "problems" => ["#{File.join(global_dir, "mine.yml")} is a link to a file that is not there"])
    expect { catalog.find("mine") }.to raise_error(Workspace::Error, 'No workflow named "mine". Known: rpiv.')
  end

  it "says a link to a directory is not a file, and skips an entry removed since the directory was listed" do
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    FileUtils.mkdir_p(global_dir)
    File.symlink(File.join(@dir, "elsewhere"), File.join(global_dir, "linked.yml"))
    allow(Dir).to receive(:glob).and_call_original
    allow(Dir).to receive(:glob).with(File.join(global_dir, "*.yml")).and_return([File.join(global_dir, "linked.yml"), File.join(global_dir, "vanished.yml")])

    list = catalog.list

    expect(list.map { |entry| entry["id"] }).to eq(%w[linked rpiv])
    expect(list.first["problems"]).to eq(["#{File.join(global_dir, "linked.yml")} is not a file"])
  end

  it "finds and lists a definition holding non-ASCII text from a process with no UTF-8 locale" do
    FileUtils.mkdir_p(global_dir)
    File.write(File.join(global_dir, "cafe.yml"), "title: Café\nsteps:\n  a:\n    prompt: Écris.\n", encoding: "UTF-8")

    without_utf8_locale do
      expect(catalog.find("cafe").to_h["title"]).to eq("Café")
      expect(catalog.list.find { |entry| entry["id"] == "cafe" }).to include("title" => "Café", "problems" => [])
    end
  end

  it "lists nothing when neither directory exists" do
    FileUtils.rm_rf(builtin_dir)

    expect(catalog.list).to eq([])
  end

  describe "the rpiv preset that ships" do
    let(:config) { Workspace::Config.new }

    it "is valid: research, plan (gated), implement, verify (checked with the project's test command, back to implement)" do
      allow(config).to receive(:workflows_dir).and_return(global_dir)
      definition = catalog.find("rpiv")
      steps = definition.steps

      expect(definition.source).to eq("builtin")
      expect(definition.to_h["inputs"].transform_values { |input| input["required"] }).to eq("task" => true, "spec" => false)
      expect(steps.map { |step| step["id"] }).to eq(%w[research plan implement verify])
      expect(steps.map { |step| step["produces"] }).to eq([["research.md"], ["plan.md"], ["implement.md"], ["verify.md"]])
      expect(steps[1]["gate"]).to eq("approve")
      # Room for four steps, one rejected plan and all three trips back from verify.
      expect(definition.to_h["max_attempts"]).to be >= 4 + 1 + 2 * steps[3]["on_fail"]["max"] - 1
      expect(steps[3]).to include("uses" => ["test-db"], "status" => {"command" => "test", "timeout" => 1200},
        "on_fail" => {"goto" => "implement", "max" => 3, "context" => "continue"}, "include" => ["review"])
    end
  end
end
