require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"

# Each example starts its own process with no UTF-8 locale, as cron or an app
# started by launchd would, and changes nothing in the process running the specs.
RSpec.describe "reading files as UTF-8 whatever the locale" do
  let(:root) { File.expand_path("../..", __dir__) }

  around do |example|
    Dir.mktmpdir("ws-utf8") do |dir|
      @home = File.realpath(dir)
      example.run
    end
  end

  def env
    {"LC_ALL" => "C", "PATH" => ENV.fetch("PATH"), "HOME" => @home,
     "XDG_STATE_HOME" => File.join(@home, "state"), "XDG_CONFIG_HOME" => File.join(@home, ".config")}
  end

  def ruby(script, *args)
    Open3.capture3(env, RbConfig.ruby, "-I", File.join(root, "lib"), "-e", script, *args, unsetenv_others: true, chdir: @home)
  end

  it "would read text as US-ASCII in such a process, were workspace not loaded" do
    out, = ruby("print Encoding.default_external")

    expect(out).to eq("US-ASCII")
  end

  it "reads text as UTF-8 once workspace is loaded, and says nothing on stderr though warnings are on" do
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-w", "-I", File.join(root, "lib"), "-e",
      'require "workspace"; path = ARGV[0]; File.binwrite(path, "O\u00F9 \u00E7a ?"); text = File.read(path); print [Encoding.default_external, text.encoding, text.valid_encoding?, text.strip.size].join(" ")',
      File.join(@home, "text"), unsetenv_others: true, chdir: @home)

    expect(out).to eq("UTF-8 UTF-8 true 7")
    expect(err).not_to include("default_external")
    expect(status).to be_success
  end

  it "lists a workspace's questions through bin/workspace when the workspace's name and a question hold non-ASCII text" do
    repo = File.join(@home, "repo")
    FileUtils.mkdir_p([repo, File.join(@home, ".config", "tmuxinator"), File.join(@home, "state", "workspace", "café")])
    File.write(File.join(repo, ".workspace-project"), "café\n", encoding: "UTF-8")
    File.write(File.join(@home, "state", "workspace", "café", "asks.json"),
      JSON.generate([{"id" => "a1b2c3", "question" => "Où ça ?", "default" => "ici", "status" => "open", "asked_at" => "2026-10-04T12:00:00Z"}]), encoding: "UTF-8")

    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, "bin", "workspace"), "ask", "list", "--json", unsetenv_others: true, chdir: repo)

    expect(err).to eq("")
    expect(status).to be_success
    document = JSON.parse(out.dup.force_encoding("UTF-8"))
    expect(document).to include("ok" => true, "workspace" => "café")
    expect(document["questions"].map { |each| each["question"] }).to eq(["Où ça ?"])
  end

  it "writes a worktree's tmuxinator config from the shipped template, which holds a non-ASCII character" do
    template = File.join(root, "lib", "templates", "workspace.project-worktree-template.yml")
    FileUtils.mkdir_p(File.join(@home, ".config", "tmuxinator"))
    FileUtils.cp(template, File.join(@home, ".config", "tmuxinator"))
    script = <<~RUBY
      require "workspace"
      require "stringio"
      config = Workspace::Config.new
      git = Workspace::Git.new(output: StringIO.new, input: StringIO.new)
      name = Workspace::ProjectConfig.new(config: config, git: git, output: StringIO.new)
        .create_worktree("app", "pdf", ARGV[0], "feature/pdf", quiet: true, task_id: "t1")
      print File.read(config.config_path_for(name))
    RUBY

    out, err, status = ruby(script, File.join(@home, "app-pdf"))

    expect(err).to eq("")
    expect(status).to be_success
    written = out.dup.force_encoding("UTF-8")
    expect(File.read(template, encoding: "UTF-8")).to match(/[^\x00-\x7F]/)
    expect(written).to include("pre_window: export WORKSPACE_TASK=t1", "feature/pdf").and match(/[^\x00-\x7F]/)
  end
end
