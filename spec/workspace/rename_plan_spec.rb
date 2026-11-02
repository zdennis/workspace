require "spec_helper"
require "tmpdir"
require "open3"
require "fileutils"

RSpec.describe Workspace::RenamePlan do
  around do |example|
    Dir.mktmpdir("rename-plan") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "api") }
  let(:linked) { File.join(repo, ".worktrees", "feat-a") }
  let(:workspace) { "api.worktree-feat-a" }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:roots) { {"api" => repo, workspace => linked} }
  let(:project_config) { instance_double(Workspace::ProjectConfig, existing_name: nil) }
  let(:config) { instance_double(Workspace::Config, agent_running?: false) }
  let(:tmux) { instance_double(Workspace::Tmux, session_name_for: "api-wt-feat-a", session_exists?: false) }
  let(:state) { instance_double(Workspace::State, keys: [workspace]) }
  let(:main_notes) { File.join(repo, "tmp", "workspace-notes") }
  let(:notes_dir) { Workspace::NotesDir.new(git: git, home: @dir) }
  let(:current_notes) { File.join(main_notes, "feat-a") }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => current_notes}, location_rule: {template: nil, main_dir: main_notes}) }
  let(:engine) { instance_double(Workspace::WorkflowEngine, run_on_checkout: nil) }
  let(:journal) { ->(_workspace) {} }
  let(:dev_lock) { ->(_path) { false } }
  let(:transcripts) { ->(_path) { false } }
  subject(:plan) do
    described_class.new(git: git, project_config: project_config, config: config, tmux: tmux, state: state, notes: notes,
      notes_dir: notes_dir, workflow_engine: engine, dev_lock: dev_lock, journal: journal, transcripts: transcripts)
  end

  def sh(*args, dir: repo)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args)
    raise out unless status.success?
    out
  end

  def refusal(code, **options)
    plan.call(workspace: workspace, new: "feat/b", **options)
    raise "no refusal"
  rescue Workspace::Error => e
    expect(e.code).to eq(code)
    e
  end

  before do
    FileUtils.mkdir_p(repo)
    sh("init", "-q")
    sh("commit", "-q", "--allow-empty", "-m", "start")
    sh("worktree", "add", "-q", "-b", "feat/a", linked)
    allow(project_config).to receive(:project_root_for) { |name| roots[name] }
    allow(project_config).to receive(:settle_worktree_name) { |project, dir, _path| "#{project}.worktree-#{dir}".downcase }
    allow(project_config).to receive(:worktree_session_name) { |project, dir| "#{project}.wt-#{dir}".tr(".", "-").downcase }
    allow(config).to receive(:pipeline_state_dir) { |name| File.join(@dir, "state", name) }
    allow(config).to receive(:config_path_for) { |name| File.join(@dir, "tmuxinator", "workspace.#{name}.yml") }
    allow(config).to receive(:project_config_path) { |name| File.join(@dir, "projects", "#{name}.yml") }
    allow(config).to receive(:agent_socket_path) { |name| File.join(@dir, "run", "#{name}.sock") }
    allow(config).to receive(:agent_log_path) { |name| File.join(@dir, "run", "#{name}.log") }
    allow(config).to receive(:inbox_path) { |_kind, name| File.join(@dir, "inbox", "#{name}.json") }
    allow(config).to receive(:hook_events_dir).and_return(File.join(@dir, "events"))
    allow(config).to receive(:rename_journal_path) { |name| File.join(@dir, "renames", "#{name}.json") }
  end

  describe "#call" do
    it "derives the new branch, directory, workspace and session beside the old directory" do
      result = plan.call(workspace: workspace, new: "feat/b")

      expect(result).to have_attributes(project: "api", workspace: workspace, new_workspace: "api.worktree-feat-b",
        branch: "feat/a", new_branch: "feat/b", path: linked, new_path: File.join(repo, ".worktrees", "feat-b"),
        session: "api-wt-feat-a", new_session: "api-wt-feat-b", resume: false)
      expect(result.path_changes?).to be(true)
      expect(result.workspace_changes?).to be(true)
      expect(result.to_h).to include("workspace" => {"from" => workspace, "to" => "api.worktree-feat-b"}, "branch" => {"from" => "feat/a", "to" => "feat/b"})
    end

    it "pins the document's key set" do
      document = plan.call(workspace: workspace, new: "feat/b").to_h

      expect(document.keys).to eq(%w[project workspace branch path session notes warnings resume])
      expect(document["notes"].keys).to eq(%w[action from to reason])
      expect(document["workspace"].keys).to eq(%w[from to])
      expect(%w[move with_checkout stays]).to include(document["notes"]["action"])
      expect(document["notes"]["reason"]).to be_nil
    end

    it "writes nothing" do
      before = Dir.glob(File.join(@dir, "**", "*"), File::FNM_DOTMATCH).sort
      plan.call(workspace: workspace, new: "feat/b")

      expect(Dir.glob(File.join(@dir, "**", "*"), File::FNM_DOTMATCH).sort).to eq(before)
    end

    it "keeps an adopted worktree in its own parent directory" do
      adopted = File.join(@dir, "elsewhere", "old-name")
      FileUtils.mkdir_p(File.dirname(adopted))
      sh("worktree", "add", "-q", "-b", "other", adopted)
      roots["api.worktree-old-name"] = adopted
      allow(tmux).to receive(:session_name_for).and_return("api-wt-old-name")
      allow(notes).to receive(:info).and_return({"dir" => File.join(main_notes, "other")})

      result = plan.call(workspace: "api.worktree-old-name", new: "newer")

      expect(result.new_path).to eq(File.join(@dir, "elsewhere", "newer"))
    end

    it "changes only the branch when the directory name comes out the same" do
      result = plan.call(workspace: workspace, new: "feat-a")

      expect(result.path_changes?).to be(false)
      expect(result.workspace_changes?).to be(false)
      expect(result.new_branch).to eq("feat-a")
    end

    describe "the notes" do
      it "moves a directory that sits where the rule puts it, to where the rule puts the new names" do
        expect(plan.call(workspace: workspace, new: "feat/b").notes).to have_attributes(action: "move", from: current_notes, to: File.join(main_notes, "feat-b"))
      end

      it "leaves a directory the person put somewhere else" do
        allow(notes).to receive(:info).and_return({"dir" => File.join(@dir, "mine")})

        expect(plan.call(workspace: workspace, new: "feat/b").notes).to have_attributes(action: "stays", reason: "custom", to: File.join(@dir, "mine"))
      end

      it "lets a directory inside the checkout go with it" do
        allow(notes).to receive(:info).and_return({"dir" => File.join(linked, "tmp", "workspace-notes")})

        expect(plan.call(workspace: workspace, new: "feat/b").notes)
          .to have_attributes(action: "with_checkout", to: File.join(repo, ".worktrees", "feat-b", "tmp", "workspace-notes"))
      end

      it "stays when the rule gives the same directory under the new names" do
        allow(notes).to receive(:location_rule).and_return({template: "#{@dir}/fixed", main_dir: nil})
        allow(notes).to receive(:info).and_return({"dir" => "#{@dir}/fixed"})

        expect(plan.call(workspace: workspace, new: "feat/b").notes).to have_attributes(action: "stays", reason: "same")
      end

      it "stays, with a warning, when the new place is inside the old one" do
        allow(notes_dir).to receive(:path_for).and_return(current_notes, File.join(current_notes, "inner"))

        result = plan.call(workspace: workspace, new: "feat/b")

        expect(result.notes).to have_attributes(action: "stays", reason: "nested")
        expect(result.warnings.map { |w| w["code"] }).to include("notes_nested")
      end

      it "refuses a notes target that holds files" do
        FileUtils.mkdir_p(File.join(main_notes, "feat-b"))
        File.write(File.join(main_notes, "feat-b", "other.md"), "theirs")

        expect(refusal("rename_target_taken").details).to include("taken" => ["notes_target"])
      end

      it "takes an empty notes target, as the move does" do
        FileUtils.mkdir_p(File.join(main_notes, "feat-b"))

        expect(plan.call(workspace: workspace, new: "feat/b").notes.action).to eq("move")
      end

      describe "on two volumes" do
        subject(:plan) do
          described_class.new(git: git, project_config: project_config, config: config, tmux: tmux, state: state, notes: notes,
            notes_dir: notes_dir, workflow_engine: engine, transcripts: transcripts, device: device)
        end

        before { FileUtils.mkdir_p(current_notes) }

        context "when the nearest existing parent of the target is on another volume" do
          let(:device) { ->(path) { (path == current_notes) ? 1 : 2 } }

          it "refuses before anything moves" do
            expect(refusal("rename_notes_other_volume").details).to include("from" => current_notes, "to" => File.join(main_notes, "feat-b"), "workspace" => workspace)
          end
        end

        context "when both are on one volume" do
          let(:device) { ->(_path) { 1 } }

          it "moves the notes" do
            expect(plan.call(workspace: workspace, new: "feat/b").notes.action).to eq("move")
          end
        end

        context "when the notes have gone on a re-run" do
          let(:device) { ->(path) { (path == current_notes) ? raise(Errno::ENOENT, path) : 2 } }

          it "has nothing to check" do
            expect(plan.call(workspace: workspace, new: "feat/b").notes.action).to eq("move")
          end
        end
      end

      it "stays when the notes directory cannot be worked out" do
        allow(notes).to receive(:info).and_raise(Workspace::Error.new("no", code: "notes_dir_unresolved"))

        result = plan.call(workspace: workspace, new: "feat/b")

        expect(result.notes).to have_attributes(action: "stays", reason: "unresolved")
        warning = result.warnings.find { |w| w["code"] == "notes_unresolved" }
        expect(warning["problem"]).to include("notes_dir_unresolved")
      end
    end

    describe "warnings" do
      it "warns about an upstream under another name and about prune" do
        sh("config", "branch.feat/a.remote", "origin")
        sh("config", "branch.feat/a.merge", "refs/heads/feat/a")

        codes = plan.call(workspace: workspace, new: "feat/b").warnings.map { |w| w["code"] }

        expect(codes).to eq(%w[upstream_other_name prune_pull_request])
      end

      it "does not warn when the upstream already has the new name" do
        sh("config", "branch.feat/a.remote", "origin")
        sh("config", "branch.feat/a.merge", "refs/heads/feat/b")

        expect(plan.call(workspace: workspace, new: "feat/b").warnings).to eq([])
      end

      it "warns about a transcript that launch will not continue" do
        allow(transcripts).to receive(:call).with(linked).and_return(true)

        expect(plan.call(workspace: workspace, new: "feat/b").warnings.map { |w| w["code"] }).to eq(["transcript_not_continued"])
      end
    end
  end

  describe "refusals" do
    it "refuses a workspace it does not know" do
      expect { plan.call(workspace: "nope", new: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
    end

    it "refuses a checkout that is gone" do
      FileUtils.rm_rf(linked)

      refusal("checkout_missing")
    end

    it "refuses a running tmux session and names workspace stop" do
      allow(tmux).to receive(:session_exists?).with("api-wt-feat-a").and_return(true)

      error = refusal("workspace_running")
      expect(error.message).to include("workspace stop #{workspace}")
      expect(error.details).to include("reason" => "session")
    end

    it "refuses a running agent daemon" do
      allow(config).to receive(:agent_running?).with(workspace).and_return(true)

      expect(refusal("workspace_running").details).to include("reason" => "agent")
    end

    it "refuses a workflow run going on the checkout" do
      allow(engine).to receive(:run_on_checkout).with(linked).and_return({"id" => "wr_1"})

      expect(refusal("run_active").details).to include("run_id" => "wr_1")
    end

    context "with the devenv lock held" do
      let(:dev_lock) { ->(path) { path == linked } }

      it "refuses" do
        refusal("dev_lock_held")
      end
    end

    it "refuses a main checkout" do
      expect { plan.call(workspace: "api", new: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_main_checkout") }
    end

    it "refuses a linked worktree whose name has no .worktree- part" do
      roots["adopted"] = linked

      expect { plan.call(workspace: "adopted", new: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_not_worktree") }
    end

    it "refuses a .worktree- name whose checkout is not a linked worktree" do
      roots["api.worktree-odd"] = repo

      expect { plan.call(workspace: "api.worktree-odd", new: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_not_worktree") }
    end

    it "refuses a pr-N branch as the source and as the new name" do
      expect { plan.call(workspace: workspace, new: "pr-12") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_pull_request_branch") }

      sh("branch", "-m", "feat/a", "pr-7", dir: linked)
      expect { plan.call(workspace: workspace, new: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_pull_request_branch") }
    end

    it "refuses the branch's own name" do
      expect { plan.call(workspace: workspace, new: "feat/a") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_no_change") }
    end

    it "refuses names git rejects or that leave no directory" do
      ["bad..name", "-x", "", "///", "has space?"].each do |name|
        expect { plan.call(workspace: workspace, new: name) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_invalid_name"), name }
      end
    end

    it "refuses a name that is taken, listing everything that is" do
      sh("branch", "feat/b")
      FileUtils.mkdir_p(File.join(repo, ".worktrees", "feat-b"))
      allow(project_config).to receive(:existing_name).with("api.worktree-feat-b").and_return("api.worktree-feat-b")
      allow(state).to receive(:keys).and_return(["api.worktree-feat-b"])
      FileUtils.mkdir_p(File.join(@dir, "state", "api.worktree-feat-b"))

      expect(refusal("rename_target_taken").details).to include("taken" => %w[branch directory config state_key state_dir])
    end

    it "treats a branch that differs only in case as taken" do
      sh("branch", "Feat/B")

      expect(refusal("rename_target_taken").details["taken"]).to include("branch")
    end

    it "refuses a directory that differs only in case" do
      expect { plan.call(workspace: workspace, new: "Feat/a") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_case_only") }
    end

    it "refuses a locked worktree" do
      sh("worktree", "lock", linked)

      refusal("rename_locked_worktree")
    end

    it "refuses when an earlier rename is not finished" do
      journal = ->(_workspace) { {"new_branch" => "feat/b"} }
      locked = described_class.new(git: git, project_config: project_config, config: config, tmux: tmux, state: state, notes: notes,
        notes_dir: notes_dir, workflow_engine: engine, journal: journal)

      expect { locked.call(workspace: workspace, new: "feat/b") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_in_progress") }
      expect { locked.call(workspace: workspace, new: "other") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_in_progress") }
    end

    it "refuses a target tmux session that exists" do
      allow(tmux).to receive(:session_exists?).with("api-wt-feat-b").and_return(true)

      expect(refusal("rename_target_taken").details["taken"]).to eq(["session"])
    end

    it "does not ask about the session when the rename leaves its name alone" do
      allow(tmux).to receive(:session_exists?).and_return(false)
      plan.call(workspace: workspace, new: "feat-a")

      expect(tmux).to have_received(:session_exists?).with("api-wt-feat-a").once
    end

    it "refuses a branch that is a ref prefix of the new name" do
      sh("branch", "x")

      error = nil
      expect { plan.call(workspace: workspace, new: "x/y") }.to raise_error(Workspace::Error) { |e| error = e }
      expect(error.details).to include("taken" => ["branch_conflict"], "conflicting_branch" => "x")
    end

    it "refuses a new name that is a ref prefix of another branch" do
      sh("branch", "x/y")

      error = nil
      expect { plan.call(workspace: workspace, new: "x") }.to raise_error(Workspace::Error) { |e| error = e }
      expect(error.details).to include("taken" => ["branch_conflict"], "conflicting_branch" => "x/y")
    end

    it "does not count the branch being renamed as a conflict" do
      expect(plan.call(workspace: workspace, new: "feat/a/b").new_branch).to eq("feat/a/b")
    end

    it "puts the new names in rename_target_taken's details, and the notes path apart" do
      sh("branch", "feat/b")
      expect(refusal("rename_target_taken").details).to include("new_workspace" => "api.worktree-feat-b", "new_branch" => "feat/b",
        "new_path" => File.join(repo, ".worktrees", "feat-b"))
      expect(refusal("rename_target_taken").details).not_to include("notes_path")
    end

    it "names the notes path apart from the checkout's new path" do
      FileUtils.mkdir_p(File.join(main_notes, "feat-b"))
      File.write(File.join(main_notes, "feat-b", "other.md"), "theirs")

      expect(refusal("rename_target_taken").details).to include("new_path" => File.join(repo, ".worktrees", "feat-b"),
        "notes_path" => File.join(main_notes, "feat-b"))
    end

    it "counts the temporary name the config is written under against the limit" do
      fits_alone = "x" * (255 - "workspace.api.worktree-.yml".bytesize)

      error = nil
      expect { plan.call(workspace: workspace, new: fits_alone) }.to raise_error(Workspace::Error) { |e| error = e }
      expect(error.code).to eq("rename_invalid_name")
      expect(error.details).to include("reason" => "too_long", "bytes" => 255 + 1 + 1 + 10 + 4)
    end

    it "takes the longest name whose temporary name fits" do
      fits = "x" * (255 - ".workspace.api.worktree-.yml..tmp".bytesize - 10)

      expect(plan.call(workspace: workspace, new: fits).new_branch).to eq(fits)
    end

    describe "files left under the new name" do
      let(:new_workspace) { "api.worktree-feat-b" }

      def leave(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "left")
      end

      {
        "project_settings" => ->(dir, name) { File.join(dir, "projects", "#{name}.yml") },
        "socket" => ->(dir, name) { File.join(dir, "run", "#{name}.sock") },
        "agent_log" => ->(dir, name) { File.join(dir, "run", "#{name}.log") },
        "inbox" => ->(dir, name) { File.join(dir, "inbox", "#{name}.json") },
        "hook_events" => ->(dir, name) { File.join(dir, "events", "#{name}.jsonl") }
      }.each do |taken, path_of|
        it "refuses #{taken}, with its path" do
          path = path_of.call(@dir, new_workspace)
          leave(path)

          error = refusal("rename_target_taken")

          expect(error.details).to include("taken" => [taken], "paths" => {taken => path})
        end
      end

      it "gives a delete for logs and a socket, quoted" do
        leave(File.join(@dir, "run", "#{new_workspace}.log"))
        leave(File.join(@dir, "events", "#{new_workspace}.jsonl"))

        expect(refusal("rename_target_taken").details["fix"]).to eq("rm #{Shellwords.escape(File.join(@dir, "run", "#{new_workspace}.log"))} #{Shellwords.escape(File.join(@dir, "events", "#{new_workspace}.jsonl"))}")
      end

      it "gives no delete while something a person wrote is in the way" do
        leave(File.join(@dir, "run", "#{new_workspace}.log"))
        leave(File.join(@dir, "inbox", "#{new_workspace}.json"))

        expect(refusal("rename_target_taken").details).not_to have_key("fix")
      end

      it "gives no delete while another name is taken" do
        leave(File.join(@dir, "run", "#{new_workspace}.log"))
        allow(tmux).to receive(:session_exists?).with("api-wt-feat-b").and_return(true)
        allow(tmux).to receive(:session_exists?).with("api-wt-feat-a").and_return(false)

        expect(refusal("rename_target_taken").details).not_to have_key("fix")
      end
    end

    it "says how to clear a journal whose checkouts are both gone" do
      journal = ->(_workspace) { {"workspace" => workspace, "new_branch" => "feat/b", "path" => File.join(@dir, "gone-a"), "new_path" => File.join(@dir, "gone-b")} }
      stuck = described_class.new(git: git, project_config: project_config, config: config, tmux: tmux, state: state, notes: notes,
        notes_dir: notes_dir, workflow_engine: engine, journal: journal)

      expect { stuck.call(workspace: workspace, new: "feat/b", resume: true) }.to raise_error(Workspace::Error) { |e|
        file = File.join(@dir, "renames", "#{workspace}.json")
        expect(e.code).to eq("rename_in_progress")
        expect(e.details).to include("path" => file, "rerun" => false, "fix" => "rm #{Shellwords.escape(file)}")
      }
    end

    it "refuses a new name whose config file name passes 255 bytes" do
      long = "x" * 250
      error = nil
      expect { plan.call(workspace: workspace, new: long) }.to raise_error(Workspace::Error) { |e| error = e }
      expect(error.code).to eq("rename_invalid_name")
      expect(error.details).to include("reason" => "too_long", "limit" => 255)
    end

    it "reports a journal before the branch being unchanged" do
      journal = ->(_workspace) { {"new_branch" => "feat/a"} }
      crashed = described_class.new(git: git, project_config: project_config, config: config, tmux: tmux, state: state, notes: notes,
        notes_dir: notes_dir, workflow_engine: engine, journal: journal)

      expect { crashed.call(workspace: workspace, new: "feat/a") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_in_progress") }
    end

    it "gives the next step of a recoverable refusal" do
      allow(tmux).to receive(:session_exists?).with("api-wt-feat-a").and_return(true)
      expect(refusal("workspace_running").details).to include("fix" => "workspace stop #{workspace}", "session" => "api-wt-feat-a")

      allow(tmux).to receive(:session_exists?).with("api-wt-feat-a").and_return(false)
      allow(config).to receive(:agent_running?).and_return(true)
      expect(refusal("workspace_running").details).to include("session" => "api-wt-feat-a", "reason" => "agent", "fix" => "workspace stop #{workspace}")
    end

    it "names the unlock command for a locked worktree" do
      sh("worktree", "lock", linked)

      expect(refusal("rename_locked_worktree").details["fix"]).to eq("git worktree unlock #{linked}")
    end

    context "with the devenv lock held" do
      let(:dev_lock) { ->(path) { path == linked } }

      it "names the dev down command" do
        expect(refusal("dev_lock_held").details).to include("fix" => "workspace dev down #{workspace}")
      end
    end

    it "asks for a rerun when a rename is in progress" do
      journal = ->(_workspace) { {"new_branch" => "feat/b"} }
      crashed = described_class.new(git: git, project_config: project_config, config: config, tmux: tmux, state: state, notes: notes,
        notes_dir: notes_dir, workflow_engine: engine, journal: journal)

      expect { crashed.call(workspace: workspace, new: "other") }.to raise_error(Workspace::Error) { |e| expect(e.details).to include("new_branch" => "feat/b", "rerun" => true) }
    end

    it "names the workspace in the detached head, rebase and missing checkout details" do
      git_dir = sh("rev-parse", "--absolute-git-dir", dir: linked).strip
      FileUtils.mkdir_p(File.join(git_dir, "rebase-merge"))
      expect(refusal("rebase_in_progress").details).to include("workspace" => workspace)
      FileUtils.rm_rf(File.join(git_dir, "rebase-merge"))

      sh("checkout", "-q", "--detach", dir: linked)
      expect(refusal("detached_head").details).to include("workspace" => workspace)

      FileUtils.rm_rf(linked)
      expect(refusal("checkout_missing").details).to include("workspace" => workspace)
    end

    it "refuses a stopped rebase" do
      git_dir = sh("rev-parse", "--absolute-git-dir", dir: linked).strip
      FileUtils.mkdir_p(File.join(git_dir, "rebase-merge"))

      expect(refusal("rebase_in_progress").details).to include("path" => linked)
    end

    it "refuses a detached HEAD" do
      sh("checkout", "-q", "--detach", dir: linked)

      refusal("detached_head")
    end
  end

  describe "resume: true with files under both names" do
    let(:journal) { ->(_workspace) { {"new_branch" => "feat/b", "path" => linked} } }

    before do
      FileUtils.mkdir_p(File.join(@dir, "run"))
      FileUtils.mkdir_p(File.join(@dir, "events"))
      File.write(File.join(@dir, "run", "api.worktree-feat-b.log"), "moved")
      File.write(File.join(@dir, "events", "api.worktree-feat-b.jsonl"), "launch")
    end

    def plan_it = plan.call(workspace: workspace, new: "feat/b", resume: true, old_branch: "feat/a")

    it "takes a log that moved as the rename's own" do
      expect(plan_it.resume).to be(true)
    end

    it "refuses a log still under both names" do
      File.write(File.join(@dir, "run", "#{workspace}.log"), "old")

      expect(refusal("rename_target_taken", resume: true, old_branch: "feat/a").details["taken"]).to eq(["agent_log"])
    end

    it "leaves an event log under both names for the step to join" do
      File.write(File.join(@dir, "events", "#{workspace}.jsonl"), "old")

      expect(plan_it.resume).to be(true)
    end
  end

  describe "resume: true" do
    let(:journal) { ->(_workspace) { {"new_branch" => "feat/b"} } }
    let(:moved) { File.join(repo, ".worktrees", "feat-b") }

    def move_checkout
      FileUtils.mv(linked, moved, force: true)
      sh("worktree", "repair", moved)
    end

    it "keeps the full taken check while the old path still exists" do
      FileUtils.mkdir_p(moved)

      error = refusal("rename_target_taken", resume: true, old_branch: "feat/a")
      expect(error.details["taken"]).to eq(["directory"])
    end

    it "checks the target notes directory while the old path still exists" do
      FileUtils.mkdir_p(File.join(main_notes, "feat-b"))
      File.write(File.join(main_notes, "feat-b", "other.md"), "theirs")

      expect(refusal("rename_target_taken", resume: true, old_branch: "feat/a").details).to include("taken" => ["notes_target"])
    end

    it "checks the target branch while the old path still exists" do
      sh("branch", "feat/b")

      expect(refusal("rename_target_taken", resume: true, old_branch: "feat/a").details["taken"]).to eq(["branch"])
    end

    it "skips the branch check once the branch is already the new one" do
      sh("branch", "-m", "feat/a", "feat/b", dir: linked)

      result = plan.call(workspace: workspace, new: "feat/b", resume: true, old_branch: "feat/a")

      expect(result).to have_attributes(branch: "feat/a", new_branch: "feat/b", resume: true)
    end

    it "skips the directory and the branch once moved, and reads the checkout from the new path" do
      move_checkout
      sh("branch", "-m", "feat/a", "feat/b", dir: moved)
      FileUtils.mkdir_p(File.join(main_notes, "feat-b"))
      allow(journal).to receive(:call).and_return({"new_branch" => "feat/b", "notes" => {"action" => "move", "from" => current_notes, "to" => File.join(main_notes, "feat-b")}})

      result = plan.call(workspace: workspace, new: "feat/b", resume: true, old_branch: "feat/a")

      expect(result.new_path).to eq(moved)
    end

    context "with the first run's journal" do
      let(:recorded) do
        {"new_branch" => "feat/b", "branch" => "feat/a", "path" => linked, "new_path" => moved, "new_workspace" => "api.worktree-recorded", "session" => "recorded-old",
         "new_session" => "recorded-new", "notes" => {"action" => "with_checkout", "from" => "/old/n", "to" => "/new/n", "reason" => nil, "problem" => nil}}
      end
      let(:journal) { ->(_workspace) { recorded } }
      let(:result) { plan.call(workspace: workspace, new: "feat/b", resume: true, old_branch: "feat/a") }

      before do
        move_checkout
        allow(project_config).to receive(:project_root_for).with(workspace).and_return(nil)
      end

      it "goes by its names and path, with the old config gone" do
        expect(result).to have_attributes(path: linked, new_workspace: "api.worktree-recorded", session: "recorded-old", new_session: "recorded-new")
      end

      it "takes its notes decision without resolving anything" do
        allow(notes).to receive(:info).and_raise("not called")

        expect(result.notes).to have_attributes(action: "with_checkout", from: "/old/n", to: "/new/n")
      end

      it "keeps a problem it recorded for the warning" do
        recorded["notes"] = {"action" => "stays", "from" => nil, "to" => nil, "reason" => "unresolved", "problem" => "x: y"}

        expect(result.warnings.map { |warning| warning["code"] }).to include("notes_unresolved")
      end

      it "refuses a daemon running under the new name" do
        allow(config).to receive(:agent_running?).with("api.worktree-recorded").and_return(true)

        expect { result }.to raise_error(Workspace::Error) { |e| expect(e.details).to include("workspace" => "api.worktree-recorded", "reason" => "agent") }
      end

      it "counts each store under the new name as its own once the old one is gone" do
        allow(project_config).to receive(:existing_name).with("api.worktree-recorded").and_return("api.worktree-recorded")
        allow(state).to receive(:keys).and_return(["api.worktree-recorded"])
        FileUtils.mkdir_p(File.join(@dir, "state", "api.worktree-recorded"))

        expect(result.new_workspace).to eq("api.worktree-recorded")
      end

      it "calls each store a conflict while the old one is there too" do
        allow(project_config).to receive(:existing_name).and_return("taken")
        allow(state).to receive(:keys).and_return([workspace, "api.worktree-recorded"])
        FileUtils.mkdir_p(File.join(@dir, "state", "api.worktree-recorded"))
        FileUtils.mkdir_p(File.join(@dir, "state", workspace))

        expect { result }.to raise_error(Workspace::Error) { |e| expect(e.details["taken"]).to eq(%w[config state_key state_dir]) }
      end
    end

    it "still refuses a config another workspace took, once moved" do
      move_checkout
      allow(project_config).to receive(:existing_name).and_return("api.worktree-feat-b")

      expect(refusal("rename_target_taken", resume: true, old_branch: "feat/a").details["taken"]).to eq(["config"])
    end

    it "finds notes outside the checkout after the move, with the old path gone" do
      move_checkout
      allow(notes).to receive(:info) do |name:, root: nil|
        raise Workspace::Error.new("old path gone", code: "notes_dir_unresolved") unless root == moved
        {"dir" => current_notes}
      end

      result = plan.call(workspace: workspace, new: "feat/b", resume: true, old_branch: "feat/a")

      expect(result.notes).to have_attributes(action: "move", from: current_notes, to: File.join(main_notes, "feat-b"))
    end

    it "treats notes inside a moved checkout as going with it" do
      move_checkout
      allow(notes).to receive(:info).and_return({"dir" => File.join(moved, "tmp", "workspace-notes")})

      expect(plan.call(workspace: workspace, new: "feat/b", resume: true, old_branch: "feat/a").notes.action).to eq("with_checkout")
    end

    it "still refuses a journal for another name" do
      expect { plan.call(workspace: workspace, new: "other", resume: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rename_in_progress") }
    end

    it "still refuses a running workspace" do
      allow(config).to receive(:agent_running?).and_return(true)

      refusal("workspace_running", resume: true)
    end
  end

  describe ".transcripts?" do
    it "finds the directory Claude Code names after the path" do
      FileUtils.mkdir_p(File.join(@dir, ".claude", "projects", "-a-b-c"))

      expect(described_class.transcripts?("/a/b.c", home: @dir)).to be(true)
      expect(described_class.transcripts?("/a/b/d", home: @dir)).to be(false)
    end

    it "matches the front of a long name, which ends in a hash" do
      path = "/" + ("x" * 250)
      FileUtils.mkdir_p(File.join(@dir, ".claude", "projects", path.gsub(/[^A-Za-z0-9]/, "-")[0, 200] + "-abc123"))

      expect(described_class.transcripts?(path, home: @dir)).to be(true)
    end
  end
end
