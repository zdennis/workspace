require "spec_helper"
require "json"

# Stands in for `start`: what its no-launch payload holds, and the notes directory NotesSetup makes.
class FakePromoteStart
  attr_reader :calls, :log

  def initialize(log: [], warnings: [], error: nil)
    @calls = []
    @log = log
    @warnings = warnings
    @error = error
  end

  def payload(branch, **options)
    @calls << [branch, options]
    @log << :start
    raise @error if @error
    path = File.join(options[:root], ".worktrees", branch)
    notes = File.join(path, "tmp", "workspace-notes")
    FileUtils.mkdir_p(notes)
    json = {"schema_version" => 1, "ok" => true, "project" => "api", "workspace" => "api.worktree-#{branch}", "path" => path,
            "branch" => branch, "base" => nil, "created" => true, "headless" => options[:headless], "launched" => false,
            "agent_kind" => "claude", "notes_dir" => notes, "task" => {"id" => "t-1", "title" => options[:title]}, "packs" => []}
    json["warnings"] = @warnings if @warnings.any?
    {exit_code: 0, json: json}
  end
end

class FakePromoteEvents
  attr_reader :events

  def initialize = @events = []

  def record(type:, project:, data:)
    @events << {"type" => type, "project" => project, "data" => data}
  end
end

