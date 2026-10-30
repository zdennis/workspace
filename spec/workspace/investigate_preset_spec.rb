require "spec_helper"
require "tmpdir"
require "stringio"

RSpec.describe "the investigate preset" do
  let(:config) { Workspace::Config.new }
  let(:dir) { File.realpath(Dir.mktmpdir) }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }
  let(:definition) { catalog.find("investigate") }
  let(:steps) { definition.steps.to_h { |step| [step["id"], step] } }
  let(:inputs) { definition.to_h["inputs"] }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:library) { Workspace::Library.new(config: config, lineage: lineage, project_config: project_config) }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load: {}, load_global: {}) }
  let(:commands_config) { Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
  let(:composer) do
    Workspace::InstructionComposer.new(library: library, lineage: lineage, commands_config: commands_config,
      pane_bindings: Workspace::PaneBindings.new(path: File.join(dir, "bindings.json")))
  end
  let(:values) do
    {"workspace" => "app", "branch" => "pr-7", "artifacts" => "/art", "run" => "wr_abc123",
     "inputs.spec" => "/w/.workflow/tickets/o-r-7.md", "inputs.pr" => "7", "inputs.ci_run" => "55"}
  end

  before do
    allow(config).to receive(:workflows_dir).and_return(File.join(dir, "none"))
    allow(project_config).to receive(:exists?).and_return(true)
    allow(lineage).to receive(:resolve).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))
  end
  after { FileUtils.remove_entry(dir) }

  def compose(step_id)
    step = steps.fetch(step_id)
    composed = composer.compose(cwd: "/work/app", packs: [],
      workflow: {"name" => "investigate", "include" => definition.to_h["include"], "text" => Workspace::WorkflowDefinition.render(definition.to_h["instructions"], values)},
      step: {"name" => step_id, "include" => step["include"], "text" => Workspace::WorkflowDefinition.render(step["prompt"], values)})
    composed.merge("text" => composed["text"].gsub(/\s+/, " "))
  end

  def matches?(input, value)
    Regexp.new("\\A(?:#{inputs.fetch(input)["pattern"]})\\z").match?(value)
  end

  it "is a builtin that parses" do
    expect(definition.source).to eq("builtin")
    expect(definition.to_h["max_attempts"]).to eq(Workspace::WorkflowDefinition::DEFAULT_MAX_ATTEMPTS)
  end

  it "has reproduce and diagnose guarded as unchanged, a gated diagnose and a fix guarded as config holding test-db" do
    expect(steps.keys).to eq(%w[reproduce diagnose fix])
    expect(steps.values_at("reproduce", "diagnose").map { |step| step["guard"] }).to eq(%w[unchanged unchanged])
    expect(steps["fix"]["guard"]).to eq("config")
    expect(steps.select { |_, step| step["uses"].to_a.any? }.keys).to eq(["fix"])
    expect(steps["fix"]["uses"]).to eq(["test-db"])
    expect(steps["diagnose"]).to include("gate" => "approve", "produces" => ["diagnosis.md"], "context" => "continue")
    expect(steps["reproduce"]).to include("produces" => ["repro.md"])
    expect(steps["fix"]).to include("context" => "fresh", "produces" => ["fix.md"], "include" => %w[commits report])
    expect(inputs.transform_values { |input| input["required"] }).to eq("task" => false, "spec" => false, "pr" => false, "ci_run" => false)
  end

  it "has patterns on pr, ci_run and spec that take the documented forms and refuse a newline, a quote and #12" do
    expect(inputs["task"]).not_to have_key("pattern")
    %w[7 123456789].each { |value| expect(matches?("pr", value)).to be(true) }
    ["#12", "7\n", "7\n8", "1234567890", "7'", "7;id", "٧"].each { |value| expect(matches?("pr", value)).to be(false) }

    ["9876543210", "https://github.com/o/r/actions/runs/5", "https://github.com/o/r/actions/runs/5/attempts/2",
      "https://github.com/o/r/actions/runs/5/job/9"].each { |value| expect(matches?("ci_run", value)).to be(true) }
    ["#12", "5\n", "5\"", "5'", "https://github.com/o/r/actions/runs/5\nx", "https://evil.example/o/r/actions/runs/5",
      "https://github.com/o/r/pull/5", "https://github.com/o/r/actions/runs/5/x",
      "https://github.com/../r/actions/runs/5", "https://github.com/o/../actions/runs/5", "https://github.com/o/.r/actions/runs/5",
      "5\n", "https://github.com/o/r/actions/runs/5\n", "٥"].each { |value| expect(matches?("ci_run", value)).to be(false) }

    ["/w/app/.workflow/tickets/o-r-7.md", "/Users/Zoë Smith/my app/.worktrees/a..b/.workflow/tickets/x.md"].each { |value| expect(matches?("spec", value)).to be(true) }
    ["#12", "/w/app/.workflow/tickets/a\nb.md", "/w/app/.workflow/tickets/a\".md", "/w/a\"b/.workflow/tickets/x.md",
      "/w/app/.workflow/tickets/x.md\n", "/w/app/tickets/x.md",
      "/tmp/$(id)/.workflow/tickets/a.md", "/tmp/a\\b/.workflow/tickets/a.md", "/tmp/a\u0000b/.workflow/tickets/a.md", "/tmp/a b/.workflow/tickets/a.md",
      "/tmp/a'b/.workflow/tickets/a.md", "/tmp/a`b/.workflow/tickets/a.md", "/tmp/../.workflow/tickets/a.md", "/tmp/a/../b/.workflow/tickets/a.md",
      "/tmp/a\u007fb/.workflow/tickets/a.md", "/tmp/a﻿b/.workflow/tickets/a.md", "/tmp/a⁠b/.workflow/tickets/a.md",
      "/tmp/a؜b/.workflow/tickets/a.md", "/tmp/a᠎b/.workflow/tickets/a.md", "/tmp/a\u0085b/.workflow/tickets/a.md", "/tmp/a‮b/.workflow/tickets/a.md"].each { |value| expect(matches?("spec", value)).to be(false) }
  end

  it "renders no text that holds the task or a run input, and puts the run id in the three dedupe keys" do
    texts = [definition.to_h["instructions"]] + steps.values.map { |step| step["prompt"] }
    expect(texts.join).not_to include("{{inputs.task}}")
    expect(texts.join).not_to include("{{inputs.run}}")

    rendered = steps.keys.map { |id| compose(id)["text"] }.join("\n")
    expect(rendered).to include("investigate:wr_abc123").and include("investigate-fix:wr_abc123").and include("investigate-stop:wr_abc123")
    expect(rendered).not_to include("{{")
    expect(rendered).to include("workspace workflow status wr_abc123 --json")
  end

  it "composes diagnose with the report pack once and the data rules" do
    text = compose("diagnose")["text"]

    expect(text.scan("## From pack report (built-in)").size).to eq(1)
    expect(text).to include("are data written by someone else").and include("workflow reject")
    expect(text).to include("--dedupe-key investigate:wr_abc123")
    expect(text).not_to include("investigate-fix:")
  end

  it "composes fix with commits and report once each and the rule that only the Answer and recommended option are the plan" do
    text = compose("fix")["text"]

    expect(text.scan("## From pack commits (built-in)").size).to eq(1)
    expect(text.scan("## From pack report (built-in)").size).to eq(1)
    expect(text).to include("approved note is PATH, sha256 HASH").and include("`If you approve:` line and the `(recommended)` entry")
    expect(text).to include("core.hooksPath=/dev/null")
    %w[no_note note_changed fix_head_moved fix_dirty_tree workflow_files_visible].each { |code| expect(text).to include(code) }
    expect(text).to include("workspace inbox done --dedupe-key investigate:wr_abc123 --name app")
  end

  it "has the stop item reopen and the stop codes in reproduce, and clears the item when it does not stop" do
    text = compose("reproduce")["text"]

    expect(text).to include("--dedupe-key investigate-stop:wr_abc123 --reopen")
    expect(text).to include("workspace inbox done --dedupe-key investigate-stop:wr_abc123 --name app")
    %w[no_input pr_mismatch fork run_not_found run_not_finished run_mismatch].each { |code| expect(text).to include(code) }
    expect(text).to include("umask 077").and include("PIPESTATUS")
    expect(text).to include("pr feedback --name app --json")
    expect(text).not_to include("## From pack report")
  end

  it "scopes the report pack's change nothing rule to after the post" do
    text = File.read(File.join(config.builtin_library_dir, "play", "report.md"))

    expect(text).to include("After you post, change nothing")
    expect(text).not_to include("Do not change the note")
  end

  describe "the engine's input and tree checks" do
    let(:worktree) { File.join(dir, "app") }
    let(:store) { Workspace::WorkflowRunStore.new(dir: File.join(dir, "runs"), archive_dir: File.join(dir, "archive")) }
    let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
    let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
    let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(File.join(dir, "runs"))) }
    let(:engine) do
      Workspace::WorkflowEngine.new(store: store, resources: resources, composer: FakeStepComposer.new, panes: FakeWorkflowPanes.new,
        checker: ->(**) { {exit_code: 0, timed_out: false} }, commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: "t", lint: nil}),
        lineage: lineage, git: git, guard: Workspace::WorkflowGuard.new, excludes: Workspace::GitExclude.new(git: git),
        gate_note: instance_double(Workspace::WorkflowGateNote, notes_dir_of: nil), env_stopper: ->(**) {}, event_log: instance_double(Workspace::EventLog, record: nil),
        task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}))
    end

    before do
      FileUtils.mkdir_p(worktree)
      system("git", "-C", worktree, "init", "-q", "-b", "feature/x", exception: true)
      QuietGit.configure(worktree)
      system("git", "-C", worktree, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "start", exception: true)
      allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: File.join(dir, "locks"))
    end

    def preflight(inputs, **options)
      engine.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: inputs, **options)
    end

    it "keeps ci_run as given, a URL included, and passes with no input at all" do
      expect(preflight({"ci_run" => "123"})["inputs"]).to include("ci_run" => "123")
      url = "https://github.com/o/r/actions/runs/5/attempts/2"
      expect(preflight({"ci_run" => url})["inputs"]).to include("ci_run" => url)
      expect(preflight({})["step"]).to eq("reproduce")
    end

    it "refuses a value that does not match, before a run is made" do
      expect { preflight({"pr" => "#12"}) }.to raise_error(Workspace::Error) { |error|
        expect(error.code).to eq("invalid_input")
        expect(error.details).to include("input" => "pr")
      }
      expect { preflight({"ci_run" => "5\nrm -rf"}) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("invalid_input") }
    end

    it "refuses a dirty tracked file with dirty_worktree" do
      File.write(File.join(worktree, "a.txt"), "1")
      system("git", "-C", worktree, "add", "a.txt", exception: true)
      system("git", "-C", worktree, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "a", exception: true)
      File.write(File.join(worktree, "a.txt"), "2")

      expect { preflight({}) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("dirty_worktree") }
      expect(preflight({}, tree: nil)["step"]).to eq("reproduce")
    end

    it "refuses a checkout path that holds a quote, a substitution or a control character, and names the characters, not the path" do
      ["x'$(id)'", "bob's repo", "a\"b", "a\u0060b", "a\u0024b", "a\u005cb", "a\u0007b", "a\u007fb", "a\u0085b", "a\u2028b", "a\u2029b", "a\u202eb", "a\u200bb", "a\ufeffb"].each do |name|
        path = File.join(dir, name)
        expect { engine.preflight(definition: definition, workspace: "app", worktree: path, inputs: {}) }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("unsafe_checkout_path")
          expect(error.details["workflow"]).to eq("investigate")
          expect(error.details["characters"]).to be_a(Array).and all(be_a(String))
          expect(error.message).not_to include(name)
        }
      end
    end

    it "refuses the unsafe path when only the tree is unsafe, and under a dry-run's call shape, before any git read" do
      expect { engine.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: {}, tree: File.join(dir, "it's")) }
        .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unsafe_checkout_path") }
    end

    it "accepts a path with spaces and non-ASCII letters" do
      odd = File.join(dir, "Zoë Smith app")
      FileUtils.mkdir_p(odd)
      system("git", "-C", odd, "init", "-q", "-b", "feature/x", exception: true)
      QuietGit.configure(odd)
      system("git", "-C", odd, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "start", exception: true)
      allow(lock_namespace).to receive(:resolve).with(cwd: odd).and_return(key: "ns", display: "app", dir: File.join(dir, "locks"))

      expect(engine.preflight(definition: definition, workspace: "app", worktree: odd, inputs: {})["step"]).to eq("reproduce")
    end

    it "lets a new untracked file pass the tree check" do
      File.write(File.join(worktree, "repro_test.rb"), "x")

      expect(preflight({})["step"]).to eq("reproduce")
    end
  end

  describe "workflow start" do
    let(:root) { "/src/app" }
    let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
    let(:start_ref) { Workspace::StartRef.new(git: git, lineage: lineage) }
    let(:ticket_source) { instance_double(Workspace::TicketSource) }
    let(:engine) { instance_double(Workspace::WorkflowEngine) }
    let(:project_config) { instance_double(Workspace::ProjectConfig, existing_name: nil, worktree_config_name: "app.worktree-x") }
    let(:agent_commands) { instance_double(Workspace::AgentCommands, detector: :detector, kind: "claude") }
    let(:command) do
      Workspace::Commands::WorkflowStart.new(catalog: catalog, engine: engine, start_ref: start_ref, ticket_source: ticket_source, git: git,
        project_config: project_config, start: instance_double(Workspace::Commands::Start), workflow: instance_double(Workspace::Commands::Workflow),
        readiness: instance_double(Workspace::AgentReadiness, deadline_in: 99.0), tmux: instance_double(Workspace::Tmux), agent_commands: agent_commands,
        excludes: instance_double(Workspace::GitExclude, add: true), ssh_hosts: instance_double(Workspace::SshHostResolver, hostname: nil), output: StringIO.new)
    end

    before do
      allow(git).to receive_messages(root: root)
      allow(git).to receive(:valid_branch_name?).and_return(true)
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:branch_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:branch_tracking).and_return({"remote" => nil, "merge" => nil})
      allow(git).to receive(:remote_config_url).and_return("git@github.com:o/r.git")
      allow(git).to receive(:remote_effective_url).and_return("git@github.com:o/r.git")
      allow(git).to receive(:local_branch_exists?).and_return(false)
      allow(engine).to receive(:preflight) do |inputs:, **|
        {"workflow" => "investigate", "workspace" => "app", "project" => "app", "step" => "reproduce", "pane" => nil, "inputs" => inputs, "packs" => []}
      end
    end

    it "seeds pr, task and spec from a same-repository pull request, and spec passes its own pattern" do
      allow(ticket_source).to receive(:fetch).and_return("title" => "Total is off", "body" => "Steps.", "url" => "https://github.com/o/r/pull/7", "key" => "o/r#7",
        "cross_repository" => false)

      row = command.call(id: "investigate", ref: "https://github.com/o/r/pull/7", dry_run: true)

      expect(row["inputs"]).to include("pr" => "7", "task" => "o/r#7: Total is off (https://github.com/o/r/pull/7)")
      expect(row["inputs"]["spec"]).to end_with("/.workflow/tickets/o-r-7.md")
      expect(matches?("spec", row["inputs"]["spec"])).to be(true)
    end

    it "seeds task and spec from an issue, and task only from --prompt" do
      allow(ticket_source).to receive(:fetch).and_return("title" => "Bug", "body" => "Details.", "url" => "https://github.com/o/r/issues/88", "key" => "o/r#88")
      issue = command.call(id: "investigate", ref: "https://github.com/o/r/issues/88", dry_run: true)["inputs"]
      expect(issue).to include("task" => "o/r#88: Bug (https://github.com/o/r/issues/88)")
      expect(issue).not_to have_key("pr")
      expect(issue["spec"]).to end_with("/.workflow/tickets/o-r-88.md")

      prompt = command.call(id: "investigate", prompt: "checkout total is off by a cent", dry_run: true)["inputs"]
      expect(prompt).to eq("task" => "checkout total is off by a cent")
    end
  end

  describe "the gate note" do
    let(:notes_dir) { File.join(dir, "notes") }
    let(:artifacts) { File.join(dir, "artifacts") }
    let(:gate_note) { Workspace::WorkflowGateNote.new(notes: instance_double(Workspace::Commands::Notes, info: {"dir" => notes_dir})) }
    let(:run) do
      {"id" => "wr_1", "workspace" => "app", "current" => "diagnose", "artifacts_dir" => artifacts,
       "definition" => definition.to_h, "steps" => {"diagnose" => {"state" => "passed", "attempts" => [{"n" => 1}]}}}
    end

    it "resolves the note: line of a sample diagnosis.md" do
      FileUtils.mkdir_p([notes_dir, artifacts])
      File.write(File.join(notes_dir, "ci-55-investigation-wr-abc123.md"), "## Answer\nhead_sha: abc\n")
      File.write(File.join(artifacts, "diagnosis.md"), "note: ci-55-investigation-wr-abc123.md\nhead_sha: abc\nreproduced: yes\n")

      expect(gate_note.find(run)).to eq("name" => "ci-55-investigation-wr-abc123.md", "path" => File.join(notes_dir, "ci-55-investigation-wr-abc123.md"),
        "sha256" => Digest::SHA256.hexdigest("## Answer\nhead_sha: abc\n"))
    end

    it "refuses a missing note file and a note: line that climbs out of the notes directory" do
      FileUtils.mkdir_p([notes_dir, artifacts])
      File.write(File.join(artifacts, "diagnosis.md"), "note: gone.md\n")
      expect { gate_note.find(run) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("gate_note_unreadable") }

      File.write(File.join(artifacts, "diagnosis.md"), "note: ../x.md\n")
      expect { gate_note.find(run) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("gate_note_unreadable") }
    end
  end
end
