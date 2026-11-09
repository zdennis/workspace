require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "workspace workflow project-scoped definitions through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-project-cli") do |dir|
      saved = ENV.to_h
      @home = File.realpath(dir)
      @plain = File.join(@home, "plain")
      FileUtils.mkdir_p(@plain)
      begin
        ENV.replace("HOME" => @home, "PATH" => ENV["PATH"])
        ENV.delete("TMUX")
        ENV.delete("TMUX_PANE")
        Dir.chdir(@plain) { example.run }
      ensure
        ENV.replace(saved)
      end
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:exits) { [] }
  let(:config) { Workspace::Config.new }
  let(:yaml) { "title: Team flow\nuse_when: The team's way.\nsteps:\n  plan:\n    prompt: Plan it.\n" }

  def run_cli(*args)
    out.truncate(0)
    out.rewind
    err.truncate(0)
    err.rewind
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", *args])
  rescue SystemExit => e
    exits << e.status
  end

  def register(name, root = File.join(@home, name))
    FileUtils.mkdir_p(config.tmuxinator_dir)
    File.write(config.config_path_for(name), "name: #{name}\nroot: #{root}\n")
    root
  end

  def make_repo(path)
    FileUtils.mkdir_p(path)
    system("git", "init", "-q", path, exception: true)
    path
  end

  def error_code_or_nil
    JSON.parse(out.string)["code"]
  rescue JSON::ParserError
    nil
  end

  def error_code
    JSON.parse(out.string)["code"]
  end

  def put_project(project, id, text = yaml)
    dir = File.join(config.workspace_projects_dir, project, "workflows")
    FileUtils.mkdir_p(dir)
    File.join(dir, "#{id}.yml").tap { |path| File.write(path, text) }
  end

  def listed(*args)
    run_cli("show", *args, "--json")
    JSON.parse(out.string)["workflows"].to_h { |row| [row["id"], row.values_at("source", "project")] }
  end

  before do
    register("app")
    register("other")
    register("app.worktree-fix")
  end

  it "lists a project's definition with its scope only for that project" do
    put_project("app", "team")

    expect(listed("--name", "app")).to include("team" => %w[project app], "rpiv" => ["builtin", nil])
    expect(listed("--name", "other")).not_to include("team")
    expect(listed).not_to include("team")
  end

  it "prints the scope in the text list and in show ID" do
    path = put_project("app", "team")

    run_cli("show", "--name", "app")
    expect(out.string).to match(/^team\s+project\s+Team flow/)
    run_cli("show", "team", "--name", "app")
    expect(out.string.lines.first).to eq("team: Team flow (project, #{path})\n")
  end

  it "does not find a project's definition without the project" do
    put_project("app", "team")

    run_cli("show", "team", "--json")

    expect(JSON.parse(out.string)).to include("ok" => false, "code" => "unknown_workflow")
  end

  it "reads a worktree workspace's parent project" do
    put_project("app", "team")

    expect(listed("--name", "app.worktree-fix")).to include("team" => %w[project app])
  end

  it "hides the user's and the preset's definition of the same id" do
    put_project("app", "rpiv")
    FileUtils.mkdir_p(config.workflows_dir)
    File.write(File.join(config.workflows_dir, "rpiv.yml"), yaml.sub("Team flow", "Mine"))

    expect(listed("--name", "app")).to include("rpiv" => %w[project app])
    expect(listed).to include("rpiv" => ["global", nil])
    run_cli("show", "rpiv", "--source", "--json", "--name", "app")
    expect(JSON.parse(out.string)["workflow"]).to include("source" => "project", "project" => "app")
  end

  it "warns, and reads no project directory, for a project name that can't be one directory name" do
    ["-dash", "my app"].each do |name|
      register(name)
      FileUtils.mkdir_p(File.join(config.workspace_projects_dir, "stray"))

      expect(listed("--name=#{name}")).to include("rpiv" => ["builtin", nil])
      expect(err.string).to include("can't be a directory under #{config.workspace_projects_dir}")
    end
  end

  it "refuses a --name that is not a workspace, rather than reading the user definitions" do
    run_cli("show", "--name", "typo", "--json")

    expect(error_code).to eq("unknown_workspace")
    run_cli("show", "team", "--name", "typo", "--json")
    expect(error_code).to eq("unknown_workspace")
    run_cli("validate", File::NULL, "--name", "typo", "--json")
    expect(error_code).to eq("unknown_workspace")
  end

  it "validates a file in the project's directory as a project definition" do
    path = put_project("app", "team")

    run_cli("validate", path, "--name", "app")
    expect(out.string.lines.first).to eq("team: valid (1 steps), in the project definitions\n")
    run_cli("validate", path, "--name", "app", "--json")
    expect(JSON.parse(out.string)["workflow"]).to include("scope" => "project", "source" => "file")
    run_cli("validate", path, "--name", "other", "--json")
    expect(JSON.parse(out.string)["workflow"]).to include("scope" => nil)
  end

  it "warns that a preset's file is shadowed by the project's definition of that id" do
    put_project("app", "rpiv")
    preset = File.join(config.builtin_workflows_dir, "rpiv.yml")

    run_cli("validate", preset, "--name", "app", "--json")
    doc = JSON.parse(out.string)

    expect(doc["workflow"]).to include("scope" => "builtin")
    expect(doc["warnings"].map { |warning| warning["code"] }).to include("shadowed")
    run_cli("validate", preset, "--json")
    expect(JSON.parse(out.string)["warnings"].map { |warning| warning["code"] }).not_to include("shadowed")
  end

  it "reports where stats finds the definition now" do
    put_project("app", "team")

    run_cli("stats", "team", "--name", "app", "--json")
    expect(JSON.parse(out.string)["definition"]).to include("source" => "project", "project" => "app")
  end

  describe "workflow sources" do
    let(:source_dir) { File.join(@home, "my-sources") }

    before do
      FileUtils.mkdir_p(source_dir)
      File.write(File.join(source_dir, "rpiv.yml"), yaml)
      File.write(File.join(source_dir, "extra.yml"), yaml)
      Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {}).run(["config", "set", "workflows.sources", "#{source_dir},#{File.join(@home, "missing-cache")}", "--scope", "global"])
    end

    it "lists a configured local source's definitions as source:1, hiding the preset" do
      expect(listed.slice("rpiv", "extra")).to eq("rpiv" => ["source:1", nil], "extra" => ["source:1", nil])
    end

    it "warns that a preset's file is shadowed by a source definition of that id" do
      preset = File.join(config.builtin_workflows_dir, "rpiv.yml")

      run_cli("validate", preset, "--json")
      warning = JSON.parse(out.string)["warnings"].find { |each| each["code"] == "shadowed" }

      expect(warning["message"]).to include("A source:1 definition of rpiv (#{File.join(source_dir, "rpiv.yml")})")
    end

    it "warns for a source file hidden by a global definition of the id" do
      path = File.join(config.workflows_dir, "extra.yml")
      FileUtils.mkdir_p(config.workflows_dir)
      File.write(path, yaml)

      run_cli("validate", File.join(source_dir, "extra.yml"), "--json")

      expect(JSON.parse(out.string)["warnings"].map { |each| each["code"] }).to include("shadowed")
    end
  end

  describe "which project a directory belongs to" do
    let(:team_path) { put_project("myapp", "team", yaml.sub("Team flow", "PROJTEAM")) }

    before do
      register("myapp", make_repo(File.join(@home, "myapp")))
      team_path
    end

    def show_from(dir, id = "team")
      Dir.chdir(dir) { run_cli("show", id, "--json") }
      JSON.parse(out.string)
    end

    it "finds a stopped checkout's project with no state entry, as start does" do
      repo = make_repo(File.join(@home, "own"))
      register("own", repo)
      put_project("own", "mine")

      expect(show_from(repo, "mine")).to include("ok" => true)
      expect(show_from(File.join(repo), "team")).to include("code" => "unknown_workflow")
    end

    it "reads no project for a clone whose directory name is a registered project in another repository" do
      clone = make_repo(File.join(@home, "evil", "myapp"))

      expect(show_from(clone)).to include("ok" => false, "code" => "unknown_workflow")
      Dir.chdir(clone) { run_cli("start", "team", "--prompt", "x", "--dry-run", "--json") }
      expect(out.string).not_to include("PROJTEAM")
      expect(error_code).to eq("unknown_workflow")
    end

    it "trusts a .workspace-project file only for a checkout the user's config ties to that project" do
      File.write(File.join(@home, "myapp", ".workspace-project"), "myapp")

      expect(show_from(File.join(@home, "myapp"))["workflow"]).to include("title" => "PROJTEAM")
      expect(err.string).to eq("")
    end

    it "ignores a repository's own .workspace-project naming another project, with a warning, in show and run" do
      other = make_repo(File.join(@home, "stranger"))
      File.write(File.join(other, ".workspace-project"), "myapp")

      expect(show_from(other)).to include("ok" => false, "code" => "unknown_workflow")
      expect(err.string).to include("names \"myapp\"", "does not put that workspace at this checkout")

      Dir.chdir(other) { run_cli("run", "team", "--dry-run", "--json") }
      expect(out.string).not_to include("Would start")
      expect(error_code).to eq("not_in_workspace")
      expect(JSON.parse(out.string)["error"]).to include("names \"myapp\"", "so it is not acted on")

      Dir.chdir(other) { run_cli("render", "team", "plan", "--json") }
      expect(error_code).to eq("not_in_workspace")
    end

    it "ignores a marker naming a worktree workspace of another project, and one that is not a name" do
      other = make_repo(File.join(@home, "stranger"))
      ["myapp.worktree-fix", "../myapp", "myapp\n.."].each do |claim|
        File.write(File.join(other, ".workspace-project"), claim)

        expect(show_from(other)).to include("code" => "unknown_workflow")
      end
    end

    it "trusts a worktree's marker when the user's config puts that worktree workspace at it" do
      main = File.join(@home, "myapp")
      system("git", "-C", main, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "--allow-empty", "-qm", "x", exception: true)
      tree = File.join(@home, "myapp-fix")
      system("git", "-C", main, "worktree", "add", "-q", tree, "-b", "fix", exception: true)
      register("myapp.worktree-fix", tree)
      File.write(File.join(tree, ".workspace-project"), "myapp.worktree-fix")

      expect(show_from(tree)["workflow"]).to include("title" => "PROJTEAM")
    end
  end

  describe "a worktree that start makes in a clone named like a registered project" do
    let(:marker_proof) { File.join(@home, "RAN-PROJONLY") }

    before do
      register("myapp", make_repo(File.join(@home, "myapp")))
      FileUtils.mkdir_p(config.tmuxinator_dir)
      FileUtils.cp(config.worktree_template_path.sub(config.tmuxinator_dir, File.join(config.workspace_dir, "lib", "templates")), config.worktree_template_path)
      Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {}).run(["config", "set", "commands.test", "echo ran > #{marker_proof}", "--name", "myapp"])
      put_project("myapp", "only", "title: Only\nsteps:\n  one:\n    prompt: One.\n    status: {command: test}\n")
    end

    def walk_into_worktree
      evil = make_repo(File.join(@home, "evil", "myapp"))
      system("git", "-C", evil, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "--allow-empty", "-qm", "x", exception: true)
      Dir.chdir(evil) do
        out.truncate(0)
        Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["start", "evd", "--no-launch", "--no-spine", "--yes"])
      end
      File.join(evil, ".worktrees", "evd")
    end

    it "targets itself but reads no myapp definition: show, check and run find none there" do
      tree = walk_into_worktree
      expect(File.exist?(config.config_path_for("myapp.worktree-evd"))).to be(true)
      expect(File.read(File.join(tree, ".workspace-project")).strip).to eq("myapp.worktree-evd")

      Dir.chdir(tree) do
        run_cli("show", "only", "--json")
        expect(error_code).to eq("unknown_workflow")
        run_cli("check", "only", "one", "--json")
        expect(error_code).to eq("unknown_workflow")
        run_cli("run", "only", "--dry-run", "--json")
        expect(out.string).not_to include("Would start")
        expect(error_code).to eq("unknown_workflow")
        run_cli("run", "rpiv", "--dry-run", "--input", "task=x")
        expect(err.string).not_to include("does not put that workspace")
        expect(err.string + out.string).not_to include("No workflow named")
      end
      expect(File.exist?(marker_proof)).to be(false)
    end

    it "still lets myapp's own worktree read myapp's definitions" do
      main = File.join(@home, "myapp")
      system("git", "-C", main, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "--allow-empty", "-qm", "x", exception: true)
      Dir.chdir(main) do
        Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["start", "mine", "--no-launch", "--no-spine", "--yes"])
      end

      Dir.chdir(File.join(main, ".worktrees", "mine")) { run_cli("show", "only", "--json") }

      expect(JSON.parse(out.string)["workflow"]).to include("title" => "Only", "source" => "project")
    end
  end

  describe "a registered project that is not a git checkout" do
    it "finds its project definitions from its root" do
      root = File.join(@home, "own")
      FileUtils.mkdir_p(root)
      register("own", root)
      put_project("own", "mine")

      Dir.chdir(root) { run_cli("show", "mine", "--json") }

      expect(JSON.parse(out.string)["workflow"]).to include("source" => "project", "project" => "own")
    end
  end

  describe "a plain repository's own worktree" do
    it "runs, renders and checks there with the user's and the presets' definitions only" do
      repo = make_repo(File.join(@home, "px"))
      system("git", "-C", repo, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "--allow-empty", "-qm", "x", exception: true)
      FileUtils.mkdir_p(config.tmuxinator_dir)
      FileUtils.cp(File.join(config.workspace_dir, "lib", "templates", "workspace.project-worktree-template.yml"), config.worktree_template_path)
      Dir.chdir(repo) { Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {}).run(["start", "px1", "--no-launch", "--no-spine", "--yes"]) }
      FileUtils.mkdir_p(config.workflows_dir)
      File.write(File.join(config.workflows_dir, "team.yml"), yaml)

      Dir.chdir(File.join(repo, ".worktrees", "px1")) do
        run_cli("run", "team", "--dry-run")
        expect(err.string + out.string).not_to include("does not put that workspace")
        expect(err.string + out.string).not_to include("No workflow named")
        run_cli("check", "team", "plan", "--json")
        expect(error_code_or_nil).to eq("step_without_status")
        run_cli("render", "team", "plan", "--json")
        expect(JSON.parse(out.string)["ok"]).to be(true)
        run_cli("show", "team", "--json")
        expect(JSON.parse(out.string)["workflow"]).to include("source" => "global")
      end
    end
  end

  describe "a plain repository nested in a worktree" do
    it "reads the user and preset definitions there, with no project, instead of refusing" do
      main = register("myapp", make_repo(File.join(@home, "myapp")))
      outer = File.join(main, ".worktrees", "outer")
      FileUtils.mkdir_p(outer)
      File.write(File.join(outer, ".workspace-project"), "myapp.worktree-outer")
      inner = make_repo(File.join(outer, "inner"))

      Dir.chdir(inner) do
        run_cli("check", "rpiv", "verify", "--json")
        expect(error_code).not_to eq("not_in_workspace")
        run_cli("render", "rpiv", "research", "--input", "task=x", "--json")
        expect(error_code).not_to eq("not_in_workspace")
        expect(JSON.parse(out.string)["ok"]).to be(true)
        run_cli("show", "rpiv", "--json")
        expect(JSON.parse(out.string)["workflow"]).to include("source" => "builtin")
        expect(err.string).to eq("")
      end
    end
  end

  describe "definitions that extend another, with a project's among them" do
    let(:base_text) { "title: Base\nsteps:\n  plan:\n    prompt: Plan.\n" }

    before do
      FileUtils.mkdir_p(config.workflows_dir)
      File.write(File.join(config.workflows_dir, "userbase.yml"), "extends: rpiv\ntitle: User base\n")
    end

    def parents_of(id)
      run_cli("show", id, "--name", "app", "--json")
      JSON.parse(out.string)["workflow"]["extends"].map { |row| row.values_at("id", "source") }
    end

    it "lets a project definition extend a user one and a preset" do
      put_project("app", "mine", "extends: userbase\ntitle: Mine\n")

      expect(parents_of("mine")).to eq([%w[userbase global], %w[rpiv builtin]])
    end

    it "lets a project definition extend the id it hides, reaching the user's, then the preset" do
      put_project("app", "userbase", "extends: userbase\ntitle: Project over user\n")
      put_project("app", "rpiv", "extends: rpiv\ntitle: Project over preset\n")

      run_cli("show", "userbase", "--name", "app", "--json")
      doc = JSON.parse(out.string)["workflow"]
      expect(doc).to include("source" => "project")
      expect(doc["extends"].map { |row| row.values_at("id", "source") }.first).to eq(%w[userbase global])
      expect(parents_of("rpiv")).to eq([%w[rpiv builtin]])
    end

    it "checks a draft against the project's definitions when it extends a project-only id" do
      put_project("app", "solo", base_text)
      draft = File.join(@home, "draft.yml")
      File.write(draft, "extends: solo\ntitle: Draft\n")

      run_cli("validate", draft, "--name", "app", "--json")
      expect(JSON.parse(out.string)["ok"]).to be(true)
      run_cli("add", "kid", draft, "--name", "app", "--dry-run", "--json")
      expect(JSON.parse(out.string)["ok"]).to be(true)
      run_cli("validate", draft, "--json")
      expect(JSON.parse(out.string)["ok"]).to be(false)
    end

    it "does not let another project's definition be extended" do
      put_project("other", "mine", "title: Theirs\nsteps:\n  a:\n    prompt: P\n")
      put_project("app", "kid", "extends: mine\n")

      run_cli("show", "kid", "--name", "app", "--json")
      expect(JSON.parse(out.string)["ok"]).to be(false)
    end

    it "names a project definition that extends the id a user adds or removes" do
      put_project("app", "mine", "extends: userbase\ntitle: Mine\n")
      draft = File.join(@home, "draft.yml")
      File.write(draft, "extends: rpiv\ntitle: Changed\n")
      user_sha = Digest::SHA256.hexdigest(File.binread(File.join(config.workflows_dir, "userbase.yml")))

      run_cli("update", "userbase", draft, "--if-sha256", user_sha, "--name", "app", "--json")

      expect(JSON.parse(out.string)["results"].first["extended_by"]).to eq(["mine (project app)"])

      run_cli("remove", "userbase", "--dry-run", "--json")
      expect(err.string).to include("mine (project app) extends userbase")
    end
  end

  describe "check and simulate" do
    it "find a definition only the project has, and none outside it" do
      put_project("app", "solo", "title: Solo\nsteps:\n  plan:\n    prompt: Plan.\n")
      script = File.join(@home, "script.yml")
      File.write(script, "steps:\n  plan:\n    - {}\n")

      run_cli("simulate", "solo", "--script", script, "--name", "app", "--json")
      expect(JSON.parse(out.string)).to include("ok" => true, "workflow" => "solo")

      run_cli("simulate", "solo", "--script", script, "--json")
      expect(error_code).to eq("unknown_workflow")

      run_cli("check", "solo", "plan", "--name", "app", "--json")
      expect(error_code).to eq("step_without_status")

      run_cli("check", "solo", "plan", "--json")
      expect(error_code).to eq("unknown_workflow")
    end
  end

  describe "changing definitions from inside a project" do
    let(:only_path) { put_project("app", "only") }
    let(:new_file) { File.join(@home, "new.yml").tap { |path| File.write(path, yaml.sub("Team flow", "Mine")) } }

    before { only_path }

    it "says a project-only id is the project's, with its path, and that update and remove edit only the user directory" do
      run_cli("update", "only", new_file, "--if-sha256", "0" * 64, "--name", "app")
      expect(err.string).to include("definition of the project app at #{only_path}", "edits only #{config.workflows_dir}")
      expect(err.string).not_to include("No workflow named")

      run_cli("remove", "only", "--yes", "--name", "app")
      expect(err.string).to include("definition of the project app at #{only_path}")
      expect(File.exist?(only_path)).to be(true)
    end

    it "names which file each sha belongs to when both the user and the project have the id" do
      user_path = File.join(config.workflows_dir, "only.yml")
      FileUtils.mkdir_p(config.workflows_dir)
      File.write(user_path, yaml.sub("Team flow", "User"))
      project_sha = Digest::SHA256.hexdigest(File.binread(only_path))
      user_sha = Digest::SHA256.hexdigest(File.binread(user_path))

      run_cli("update", "only", new_file, "--if-sha256", project_sha, "--name", "app", "--json")
      doc = JSON.parse(out.string)
      expect(doc["code"]).to eq("stale_workflow")
      expect(doc["details"]).to include("path" => user_path, "sha256" => user_sha, "project_path" => only_path, "project_sha256" => project_sha)
      expect(doc["error"]).to include("hides this one in app", "reads that file")

      run_cli("update", "only", new_file, "--if-sha256", user_sha, "--name", "app")
      expect(File.read(user_path)).to include("Mine")
      expect(File.read(only_path)).to include("Team flow")
    end

    it "says a project definition hides what add writes, and what stays in effect after remove" do
      run_cli("add", "only", new_file, "--name", "app")
      expect(out.string).to include("the project definition at #{only_path} hides it in app")

      put_project("app", "explore")
      explore_user = File.join(config.workflows_dir, "explore.yml")
      File.write(explore_user, yaml)
      run_cli("remove", "explore", "--yes", "--name", "app")
      expect(out.string).to include("the project definition at #{File.join(config.workspace_projects_dir, "app", "workflows", "explore.yml")} stays in effect in app")
      expect(out.string).not_to include("preset")
    end

    it "tells update, like add and remove, that the project's definition hides what it wrote" do
      user_path = File.join(config.workflows_dir, "only.yml")
      FileUtils.mkdir_p(config.workflows_dir)
      File.write(user_path, yaml)

      run_cli("update", "only", new_file, "--if-sha256", Digest::SHA256.hexdigest(File.binread(user_path)), "--name", "app")

      expect(out.string).to include("Updated workflow only at #{user_path}; the project definition at #{only_path} hides it in app.")
    end

    it "still says the preset is in effect again when the project has no definition of the id" do
      FileUtils.mkdir_p(config.workflows_dir)
      File.write(File.join(config.workflows_dir, "explore.yml"), yaml)

      run_cli("remove", "explore", "--yes", "--name", "app")

      expect(out.string).to include("the preset of the same id is in effect again")
    end
  end
end
