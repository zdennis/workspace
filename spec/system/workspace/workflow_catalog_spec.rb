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
  let(:config) do
    instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: builtin_dir, workspace_projects_dir: File.join(@dir, "projects")).tap do |double|
      allow(double).to receive(:project_workflows_dir) { |name| Workspace::Config::PROJECT_DIR_NAME.match?(name) ? File.join(@dir, "projects", name, "workflows") : nil }
    end
  end
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

  describe "project scope" do
    let(:project_dir) { File.join(@dir, "projects", "app", "workflows") }
    let(:yaml) { "title: Team\nsteps:\n  a:\n    prompt: P\n" }

    it "finds a project's file before the user's and the preset" do
      write(project_dir, "rpiv", yaml)
      write(global_dir, "rpiv", "title: Mine\nsteps:\n  a:\n    prompt: P\n")

      expect(catalog.find("rpiv", project: "app").source).to eq("project")
      expect(catalog.find("rpiv", project: "app").to_h["title"]).to eq("Team")
      expect(catalog.find("rpiv", project: "other").source).to eq("global")
      expect(catalog.find("rpiv").source).to eq("global")
    end

    it "lists one row per id, the project's winning and naming the project" do
      write(project_dir, "rpiv", yaml)
      write(project_dir, "team", yaml)

      rows = catalog.list(project: "app").to_h { |row| [row["id"], row.values_at("source", "project")] }
      expect(rows).to eq("rpiv" => %w[project app], "team" => %w[project app])
      expect(catalog.list.map { |row| row["id"] }).to eq(%w[rpiv])
      expect(catalog.list.first["project"]).to be_nil
    end

    it "does not know a project's id from another project or from no project" do
      write(project_dir, "team", yaml)

      expect { catalog.find("team") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_workflow") }
      expect { catalog.find("team", project: "other") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_workflow") }
      expect(catalog.find("team", project: "app").path).to eq(File.join(project_dir, "team.yml"))
    end

    it "lists a broken project file with its problems instead of falling back to the user's" do
      write(project_dir, "rpiv", "steps: nope\n")
      write(global_dir, "rpiv", yaml)

      row = catalog.list(project: "app").first
      expect(row["source"]).to eq("project")
      expect(row["problems"]).not_to be_empty
      expect { catalog.find("rpiv", project: "app") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("invalid_workflow") }
    end

    it "reads a project file's bytes through source" do
      write(project_dir, "team", yaml)

      found = catalog.source("team", project: "app")
      expect([found["source"], found["project"], found["text"]]).to eq(["project", "app", yaml])
    end

    it "ignores a project name that could not be one directory" do
      ["../x", "a/b", ".hidden", "..", "", "a\nb"].each do |name|
        expect(catalog.find("rpiv", project: name).source).to eq("builtin")
        expect(catalog.list(project: name).map { |row| row["source"] }).to eq(%w[builtin])
      end
    end

    it "does not read a project file through a name that climbs out of the projects directory" do
      write(File.join(@dir, "projects"), "escaped", yaml)

      expect { catalog.find("escaped", project: "../projects") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_workflow") }
    end

    it "names a project's ids among the known ones when an id is unknown" do
      write(project_dir, "team", yaml)

      expect { catalog.find("nope", project: "app") }.to raise_error(Workspace::Error, 'No workflow named "nope". Known: rpiv, team.') { |error|
        expect(error.details["known"]).to eq(%w[rpiv team])
      }
      expect { catalog.find("nope") }.to raise_error(Workspace::Error) { |error| expect(error.details["known"]).to eq(%w[rpiv]) }
    end

    it "lists an entry of a project's directory that can't be a definition, with why and its project" do
      write(project_dir, "Bad Name", yaml)
      FileUtils.mkdir_p(File.join(project_dir, "dir.yml"))

      rows = catalog.list(project: "app").reject { |row| row["id"] == "rpiv" }

      expect(rows.map { |row| row.values_at("id", "source", "project") }).to eq([["Bad Name", "project", "app"], ["dir", "project", "app"]])
      expect(rows.first["path"]).to eq(File.join(project_dir, "Bad Name.yml"))
      expect(rows.first["problems"]).to eq(["the file's name must be a workflow id: lowercase letters, digits, '-' and '_', at most 40 characters"])
      expect(rows.last["problems"]).to eq(["#{File.join(project_dir, "dir.yml")} is not a file"])
      expect(catalog.list.map { |row| row["id"] }).to eq(%w[rpiv])
    end

    it "looks a parent up project first, and below the source that asks" do
      write(project_dir, "rpiv", yaml)
      write(global_dir, "rpiv", "title: Mine\nsteps:\n  a:\n    prompt: P\n")

      expect(catalog.parent("rpiv", project: "app")["source"]).to eq("project")
      expect(catalog.parent("rpiv", below: "project", project: "app")["source"]).to eq("global")
      expect(catalog.parent("rpiv", below: "global", project: "app")["source"]).to eq("builtin")
      expect(catalog.parent("rpiv", below: "file", project: "app")["source"]).to eq("builtin")
      expect(catalog.parent("rpiv", below: "builtin", project: "app")).to be_nil
      expect(catalog.parent("rpiv", project: "other")["source"]).to eq("global")
      expect(catalog.parent("rpiv")["source"]).to eq("global")
    end

    it "lets a project file extend the id it hides, and be read through find, list and source" do
      write(global_dir, "team", "title: User\nsteps:\n  a:\n    prompt: P\n")
      write(project_dir, "team", "extends: team\ntitle: Project\n")

      found = catalog.find("team", project: "app")
      expect([found.source, found.to_h["title"], found.to_h["steps"].map { |step| step["id"] }]).to eq(["project", "Project", ["a"]])
      expect(catalog.list(project: "app").find { |row| row["id"] == "team" }["problems"]).to eq([])
      expect(catalog.source("team", project: "app")["problems"]).to eq([])
      expect(catalog.source("team")["source"]).to eq("global")
    end

    it "names the definitions of every project that extend an id, whichever project the caller is in" do
      other_dir = File.join(@dir, "projects", "other", "workflows")
      write(global_dir, "base", yaml)
      write(global_dir, "mid", "extends: base\n")
      write(project_dir, "kid", "extends: mid\n")
      write(other_dir, "pk", "extends: base\n")

      expect(catalog.extended_by("base")).to eq(["mid", "kid (project app)", "pk (project other)"])
    end

    it "leaves out a project that has its own definition of the id, which its children extend instead" do
      other_dir = File.join(@dir, "projects", "other", "workflows")
      write(global_dir, "base", yaml)
      write(other_dir, "base", yaml)
      write(other_dir, "pk", "extends: base\n")

      expect(catalog.extended_by("base")).to eq([])
    end

    it "keeps a project whose own definition of the id extends it, with the project definitions that extend that one" do
      other_dir = File.join(@dir, "projects", "other", "workflows")
      write(global_dir, "team", yaml)
      write(project_dir, "team", "extends: team\n")
      write(project_dir, "kid", "extends: team\n")
      write(other_dir, "team", yaml)

      expect(catalog.extended_by("team")).to eq(["team (project app)", "kid (project app)"])
    end

    it "ignores a directory under projects/ that could not be a project name" do
      write(File.join(@dir, "projects", "bad name", "workflows"), "pk", "extends: base\n")
      write(global_dir, "base", yaml)

      expect(catalog.extended_by("base")).to eq([])
    end

    it "says which directory a file path sits in" do
      expect(catalog.scope_of(File.join(project_dir, "x.yml"), project: "app")).to eq("project")
      expect(catalog.scope_of(File.join(global_dir, "x.yml"), project: "app")).to eq("global")
      expect(catalog.scope_of(File.join(project_dir, "x.yml"))).to be_nil
      expect(catalog.scope_of(File.join(builtin_dir, "x.yml"))).to eq("builtin")
    end

    it "takes the parent project of a worktree workspace" do
      expect(described_class.project_of("app.worktree-fix")).to eq("app")
      expect(described_class.project_of("app")).to eq("app")
      expect(described_class.project_of(nil)).to be_nil
    end
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
    expect(list[0]).to include("problems" => ["steps must be a mapping of step id to step, with at least one step"], "sha256" => Digest::SHA256.hexdigest("steps: {}\n"))
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

    expect(entry).to eq("id" => "mine", "title" => "mine", "description" => nil, "use_when" => nil, "applies_to" => [], "source" => "global", "project" => nil, "path" => File.join(global_dir, "mine.yml"),
      "sha256" => nil, "problems" => ["#{File.join(global_dir, "mine.yml")} is a link to a file that is not there"])
    expect { catalog.find("mine") }.to raise_error(Workspace::Error, 'No workflow named "mine". Known: rpiv.')
  end

  it "says a link to a directory is not a file, and skips an entry removed since the directory was listed" do
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    FileUtils.mkdir_p(global_dir)
    File.symlink(File.join(@dir, "elsewhere"), File.join(global_dir, "linked.yml"))
    pattern = File.join(global_dir, "*.yml")
    racing = lambda do |glob|
      (glob == pattern) ? [File.join(global_dir, "linked.yml"), File.join(global_dir, "vanished.yml")] : Dir.glob(glob)
    end

    list = described_class.new(config: config, globber: racing).list

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

  describe "#locate" do
    it "answers the global file, the builtin one, the global one over a builtin, and nil for a missing or malformed id" do
      write(builtin_dir, "only-builtin", "steps:\n  a:\n    prompt: P\n")
      write(global_dir, "only-global", "steps:\n  a:\n    prompt: P\n")
      write(global_dir, "rpiv", "steps:\n  a:\n    prompt: P\n")

      expect(catalog.locate("only-global")).to eq(["global", File.join(global_dir, "only-global.yml")])
      expect(catalog.locate("only-builtin")).to eq(["builtin", File.join(builtin_dir, "only-builtin.yml")])
      expect(catalog.locate("rpiv")).to eq(["global", File.join(global_dir, "rpiv.yml")])
      expect(catalog.locate("missing")).to be_nil
      expect(catalog.locate("../x")).to be_nil
    end
  end

  describe "#known? and #known_ids" do
    it "counts a project's own definitions only for that project" do
      project_dir = File.join(@dir, "projects", "app", "workflows")
      write(project_dir, "team", "steps:\n  a:\n    prompt: P\n")

      expect(catalog.known?("team")).to be(false)
      expect(catalog.known?("team", project: "app")).to be(true)
      expect(catalog.known_ids(project: "app")).to include("team")
      expect(catalog.known_ids).not_to include("team")
    end

    it "is true for a preset, a user file and a file that fails its checks" do
      write(global_dir, "mine", "steps:\n  a:\n    prompt: P\n")
      write(global_dir, "broken", "title: [\n")

      expect(%w[rpiv mine broken].map { |id| catalog.known?(id) }).to eq([true, true, true])
    end

    it "is false for an unknown id, a ticket key, an issue number and a URL" do
      expect(["nope", "PROJ-101", "#12", "https://example.com/o/r/issues/1"].map { |id| catalog.known?(id) }).to eq([false] * 4)
    end

    it "lists ids but leaves out a .yml entry no id can find" do
      write(global_dir, "mine", "steps:\n  a:\n    prompt: P\n")
      write(global_dir, "Bad Name", "x: 1\n")
      FileUtils.mkdir_p(File.join(global_dir, "dir.yml"))

      expect(catalog.known_ids).to eq(%w[mine rpiv])
    end
  end

  describe "#global_path" do
    it "names the user's file for an id" do
      expect(catalog.global_path("ship")).to eq(File.join(global_dir, "ship.yml"))
    end

    it "refuses an id that could not be a file name" do
      expect { catalog.global_path("../evil") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_workflow") }
    end
  end

  describe "#source" do
    it "answers a valid file's text, raw-byte digest and no problems" do
      yaml = "steps:\n  a:\n    prompt: P\n"
      write(global_dir, "ship", yaml)

      expect(catalog.source("ship")).to eq("source" => "global", "project" => nil, "path" => File.join(global_dir, "ship.yml"), "text" => yaml,
        "sha256" => Digest::SHA256.hexdigest(yaml), "problems" => [])
    end

    it "answers an invalid global file without raising, with every problem" do
      yaml = "schema_version: 9\nsteps: nope\n"
      write(global_dir, "bad", yaml)

      result = catalog.source("bad")

      expect(result).to include("text" => yaml, "sha256" => Digest::SHA256.hexdigest(yaml), "source" => "global")
      expect(result["problems"].size).to be >= 2
    end

    it "gives text nil, the digest of the bytes and a problem for bytes that are not UTF-8" do
      bytes = "steps:\n  a:\n    prompt: \xFF\xFE\n".b
      FileUtils.mkdir_p(global_dir)
      File.binwrite(File.join(global_dir, "bin.yml"), bytes)

      result = catalog.source("bin")

      expect(result["text"]).to be_nil
      expect(result["sha256"]).to eq(Digest::SHA256.hexdigest(bytes))
      expect(result["problems"]).to include(/not valid UTF-8/)
    end

    it "raises unknown_workflow naming the known ids" do
      expect { catalog.source("nope") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_workflow")
        expect(e.details["known"]).to eq(["rpiv"])
      }
    end
  end

  describe "#list of an invalid file" do
    it "reports the raw-byte sha256 with its problems" do
      yaml = "steps: nope\n"
      write(global_dir, "bad", yaml)

      row = catalog.list.find { |each| each["id"] == "bad" }

      expect(row["sha256"]).to eq(Digest::SHA256.hexdigest(yaml))
      expect(row["problems"]).not_to be_empty
    end
  end

  it "lists a file that can't be read with sha256 nil and a problem" do
    skip "root reads any file" if Process.uid.zero?
    write(global_dir, "locked", "steps:\n  a:\n    prompt: P\n")
    File.chmod(0o000, File.join(global_dir, "locked.yml"))

    row = catalog.list.find { |each| each["id"] == "locked" }

    expect(row["sha256"]).to be_nil
    expect(row["problems"]).to match([/can't be read/])
  ensure
    File.chmod(0o644, File.join(global_dir, "locked.yml")) if File.exist?(File.join(global_dir, "locked.yml"))
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

    it "has the plan and implement steps work the workspace plan, with the implementation-plan syntax composed in" do
      allow(config).to receive(:workflows_dir).and_return(global_dir)
      steps = catalog.find("rpiv").steps.to_h { |step| [step["id"], step] }

      expect(steps["plan"]["include"]).to eq(%w[notes implementation-plan])
      expect(steps["plan"]["prompt"]).to include("workspace plan path").and include("IMPLEMENTATION_PLAN.md")
      expect(steps["implement"]["include"]).to eq(%w[notes implementation-plan])
      expect(steps["implement"]["prompt"]).to include("workspace plan path")
    end

    describe "the plan step's status check" do
      require "tmpdir"
      require "open3"

      def check_exit(plans_json)
        Dir.mktmpdir do |bin|
          File.write(File.join(bin, "workspace"), "#!/bin/sh\ncat <<'JSON'\n#{plans_json}\nJSON\n")
          File.chmod(0o755, File.join(bin, "workspace"))
          allow(config).to receive(:workflows_dir).and_return(global_dir)
          command = catalog.find("rpiv").steps.find { |step| step["id"] == "plan" }["status"]["run"]
          _out, status = Open3.capture2e({"PATH" => "#{bin}:#{ENV["PATH"]}"}, "sh", "-c", command)
          status.exitstatus
        end
      end

      it "passes only for a plan that exists and has a task" do
        expect(check_exit('{"plans":[{"exists":true,"counts":{"total":3}}]}')).to eq(0)
      end

      it "fails for no plan file, a plan with no tasks, or no row" do
        expect(check_exit('{"plans":[{"exists":false,"counts":{"total":0}}]}')).to eq(1)
        expect(check_exit('{"plans":[{"exists":true,"counts":{"total":0}}]}')).to eq(1)
        expect(check_exit('{"plans":[]}')).to eq(1)
      end
    end
  end
end
