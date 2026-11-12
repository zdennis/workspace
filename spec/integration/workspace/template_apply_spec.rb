require "spec_helper"
require "tmpdir"
require "digest"
require "json"

# TemplateApply over a real TemplateStatus, TmuxinatorConfigWriter, TmuxinatorBackupStore and NameMigration
# lock, all in a temporary directory; the render, the template lookup and tmux are doubles.
RSpec.describe Workspace::TemplateApply do
  around do |example|
    Dir.mktmpdir("template-apply") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:config) do
    instance_double(Workspace::Config, render_state_dir: File.join(@dir, "state", ".render"), tmuxinator_backups_dir: File.join(@dir, "state", "backups", "tmuxinator")).tap do |c|
      allow(c).to receive(:config_path_for) { |name| File.join(@dir, "tmuxinator", "workspace.#{name}.yml") }
      allow(c).to receive(:agent_lock_path) { |name| File.join(@dir, "locks", "#{name}.lock") }
    end
  end
  let(:writer) { Workspace::TmuxinatorConfigWriter.new(config: config) }
  let(:backups) { Workspace::TmuxinatorBackupStore.new(config: config, writer: writer) }
  let(:real_locks) { Workspace::NameMigration.new(config: config, project_config: nil, tmux: nil, state: nil, event_log: nil, project_catalog_factory: nil, writer: writer) }
  # The real locks, with a step run before a name's lock is taken (what happens while apply waits for it).
  let(:before_lock) { {} }
  let(:locks) { steps_before_lock.new(real_locks, before_lock) }
  # Runs after each assessment, as if something changed the files in between.
  let(:after_assess) { {} }
  let(:assessing) { steps_after_assess.new(real_status, after_assess) }
  let(:steps_before_lock) do
    Class.new do
      def initialize(real, steps) = (@real, @steps = real, steps)

      def with_locks(*names, &block)
        @steps[names.first]&.call
        @real.with_locks(*names, &block)
      end
    end
  end
  let(:steps_after_assess) do
    Class.new do
      def initialize(real, steps) = (@real, @steps = real, steps)

      def assess(name) = @real.assess(name).tap { @steps[name]&.call }
    end
  end
  let(:template_path) { File.join(@dir, "team", "project.yml") }
  let(:library) { instance_double(Workspace::Library, tmuxinator_template: {"name" => "team", "path" => template_path}) }
  let(:project_config) do
    instance_double(Workspace::ProjectConfig, agent_pane_value: "claude", agent_pane_text: "claude").tap do |pc|
      allow(pc).to receive(:config_path_for) { |name| config.config_path_for(name) }
      allow(pc).to receive(:exists?) { |name| File.exist?(config.config_path_for(name)) }
      allow(pc).to receive(:render) { |_kind, inputs, _text| "#{inputs[:workspace_name]} v2\n" }
    end
  end
  let(:real_status) { Workspace::TemplateStatus.new(library: library, project_config: project_config, writer: writer) }
  let(:tmux) { instance_double(Workspace::Tmux, session_exists?: false).tap { |t| allow(t).to receive(:session_name_for) { |name| name } } }
  let(:retention) { instance_double(Workspace::TmuxinatorBackupConfig, keep: 20, max_age: nil) }
  let(:differ) { ->(old, new, old_label:, new_label:) { "--- #{old_label}\n+++ #{new_label}\n-#{old}+#{new}" } }
  subject(:apply) do
    described_class.new(status: assessing, writer: writer, backups: backups, locks: locks, project_config: project_config, tmux: tmux, differ: differ, retention: retention)
  end

  before do
    FileUtils.mkdir_p([File.dirname(template_path), File.join(@dir, "locks"), File.join(@dir, "tmuxinator")])
    File.write(template_path, "tpl v2\n")
  end

  def sha(text) = Digest::SHA256.hexdigest(text)

  def path(name) = config.config_path_for(name)

  # A config as a render wrote it, from an older template text unless +template_sha+ says otherwise.
  def rendered(name, text: "#{name} v1\n", template_sha: sha("tpl v1\n"))
    writer.write(name, text, kind: :project, template: "team", template_sha: template_sha,
      inputs: {workspace_name: name, agent_kind: "claude", agent_command: "claude"})
  end

  def tree
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).reject { |entry| entry.end_with?(".") }.sort.to_h do |entry|
      full = File.join(@dir, entry)
      [entry, File.file?(full) ? File.binread(full) : :dir]
    end
  end

  def outcomes(result) = result.rows.to_h { |row| [row["workspace"], [row["outcome"], row["reason"]]] }

  it "writes a stale config and its record from today's render, after copying both into one batch" do
    rendered("app")
    before_record = File.read(writer.record_path("app"))

    result = apply.call(["app"])

    expect(result.rows).to eq([{"workspace" => "app", "outcome" => "applied", "reason" => nil, "message" => nil, "state" => "stale",
                                "template" => "team", "running" => false, "record_only" => false, "code" => nil}])
    expect(File.read(path("app"))).to eq("app v2\n")
    expect(writer.record("app")).to have_attributes(template: "team", template_sha: sha("tpl v2\n"), rendered_sha: sha("app v2\n"))
    expect(writer.record("app").inputs).to include(workspace_name: "app", agent_command: "claude")
    manifest = backups.find(result.backup)
    expect(manifest).to include("reason" => "apply")
    expect(manifest["entries"]).to contain_exactly(include("name" => "app", "sha_before" => sha("app v1\n"), "sha_after" => sha("app v2\n"),
      "record_sha_before" => sha(before_record), "record_sha_after" => sha(File.read(writer.record_path("app")))))
    expect(File.read(backups.copy_path(manifest, "app"))).to eq("app v1\n")
  end

  it "rewrites only the record when another set renders the same text, with no relaunch note" do
    rendered("app", text: "app v2\n", template_sha: sha("tpl v2\n"))
    writer.write("app", "app v2\n", kind: :project, template: "old-set", template_sha: sha("tpl v2\n"),
      inputs: {workspace_name: "app", agent_kind: "claude", agent_command: "claude"})
    File.utime(Time.at(1_000_000), Time.at(1_000_000), path("app"))
    allow(tmux).to receive(:session_exists?).and_return(true)

    row = apply.call(["app"]).rows.first

    expect(row).to include("outcome" => "applied", "record_only" => true, "running" => false, "message" => "already up to date; only its render record was updated")
    expect(File.mtime(path("app"))).to eq(Time.at(1_000_000))
    expect(writer.record("app")).to have_attributes(template: "team", rendered_sha: sha("app v2\n"))
  end

  it "waits for a remove that holds the lock, so a removed config is never written back" do
    rendered("app")
    remover = nil
    after_assess["app"] = lambda do
      remover = Thread.new do
        real_locks.hold_if_possible("app") do
          File.delete(path("app"))
          writer.remove_record("app")
        end
      end
      expect(remover.join(0.2)).to be_nil
    end

    expect(outcomes(apply.call(["app"]))).to eq("app" => ["applied", nil])
    remover.join

    expect(File.exist?(path("app"))).to be(false)
    expect(File.exist?(writer.record_path("app"))).to be(false)
    expect(outcomes(apply.call(["app"]))).to eq("app" => ["skipped", "gone"])
  end

  it "says a running session needs a relaunch" do
    rendered("app")
    allow(tmux).to receive(:session_exists?).with("app", project: "app").and_return(true)

    row = apply.call(["app"]).rows.first

    expect(row).to include("outcome" => "applied", "running" => true, "message" => "running: relaunch to take effect")
  end

  it "leaves a current config alone and keeps no empty batch" do
    rendered("app", text: "app v2\n", template_sha: sha("tpl v2\n"))

    result = apply.call(["app"])

    expect(outcomes(result)).to eq("app" => ["unchanged", nil])
    expect(result.backup).to be_nil
    expect(backups.list).to eq([])
  end

  it "skips a config edited since it was rendered unless --force, and overwrites it with --force" do
    rendered("app")
    File.write(path("app"), "hand edit\n")

    skipped = apply.call(["app"])
    expect(skipped.rows.first).to include("outcome" => "skipped", "reason" => "modified", "code" => "template_modified", "state" => "modified")
    expect(File.read(path("app"))).to eq("hand edit\n")

    forced = apply.call(["app"], force: true)
    expect(outcomes(forced)).to eq("app" => ["applied", nil])
    expect(File.read(path("app"))).to eq("app v2\n")
    expect(File.read(backups.copy_path(backups.find(forced.backup), "app"))).to eq("hand edit\n")
  end

  it "skips a config with no render record, with or without --force, pointing at adopt" do
    File.write(path("app"), "app old\n")

    [false, true].each do |force|
      row = apply.call(["app"], force: force).rows.first
      expect(row).to include("outcome" => "skipped", "reason" => "untracked", "message" => include("workspace template adopt app"))
    end
    expect(File.read(path("app"))).to eq("app old\n")
    expect(File.exist?(writer.record_path("app"))).to be(false)
  end

  it "fails a workspace whose render can't be made and goes on with the others" do
    rendered("bad")
    rendered("app")
    allow(project_config).to receive(:render) do |_kind, inputs, _text|
      raise Workspace::Error, "no value for BRANCH" if inputs[:workspace_name] == "bad"
      "#{inputs[:workspace_name]} v2\n"
    end

    result = apply.call(%w[bad app])

    expect(result.rows.first).to include("workspace" => "bad", "outcome" => "failed", "reason" => "error", "code" => "error", "message" => "no value for BRANCH")
    expect(outcomes(result)["app"]).to eq(["applied", nil])
    expect(File.read(path("bad"))).to eq("bad v1\n")
  end

  it "under --dry-run decides every row and leaves the directory byte for byte as it was, with no batch" do
    rendered("app")
    rendered("cur", text: "cur v2\n", template_sha: sha("tpl v2\n"))
    File.write(path("loose"), "loose\n")
    before = tree

    result = apply.call(%w[app cur loose], dry_run: true, diff: true)

    expect(outcomes(result)).to eq("app" => ["would_apply", nil], "cur" => ["unchanged", nil], "loose" => ["skipped", "untracked"])
    expect(result.backup).to be_nil
    expect(tree).to eq(before)
  end

  it "adds each row's diff under --diff, nil when nothing would change" do
    rendered("app")
    rendered("cur", text: "cur v2\n", template_sha: sha("tpl v2\n"))

    rows = apply.call(%w[app cur], diff: true).rows

    expect(rows.first["diff"]).to eq("--- #{path("app")}\n+++ rendered\n-app v1\n+app v2\n")
    expect(rows.last["diff"]).to be_nil
  end

  describe "the startup lock" do
    it "gives a lock that can't be taken a workspace_locked row and applies the rest" do
      rendered("a")
      rendered("b")
      before_lock["b"] = -> { raise Workspace::NameMigration::LockUnavailable, "Permission denied" }

      result = apply.call(%w[a b])

      expect(result.rows.last).to include("workspace" => "b", "outcome" => "failed", "reason" => "workspace_locked", "code" => "workspace_locked")
      expect(outcomes(result)["a"]).to eq(["applied", nil])
      expect(File.read(path("b"))).to eq("b v1\n")
    end

    it "gives a lock whose path can't be built a workspace_locked row, applies the rest and still keeps the batch" do
      rendered("a")
      rendered("b")
      allow(config).to receive(:agent_lock_path) do |name|
        raise Workspace::Error, "socket directory too deep" if name == "b"
        File.join(@dir, "locks", "#{name}.lock")
      end

      result = apply.call(%w[b a])

      expect(result.rows.first).to include("workspace" => "b", "outcome" => "failed", "reason" => "workspace_locked", "message" => include("socket directory too deep"))
      expect(outcomes(result)["a"]).to eq(["applied", nil])
      expect(backups.find(result.backup)["entries"].map { |entry| entry["name"] }).to eq(["a"])
    end

    it "waits for a lock another holder has, then applies" do
      rendered("app")
      holder = File.open(config.agent_lock_path("app"), File::RDWR | File::CREAT, 0o600)
      holder.flock(File::LOCK_EX)

      worker = Thread.new { apply.call(["app"]) }
      expect(worker.join(0.3)).to be_nil
      expect(File.read(path("app"))).to eq("app v1\n")

      holder.close
      expect(outcomes(worker.value)).to eq("app" => ["applied", nil])
      expect(File.read(path("app"))).to eq("app v2\n")
    ensure
      holder&.close unless holder&.closed?
    end

    it "skips a workspace renamed while it waited, writing nothing under the old name" do
      rendered("old")
      before_lock["old"] = lambda do
        File.rename(path("old"), path("new"))
        File.rename(writer.record_path("old"), writer.record_path("new"))
      end

      result = apply.call(["old"])

      expect(result.rows.first).to include("outcome" => "skipped", "reason" => "gone")
      expect(File.exist?(path("old"))).to be(false)
      expect(File.exist?(writer.record_path("old"))).to be(false)
      expect(File.read(path("new"))).to eq("old v1\n")
      expect(result.backup).to be_nil
    end
  end

  describe "--rollback-all-on-error" do
    it "puts every file the batch wrote back on the first failure, and does not reach the rest" do
      rendered("a")
      rendered("bad")
      rendered("c")
      a_record = File.read(writer.record_path("a"))
      allow(project_config).to receive(:render) do |_kind, inputs, _text|
        raise Workspace::Error, "no value" if inputs[:workspace_name] == "bad"
        "#{inputs[:workspace_name]} v2\n"
      end

      result = apply.call(%w[a bad c], rollback: true)

      expect(result.rolled_back).to be(true)
      expect(outcomes(result)).to eq("a" => ["rolled_back", nil], "bad" => ["failed", "error"], "c" => ["skipped", "not_reached"])
      expect(File.read(path("a"))).to eq("a v1\n")
      expect(File.read(writer.record_path("a"))).to eq(a_record)
      expect(File.read(path("c"))).to eq("c v1\n")
      expect(result.backup).not_to be_nil
    end

    it "keeps a config's mode when it puts it back" do
      rendered("a")
      rendered("bad")
      File.chmod(0o644, path("a"))
      allow(project_config).to receive(:render) do |_kind, inputs, _text|
        raise Workspace::Error, "no value" if inputs[:workspace_name] == "bad"
        "#{inputs[:workspace_name]} v2\n"
      end

      apply.call(%w[a bad], rollback: true)

      expect(File.read(path("a"))).to eq("a v1\n")
      expect(File.stat(path("a")).mode & 0o7777).to eq(0o644)
    end

    it "deletes a render record the batch created" do
      rendered("a")
      rendered("bad")
      after_assess["a"] = -> { File.delete(writer.record_path("a")) }
      allow(project_config).to receive(:render) do |_kind, inputs, _text|
        raise Workspace::Error, "no value" if inputs[:workspace_name] == "bad"
        "#{inputs[:workspace_name]} v2\n"
      end

      result = apply.call(%w[a bad], rollback: true)

      expect(backups.find(result.backup)["entries"].first).to include("name" => "a", "record_sha_before" => nil)
      expect(File.exist?(writer.record_path("a"))).to be(false)
      expect(File.read(path("a"))).to eq("a v1\n")
    end

    it "still puts back the others when one file changed after the batch wrote it" do
      rendered("a")
      rendered("d")
      rendered("bad")
      allow(project_config).to receive(:render) do |_kind, inputs, _text|
        if inputs[:workspace_name] == "bad"
          File.write(path("a"), "edited meanwhile\n")
          raise Workspace::Error, "no value"
        end
        "#{inputs[:workspace_name]} v2\n"
      end

      result = apply.call(%w[a d bad], rollback: true)

      expect(outcomes(result)).to eq("a" => ["applied", nil], "d" => ["rolled_back", nil], "bad" => ["failed", "error"])
      expect(result.warnings).to contain_exactly(include("code" => "rollback_left_file", "workspace" => "a", "kind" => "config", "path" => path("a")))
      expect(File.read(path("a"))).to eq("edited meanwhile\n")
      expect(File.read(path("d"))).to eq("d v1\n")
    end
  end

  it "prunes past the retention limits after a batch, keeping each workspace's newest" do
    allow(retention).to receive(:keep).and_return(1)
    rendered("a")
    first = apply.call(["a"]).backup
    rendered("b")
    second = apply.call(["b"]).backup
    rendered("a")

    third = apply.call(["a"]).backup

    expect(backups.list.map { |manifest| manifest["id"] }).to eq([third, second])
    expect(first).not_to be_nil
  end
end