RSpec.describe Workspace::Commands::Promote do
  let(:fixtures) { File.expand_path("../../fixtures/promote", __dir__) }

  # The JSON type of each value, recursively: a Hash's keys, the first element of a non-empty Array.
  def shape(value)
    case value
    when Hash then value.transform_values { |v| shape(v) }
    when Array then value.empty? ? [] : [shape(value.first)]
    when String then "string"
    when Integer, Float then "number"
    when true, false then "boolean"
    when nil then "null"
    end
  end

  def expect_fixture(name, document)
    fixture = JSON.parse(File.read(File.join(fixtures, "#{name}.json")))
    expect(shape(JSON.parse(JSON.generate(document)))).to eq(shape(fixture))
  end

  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:log) { [] }
  let(:events) { FakePromoteEvents.new }
  let(:env) { {} }
  let(:panes) { double("panes", session_live?: false, panes: []) }
  let(:spine_init) { double("spine_init", add_missing_ship: {"outcome" => "added", "files" => []}) }
  let(:spine_config) { double("spine_config", auto?: false) }
  let(:plan_command) { double("plan_command") }
  let(:plan_dispatch) { double("plan_dispatch") }
  let(:locks) { ->(_root) { {names: [], own: true} } }
  let(:start) { FakePromoteStart.new(log: log) }

  def build(checkout_move:, notes:, project_config:, start: self.start, notes_carry: Workspace::NotesCarry.new(spine_init: spine_init))
    described_class.new(checkout_move: checkout_move, notes_carry: notes_carry, start: start, notes: notes, project_config: project_config,
      panes: panes, spine_init: spine_init, spine_config: spine_config, plan_command: plan_command, plan_dispatch: plan_dispatch,
      locks: locks, event_log: events, env: env, output: output, error_output: error_output)
  end

  def error_from
    yield
    raise "expected an error"
  rescue Workspace::Error => e
    e
  end

  context "against a real repository" do
    include MoveRepos

    let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
    let(:main_notes) { File.join(repo, "tmp", "workspace-notes") }
    let(:notes) { double("notes").tap { |n| allow(n).to receive(:info).with(name: "api").and_return("dir" => main_notes) } }
    let(:project_config) do
      double("project_config").tap do |pc|
        allow(pc).to receive(:existing_name).with("api").and_return("api")
        allow(pc).to receive(:project_root_for).with("api").and_return(repo)
        allow(pc).to receive(:project_root_for).with("nope").and_return(nil)
        allow(pc).to receive(:worktree_config_name) { |project, dir| "#{project}.worktree-#{dir}" }
      end
    end

    def mover(git = self.git)
      Workspace::CheckoutMove.new(git: git, git_exclude: Workspace::GitExclude.new(git: git))
    end

    def git_with(**overrides)
      Workspace::Git.new(output: StringIO.new, input: StringIO.new).tap do |double|
        overrides.each do |name, fn|
          original = double.method(name)
          double.define_singleton_method(name) { |*args, **kw| fn.call(original, *args, **kw) }
        end
      end
    end

    def worktree(branch = "fix-login") = File.join(repo, ".worktrees", branch)

    def note(rel, text = "#{rel}\n") = write(File.join("tmp", "workspace-notes", rel), text)

    def dirty
      write("app.rb", "one\nTWO\nthree\n")
      sh("add", "app.rb")
      write("run.sh", "echo changed\n")
      write("spec/login_spec.rb", "it\n")
    end

    it "moves the work, makes the workspace, carries the notes, and prints the success document" do
      commit_file("local.rb", "l\n", "local commit")
      dirty
      before = work(repo)
      note("IMPLEMENTATION_PLAN.md", "---\nstatus: active\n---\n# Plan\n\n## Tasks\n\n- [ ] T1 Do it\n")
      note("spine/goal.md", "goal\n")
      note("research-login.md", "found\n")
      note("other.md", "stays\n")

      result = build(checkout_move: mover, notes: notes, project_config: project_config)
        .call(working_dir: repo, branch: "fix-login", title: "Fix the login bug", carry_notes: ["research-login.md"], json: true)

      doc = result[:json]
      expect(result[:exit_code]).to eq(0)
      expect_fixture("success", doc)
      expect(work(worktree)).to eq(before)
      expect(work(repo)[:status]).to eq("")
      new_notes = File.join(worktree, "tmp", "workspace-notes")
      expect(File.read(File.join(new_notes, "IMPLEMENTATION_PLAN.md"))).to include("T1 Do it")
      expect(File.read(File.join(new_notes, "spine", "goal.md"))).to eq("goal\n")
      expect(File.read(File.join(new_notes, "research-login.md"))).to eq("found\n")
      expect(File).not_to exist(File.join(new_notes, "other.md"))
      expect(File.read(File.join(main_notes, "other.md"))).to eq("stays\n")
      expect(Dir.children(main_notes)).to include(start_with("IMPLEMENTATION_PLAN.md.moved-"), start_with("spine.moved-"))
      expect(doc["notes"]).to eq("plan" => "moved", "spine" => "moved", "carried" => [{"path" => "research-login.md", "outcome" => "copied"}])
      expect(doc["warnings"].map { |w| w["code"] }).to eq(["default_ahead"])
      expect(doc["next"]).to eq(["workspace plan start --name api.worktree-fix-login"])
      expect(spine_init).to have_received(:add_missing_ship).with(name: "api.worktree-fix-login", spine_dir: File.join(new_notes, "spine"))
      expect(start.calls).to eq([["fix-login", {no_launch: true, spine: false, promoted: true, root: repo, yes: true, headless: false, title: "Fix the login bug"}]])
      expect(events.events).to eq([{"type" => "workspace_promoted", "project" => "api.worktree-fix-login", "data" => {
        "workspace" => "api.worktree-fix-login", "parent" => "api", "branch" => "fix-login", "from_branch" => "main", "branch_created" => true,
        "snapshot" => doc["moved"]["snapshot"]["id"], "notes" => {"plan" => "moved", "spine" => "moved", "carried" => 1}
      }}])
      expect(promote_refs).to eq([])
    end

    it "works from any directory with --name" do
      dirty

      doc = build(checkout_move: mover, notes: notes, project_config: project_config)
        .call(working_dir: "/", name: "api", branch: "fix-login", json: true)[:json]

      expect(doc).to include("workspace" => "api.worktree-fix-login", "path" => worktree)
      expect(work(repo)[:status]).to eq("")
    end

    it "refuses an unknown --name" do
      error = error_from { build(checkout_move: mover, notes: notes, project_config: project_config).call(working_dir: repo, name: "nope", branch: "x") }

      expect(error.code).to eq("unknown_workspace")
    end

    it "previews without writing anything, and matches the dry run document" do
      write("app.rb", "changed\n")
      note("IMPLEMENTATION_PLAN.md", "plan\n")
      note("research-login.md")
      before = fingerprint(repo)

      doc = build(checkout_move: mover, notes: notes, project_config: project_config)
        .call(working_dir: repo, branch: "fix-login", carry_notes: ["research-login.md"], dry_run: true, json: true)[:json]

      expect_fixture("dry_run", doc)
      expect(doc["notes"]).to eq("plan" => "would_move", "spine" => "none", "carried" => [{"path" => "research-login.md", "outcome" => "would_copy"}])
      expect(fingerprint(repo)).to eq(before)
      expect(start.calls).to eq([])
      expect(events.events).to eq([])
    end

    it "previews with no branch on the default branch, answering branch_required" do
      write("app.rb", "changed\n")

      doc = build(checkout_move: mover, notes: notes, project_config: project_config).call(working_dir: repo, dry_run: true, json: true)[:json]

      expect_fixture("dry_run_branch_required", doc)
      expect(doc).to include("branch_required" => true, "workspace" => nil, "path" => nil, "branch" => nil)
    end

    it "refuses the real run with no branch on the default branch, as a usage error" do
      write("app.rb", "changed\n")

      error = error_from { build(checkout_move: mover, notes: notes, project_config: project_config).call(working_dir: repo) }

      expect(error).to be_a(Workspace::UsageError)
      expect(error.code).to eq("branch_required")
      expect(start.calls).to eq([])
    end

    it "passes a rolled-back move through as move_failed, and starts nothing" do
      dirty
      before = fingerprint(repo)
      failing = git_with(stash_apply: ->(original, path, sha, **kw) { path.include?("/.worktrees/") ? [false, "error: could not apply"] : original.call(path, sha, **kw) })

      error = error_from { build(checkout_move: mover(failing), notes: notes, project_config: project_config).call(working_dir: repo, branch: "fix-login", json: true) }

      expect(error.code).to eq("move_failed")
      expect_fixture("move_failed", Workspace::JsonEnvelope.from_exception(1, error))
      expect(fingerprint(repo)).to eq(before)
      expect(start.calls).to eq([])
      expect(events.events).to eq([])
    end

    it "passes a move that could not be undone through as move_incomplete" do
      dirty
      failing = git_with(stash_apply: ->(*, **) { [false, "error: could not apply"] })

      error = error_from { build(checkout_move: mover(failing), notes: notes, project_config: project_config).call(working_dir: repo, branch: "fix-login", json: true) }

      expect(error.code).to eq("move_incomplete")
      expect_fixture("move_incomplete", Workspace::JsonEnvelope.from_exception(1, error))
      expect(promote_refs.size).to eq(1)
      expect(start.calls).to eq([])
    end

    it "refuses while another pane of the main workspace works, with the agent_working document" do
      dirty
      allow(panes).to receive(:session_live?).with("api").and_return(true)
      allow(panes).to receive(:panes).with("api").and_return([{"pane_id" => "%1", "state" => "working"}, {"pane_id" => "%3", "state" => "working"}])
      env["TMUX_PANE"] = "%1"
      before = fingerprint(repo)

      error = error_from { build(checkout_move: mover, notes: notes, project_config: project_config).call(working_dir: repo, branch: "fix-login", json: true) }

      expect(error.code).to eq("agent_working")
      expect(error.details).to eq("workspace" => "api", "panes" => [{"pane" => "%3", "state" => "working"}])
      expect_fixture("agent_working", Workspace::JsonEnvelope.from_exception(1, error))
      expect(fingerprint(repo)).to eq(before)
    end

    it "keeps the move when start fails after it, naming the start command that adopts the worktree" do
      dirty
      failing_start = FakePromoteStart.new(error: Workspace::ConfigParseError.new("bad yaml", code: "config_parse"))

      error = error_from do
        build(checkout_move: mover, notes: notes, project_config: project_config, start: failing_start).call(working_dir: repo, branch: "fix-login")
      end

      expect(error.code).to eq("config_parse")
      expect(error.details).to include("next" => ["workspace start fix-login"], "moved" => include("branch" => "fix-login"))
      expect(work(repo)[:status]).to eq("")
      expect(sh("rev-parse", "--abbrev-ref", "HEAD", dir: worktree).strip).to eq("fix-login")
    end
  end

  context "with a fake move" do
    let(:root) { Dir.mktmpdir("promote-unit") }
    let(:main_notes) { File.join(root, "main-notes") }
    let(:moved) do
      {"from_branch" => "main", "branch" => "fix-login", "branch_created" => true, "base_commit" => "a" * 40, "commits_ahead" => 0,
       "staged" => [], "staged_count" => 0, "unstaged" => ["app.rb"], "unstaged_count" => 1, "untracked" => [], "untracked_count" => 0,
       "left_behind" => [], "snapshot" => {"ref" => "refs/workspace/promote/x", "id" => "b" * 40, "kept" => false},
       "main" => {"path" => root, "branch" => "main", "clean" => true}}
    end
    let(:checkout_move) do
      double("checkout_move").tap do |cm|
        allow(cm).to receive(:call) {
          log << :move
          {"branch_required" => false, "path" => File.join(root, ".worktrees", "fix-login"), "moved" => moved, "warnings" => []}
        }
        allow(cm).to receive(:plan).and_return("branch_required" => false, "path" => File.join(root, ".worktrees", "fix-login"), "moved" => moved, "warnings" => [])
      end
    end
    let(:notes) { double("notes", info: {"dir" => main_notes}) }
    let(:project_config) do
      double("project_config", existing_name: "api").tap { |pc| allow(pc).to receive(:worktree_config_name) { |p, d| "#{p}.worktree-#{d}" } }
    end
    let(:notes_carry) { double("notes_carry") }
    let(:carried) { {"plan" => "none", "spine" => "none", "ship" => nil, "carried" => [], "warnings" => []} }
    let(:new_notes) { File.join(root, ".worktrees", "fix-login", "tmp", "workspace-notes") }

    before do
      FileUtils.mkdir_p(main_notes)
      allow(notes_carry).to receive(:call) {
        log << :carry
        carried
      }
      allow(spine_init).to receive(:call) {
        log << :spine
        {"outcome" => "created", "template" => {"name" => "default"}, "dir" => "x"}
      }
      allow(plan_command).to receive(:init) { |name:, title:, print:|
        log << :plan
        FileUtils.mkdir_p(new_notes)
        File.write(File.join(new_notes, "IMPLEMENTATION_PLAN.md"), "# Plan\n\n## Tasks\n")
        {"path" => File.join(new_notes, "IMPLEMENTATION_PLAN.md")}
      }
    end

    after { FileUtils.remove_entry(root) }

    subject(:command) { build(checkout_move: checkout_move, notes: notes, project_config: project_config, notes_carry: notes_carry) }

    def run(**options) = command.call(working_dir: root, branch: "fix-login", json: true, **options)

    it "starts with no plan and no spine, carries, then makes the spine and the plan that were asked for" do
      doc = run(spine: true, plan: "Fix it")[:json]

      expect(log).to eq(%i[move start carry spine plan])
      expect(start.calls.first.last).to include(no_launch: true, spine: false, promoted: true)
      expect(start.calls.first.last).not_to have_key(:plan)
      expect(notes_carry).to have_received(:call).with(from: main_notes, to: new_notes, name: "api.worktree-fix-login", carry_notes: [], dry_run: false)
      expect(plan_command).to have_received(:init).with(name: "api.worktree-fix-login", title: "Fix it", print: false)
      expect(doc["spine"]).to eq("outcome" => "created", "template" => {"name" => "default"})
      expect(doc["plan"]).to include("outcome" => "created")
      expect(doc["next"]).to eq(["workspace launch api.worktree-fix-login"])
    end

    it "makes no spine or plan when they were carried" do
      carried.merge!("plan" => "moved", "spine" => "moved")

      doc = run(spine: true, plan: true)[:json]

      expect(log).to eq(%i[move start carry])
      expect(doc).not_to have_key("spine")
      expect(doc).not_to have_key("plan")
    end

    it "makes no fresh spine or plan over ones the carry skipped, which are still in the main checkout" do
      carried.merge!("plan" => "skipped", "spine" => "skipped")

      doc = run(spine: true, plan: true)[:json]

      expect(log).to eq(%i[move start carry])
      expect(doc).not_to have_key("spine")
    end

    it "keeps going with a warning when carrying the notes fails" do
      allow(notes_carry).to receive(:call).and_raise(Errno::EACCES, "notes")

      doc = run(carry_notes: ["a.md"])[:json]

      expect(doc["notes"]).to eq("plan" => "skipped", "spine" => "skipped", "carried" => [{"path" => "a.md", "outcome" => "missing"}])
      expect(doc["warnings"]).to include(include("code" => "notes_unavailable", "message" => include(main_notes)))
      expect(events.events.size).to eq(1)
    end

    it "warns that the plan and spine stay behind when the new workspace has no notes directory" do
      start = FakePromoteStart.new(log: log)
      allow(start).to receive(:payload).and_wrap_original { |original, *args, **kw| original.call(*args, **kw).tap { |r| r[:json].delete("notes_dir") } }
      command = build(checkout_move: checkout_move, notes: notes, project_config: project_config, notes_carry: notes_carry, start: start)

      doc = command.call(working_dir: root, branch: "fix-login", json: true)[:json]

      expect(notes_carry).not_to have_received(:call)
      expect(doc["warnings"]).to include(include("code" => "notes_unavailable"))
    end

    it "keeps start's retry hint when start fails after the move" do
      start = FakePromoteStart.new(error: Workspace::Error.new("x", code: "unsaved_work", retry_with: {"flags" => ["--force"], "destructive" => true}))
      command = build(checkout_move: checkout_move, notes: notes, project_config: project_config, notes_carry: notes_carry, start: start)

      error = error_from { command.call(working_dir: root, branch: "fix-login") }

      expect(error.retry).to eq("flags" => ["--force"], "destructive" => true)
    end

    it "follows spine.auto unless --no-spine" do
      allow(spine_config).to receive(:auto?).with("api.worktree-fix-login").and_return(true)

      run
      run(spine: false)

      expect(spine_init).to have_received(:call).once
    end

    it "wraps start's plain warnings as start_note" do
      start = FakePromoteStart.new(log: log, warnings: ["Note: hooks not installed"])
      command = build(checkout_move: checkout_move, notes: notes, project_config: project_config, notes_carry: notes_carry, start: start)

      doc = command.call(working_dir: root, branch: "fix-login", json: true)[:json]

      expect(doc["warnings"]).to eq([{"code" => "start_note", "message" => "Note: hooks not installed"}])
    end

    it "moves with --force while a pane works, and says so" do
      allow(panes).to receive(:session_live?).and_return(true)
      allow(panes).to receive(:panes).and_return([{"pane_id" => "%2", "state" => "waiting"}, {"pane_id" => "%4", "state" => "idle"}])

      doc = run(force: true)[:json]

      expect(doc["warnings"]).to include(include("code" => "agent_working", "panes" => [{"pane" => "%2", "state" => "waiting"}]))
    end

    it "reports busy panes as a warning on a dry run, and refuses nothing" do
      allow(panes).to receive(:session_live?).and_return(nil)
      allow(panes).to receive(:panes).and_return([{"pane_id" => "%2", "state" => "working"}])

      doc = run(dry_run: true)[:json]

      expect(doc["warnings"]).to include(include("code" => "agent_working"))
      expect(checkout_move).not_to have_received(:call)
    end

    it "warns agent_state_unknown when the daemon does not answer, and moves" do
      allow(panes).to receive(:session_live?).and_return(true)
      allow(panes).to receive(:panes).and_raise(Workspace::Error.new("no daemon", code: "no_daemon"))

      doc = run[:json]

      expect(doc["warnings"].map { |w| w["code"] }).to eq(["agent_state_unknown"])
      expect(checkout_move).to have_received(:call)
    end

    def promote_with_locks(held)
      locks_found = ->(path) { (path == root) ? held : {names: [], own: true} }
      command = described_class.new(checkout_move: checkout_move, notes_carry: notes_carry, start: start, notes: notes, project_config: project_config,
        panes: panes, locks: locks_found, output: output, error_output: error_output)
      command.call(working_dir: root, branch: "fix-login", json: true)[:json]
    end

    it "warns about the locks the caller holds, naming them" do
      doc = promote_with_locks(names: ["devenv"], own: true)

      warning = doc["warnings"].find { |w| w["code"] == "locks_held" }
      expect(warning).to include("locks" => ["devenv"], "own" => true)
      expect(warning["message"]).to start_with("Locks you hold in this repository were not released: devenv")
    end

    it "says the locks may be other sessions' when it cannot tell whose they are" do
      doc = promote_with_locks(names: ["devenv", "migrations"], own: false)

      warning = doc["warnings"].find { |w| w["code"] == "locks_held" }
      expect(warning).to include("locks" => ["devenv", "migrations"], "own" => false)
      expect(warning["message"]).to include("perhaps by other sessions", "devenv, migrations")
    end

    it "gives no locks warning when the caller holds none" do
      doc = promote_with_locks(names: [], own: true)

      expect(doc["warnings"].map { |w| w["code"] }).not_to include("locks_held")
    end

    it "names the main workspace by its checkout when its config is not named after the directory" do
      allow(project_config).to receive(:existing_name).and_return(nil)
      allow(panes).to receive(:session_live?).with("work-notes").and_return(true)
      allow(panes).to receive(:panes).with("work-notes").and_return([{"pane_id" => "%9", "state" => "working"}])
      command = described_class.new(checkout_move: checkout_move, notes_carry: notes_carry, start: start, notes: notes, project_config: project_config,
        panes: panes, workspace_at: ->(path) { "work-notes" if path == root }, env: env, output: output, error_output: error_output)

      error = error_from { command.call(working_dir: root, branch: "fix-login", json: true) }

      expect(error.code).to eq("agent_working")
      expect(notes).to have_received(:info).with(name: "work-notes")
    end

    it "carries nothing when the main checkout has no workspace config, and says so for a named note" do
      allow(project_config).to receive(:existing_name).and_return(nil)

      doc = run(carry_notes: ["a.md"])[:json]

      expect(notes_carry).not_to have_received(:call)
      expect(doc["notes"]).to eq("plan" => "none", "spine" => "none", "carried" => [{"path" => "a.md", "outcome" => "missing"}])
      expect(doc["warnings"].map { |w| w["code"] }).to eq(["notes_unavailable"])
    end

    it "turns a spine or plan failure into a warning" do
      allow(spine_init).to receive(:call).and_raise(Workspace::Error.new("no template", code: "unknown_template"))
      allow(plan_command).to receive(:init).and_raise(Workspace::Error.new("cannot write", code: "notes_dir_unwritable"))

      doc = run(spine: "team", plan: true)[:json]

      expect(doc["spine"]).to eq("outcome" => "failed", "error" => "unknown_template")
      expect(doc["plan"]).to eq("path" => nil, "outcome" => "failed")
      expect(doc["warnings"].map { |w| w["code"] }).to eq(%w[spine_init_failed plan_init_failed])
    end

    describe "--launch" do
      let(:launches) { [] }
      let(:launch) {
        ->(ws, prompt:, play:) {
          launches << [ws, prompt, play]
          {ok: true, started: true, packs: [{"name" => "notes"}]}
        }
      }

      it "launches with --prompt when there is no plan" do
        doc = run(launch: launch, prompt: "Go on.")[:json]

        expect(launches).to eq([["api.worktree-fix-login", "Go on.", nil]])
        expect(doc).to include("launched" => true, "next" => [], "packs" => [{"name" => "notes"}])
      end

      it "starts the plan when there is one, with the plan play, adding --prompt after its line" do
        allow(plan_dispatch).to receive(:start) { |name:, launch:|
          launch.call(name, Workspace::Commands::PlanDispatch::DRAFT_PROMPT)
          {"outcome" => "drafting"}
        }

        result = run(plan: true, launch: launch, prompt: "Read HANDOFF.md.")

        expect(plan_dispatch).to have_received(:start).with(name: "api.worktree-fix-login", launch: anything)
        expect(launches).to eq([["api.worktree-fix-login", "#{Workspace::Commands::PlanDispatch::DRAFT_PROMPT}\n\nRead HANDOFF.md.", "implementation-plan"]])
        expect(result[:exit_code]).to eq(0)
        expect(result[:json]["launched"]).to eq(true)
      end

      it "launches plainly when the carried plan is done" do
        FileUtils.mkdir_p(new_notes)
        File.write(File.join(new_notes, "IMPLEMENTATION_PLAN.md"), "# Plan\n\n## Tasks\n\n- [x] T1 Done\n")
        allow(plan_dispatch).to receive(:start).and_raise(Workspace::Error.new("done", code: "plan_done"))

        run(launch: launch)

        expect(launches).to eq([["api.worktree-fix-login", nil, nil]])
      end

      it "exits 1 with launch_failed when the prompt was not delivered, keeping the workspace" do
        failed = ->(_ws, prompt:, play:) { {ok: false, started: true, message: "the agent was not ready"} }

        result = run(launch: failed)

        expect(result[:exit_code]).to eq(1)
        expect(result[:json]).to include("ok" => true, "launched" => true)
        expect(result[:json]["warnings"]).to include(include("code" => "launch_failed"))
      end
    end

    it "prints a summary and the warnings without --json" do
      allow(panes).to receive(:session_live?).and_return(true)
      allow(panes).to receive(:panes).and_raise(Workspace::Error.new("no daemon", code: "no_daemon"))

      command.call(working_dir: root, branch: "fix-login")

      expect(output.string).to include("Moved 0 staged, 1 unstaged, 0 untracked file(s)").and include("Next: workspace launch api.worktree-fix-login")
      expect(error_output.string).to include("Warning: Could not tell whether an agent")
    end
  end
end
