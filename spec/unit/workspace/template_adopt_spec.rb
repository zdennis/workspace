require "spec_helper"
require "tmpdir"

# TemplateAdopt over doubles: the record it writes, what it reads out of a config, and the refusals.
RSpec.describe Workspace::TemplateAdopt do
  around do |example|
    Dir.mktmpdir("adopt-unit") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:template_path) { File.join(@dir, "project.yml") }
  let(:library) { instance_double(Workspace::Library, tmuxinator_template: {"name" => "team", "path" => template_path}) }
  let(:writer) { instance_double(Workspace::TmuxinatorConfigWriter, record: nil, write_record_for: nil) }
  let(:main_agent) { instance_double(Workspace::MainAgent, kind: "codex") }
  let(:locks) { instance_double(Workspace::NameMigration) }
  let(:rendered) { "rendered\n" }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig, agent_pane_value: nil, agent_pane_text: "codex", banner_text: "app", render: rendered).tap do |pc|
      allow(pc).to receive(:config_path_for) { |name| File.join(@dir, "#{name}.yml") }
      allow(pc).to receive(:exists?) { |name| File.exist?(File.join(@dir, "#{name}.yml")) }
    end
  end
  subject(:adopt) { described_class.new(library: library, project_config: project_config, writer: writer, main_agent: main_agent, locks: locks) }

  before do
    File.write(template_path, "tpl\n")
    allow(locks).to receive(:with_locks) { |*_names, &block| block.call }
  end

  def config(name, text) = File.write(File.join(@dir, "#{name}.yml"), text)

  it "records an exact match with the file's own sha, from the inputs it read, and holds the workspace's lock" do
    text = "# /x/app.yml\n\nname: app\nroot: /src/app\npanes:\n  - ascii-banner \"My App\"\n"
    config("app", text)
    allow(project_config).to receive(:render).and_return(text)

    row = adopt.call(["app"]).first

    expect(locks).to have_received(:with_locks).with("app")
    expect(row).to include("outcome" => "adopted", "match" => "exact", "template" => "team", "kind" => "project")
    expect(writer).to have_received(:write_record_for).with("app", text, kind: :project, template: "team", template_sha: Digest::SHA256.hexdigest("tpl\n"),
      inputs: {workspace_name: "app", config_path: "/x/app.yml", agent_kind: "codex", agent_command: "codex", project_name: "app", project_root: "/src/app", display_name: "My App"}, approx: false)
  end

  it "records approx with the render's text, so the file reads as edited" do
    config("app", "name: app\nroot: /src/app\n")

    expect(adopt.call(["app"]).first).to include("outcome" => "adopted", "match" => "approx")
    expect(writer).to have_received(:write_record_for).with("app", "rendered\n", hash_including(approx: true))
  end

  it "reads a worktree's session, path, echo line and task id" do
    config("app.worktree-x", "name: app-wt-x\nroot: /src/app/.worktrees/x\npre_window: export WORKSPACE_TASK=t_1\npanes:\n  - echo 'Worktree — feat/x (app)'\n")

    adopt.call(["app.worktree-x"])

    expect(writer).to have_received(:write_record_for).with("app.worktree-x", anything, hash_including(kind: :worktree,
      inputs: hash_including(tmux_session_name: "app-wt-x", worktree_path: "/src/app/.worktrees/x", worktree_branch: "feat/x", project_name: "app", task_id: "t_1")))
  end

  it "takes the project from the name and the branch from the directory for a worktree with no echo line" do
    config("app.worktree-y", "name: a\nroot: /r/y\n")

    expect(adopt.call(["app.worktree-y"]).first).to include("outcome" => "adopted")
    expect(writer).to have_received(:write_record_for).with("app.worktree-y", anything, hash_including(inputs: hash_including(project_name: "app", worktree_branch: "y")))
  end

  it "takes only an absolute path in the header as the config path" do
    config("app", "# a comment\nname: app\nroot: /r\n")
    config("api", "# /abs/api.yml\nname: api\nroot: /r\n")

    adopt.call(%w[app api])

    expect(writer).to have_received(:write_record_for).with("app", anything, hash_including(inputs: hash_including(config_path: File.join(@dir, "app.yml"))))
    expect(writer).to have_received(:write_record_for).with("api", anything, hash_including(inputs: hash_including(config_path: "/abs/api.yml")))
  end

  it "adopts a config with no agent as claude" do
    config("app", "name: app\nroot: /r\n")
    allow(main_agent).to receive(:kind).and_return("none")

    adopt.call(["app"])

    expect(writer).to have_received(:write_record_for).with("app", anything, hash_including(inputs: hash_including(agent_kind: "claude")))
  end

  it "writes nothing and takes no lock under a dry run" do
    config("app", "name: app\nroot: /src/app\n")

    expect(adopt.call(["app"], dry_run: true).first).to include("outcome" => "would_adopt", "match" => "approx")
    expect(writer).not_to have_received(:write_record_for)
    expect(locks).not_to have_received(:with_locks)
  end

  it "skips a tracked config and a gone one" do
    config("app", "name: app\nroot: /src/app\n")
    allow(writer).to receive(:record).with("app").and_return(instance_double(Workspace::TmuxinatorConfigWriter::Record))

    expect(adopt.call(%w[app ghost]).map { |r| [r["outcome"], r["reason"]] }).to eq([%w[skipped tracked], %w[skipped gone]])
    expect(writer).not_to have_received(:write_record_for)
  end

  it "fails with adopt_unrecoverable for YAML it can't parse, and a missing root" do
    config("bad", "a: [\n")
    config("noroot", "name: x\n")

    codes = adopt.call(%w[bad noroot]).map { |r| [r["outcome"], r["code"]] }

    expect(codes).to all(eq(%w[failed adopt_unrecoverable]))
  end

  it "answers a render error or a lock problem as that row's failure, and goes on" do
    config("a", "name: a\nroot: /r\n")
    config("b", "name: b\nroot: /r\n")
    allow(project_config).to receive(:render).and_raise(Workspace::Error.new("no value", code: "render_boom"))
    allow(locks).to receive(:with_locks).with("b").and_raise(Workspace::NameMigration::LockUnavailable, "busy")

    rows = adopt.call(%w[a b])

    expect(rows.map { |r| [r["outcome"], r["code"]] }).to eq([%w[failed render_boom], %w[failed workspace_locked]])
  end
end
