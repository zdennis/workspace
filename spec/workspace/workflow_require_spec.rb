require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowRequire do
  around do |example|
    Dir.mktmpdir("wf-require") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "repo") }
  let(:artifacts) { File.join(@dir, "artifacts") }
  let(:notes) { File.join(@dir, "notes") }
  let(:notes_dir) { notes }
  let(:guard) { Workspace::WorkflowGuard.new }
  subject(:requirer) { described_class.new(guard: guard, notes_dir_of: ->(_workspace) { notes_dir }) }

  def git(*args)
    system({"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"}, "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com",
      "-c", "commit.gpgsign=false", "-c", "maintenance.auto=false", "-c", "gc.auto=0", *args, out: File::NULL, exception: true)
  end

  before do
    FileUtils.mkdir_p([repo, artifacts, notes])
    File.write(File.join(repo, "a.txt"), "one\n")
    git("init", "-q", "-b", "main")
    git("add", "-A")
    git("commit", "-q", "-m", "start")
  end

  let!(:base) { guard.head(repo) }
  let(:run) { {"worktree" => repo, "artifacts_dir" => artifacts, "workspace" => "app"} }

  def check(*proofs, attempt: {"head" => {"before" => base}})
    requirer.check(run: run, step: {"require" => proofs}, attempt: attempt)
  end

  # A proof the engine runs outside the lock, carried through both halves.
  def proven(entry, attempt:)
    found = requirer.check(run: run, step: {"require" => [entry]}, attempt: attempt)
    return found unless found&.key?("outside")
    requirer.run_outside(found["outside"], cwd: repo, env: {"X" => "1"}, stop_when: stop_when)["unmet"]
  end

  let(:stop_when) { -> { false } }

  def commit
    git("commit", "-q", "--allow-empty", "-m", "more")
  end

  it "passes a step with no require" do
    expect(requirer.check(run: run, step: {}, attempt: {})).to be_nil
  end

  describe "commits" do
    it "passes with enough commits since the attempt began" do
      commit
      expect(check({"commits" => 1})).to be_nil
    end

    it "fails saying what was required and found" do
      expect(check({"commits" => 1})).to include("proof" => "commits", "code" => "require_commits", "required" => 1, "found" => 0, "base" => base,
        "detail" => "required 1 commit since #{base[0, 7]}, found 0")
      commit
      expect(check({"commits" => 2})).to include("detail" => "required 2 commits since #{base[0, 7]}, found 1")
    end

    it "fails as unproven with no recorded starting commit" do
      commit
      expect(check({"commits" => 1}, attempt: {})).to include("unproven" => true, "detail" => /no recorded starting commit/)
      expect(check({"commits" => 1}, attempt: {"head" => {"before" => nil}})).to include("unproven" => true)
    end

    it "does not count commits that arrive by merge" do
      git("checkout", "-q", "-b", "other")
      File.write(File.join(repo, "o.txt"), "o\n")
      git("add", "-A")
      git("commit", "-q", "-m", "other")
      git("checkout", "-q", "main")
      git("merge", "-q", "--no-ff", "-m", "merge", "other")
      expect(check({"commits" => 1})).to include("found" => 0, "detail" => /found 0/)
    end

    it "fails as unproven, with a reason, when the base is no longer an ancestor of HEAD" do
      commit
      git("reset", "-q", "--hard", "HEAD~1")
      git("commit", "-q", "--amend", "--allow-empty", "-m", "rewritten")
      expect(check({"commits" => 1})).to include("code" => "require_commits", "unproven" => true, "reason" => "history_rewritten",
        "detail" => /not an ancestor of HEAD/)
    end

    it "fails as unproven when git can't answer the ancestor check" do
      allow(guard).to receive(:commits_since).and_return(nil)
      expect(check({"commits" => 1})).to include("unproven" => true, "detail" => /could not count/)
    end

    it "fails as unproven when git does not know the base" do
      expect(check({"commits" => 1}, attempt: {"head" => {"before" => "a" * 40}})).to include("unproven" => true, "detail" => /could not count/)
    end
  end

  describe "nonempty" do
    it "passes a regular file with content" do
      File.write(File.join(artifacts, "implement.md"), "done\n")
      expect(check({"nonempty" => "implement.md"})).to be_nil
    end

    it "fails on a missing, an empty, a linked and a directory path" do
      expect(check({"nonempty" => "implement.md"})).to include("code" => "require_nonempty", "detail" => "required implement.md to be non-empty, found it missing")
      File.write(File.join(artifacts, "implement.md"), "")
      expect(check({"nonempty" => "implement.md"})).to include("detail" => /found it empty/)
      File.write(File.join(@dir, "real.md"), "x")
      File.symlink(File.join(@dir, "real.md"), File.join(artifacts, "link.md"))
      expect(check({"nonempty" => "link.md"})).to include("detail" => /a symbolic link/)
      FileUtils.mkdir_p(File.join(artifacts, "dir.md"))
      expect(check({"nonempty" => "dir.md"})).to include("detail" => /not a regular file/)
    end

    it "is unproven with no artifacts directory recorded, and never reads a path from the root" do
      run["artifacts_dir"] = nil
      expect(check({"nonempty" => "implement.md"})).to include("unproven" => true, "detail" => /no artifacts directory/)
      run["artifacts_dir"] = ""
      expect(check({"nonempty" => "implement.md"})).to include("unproven" => true)
    end

    it "fails a file reached through a linked parent directory, but passes a real subdirectory" do
      FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
      File.write(File.join(@dir, "elsewhere", "x.md"), "x")
      File.symlink(File.join(@dir, "elsewhere"), File.join(artifacts, "sub"))
      expect(check({"nonempty" => "sub/x.md"})).to include("detail" => /outside the artifacts directory/)
      FileUtils.mkdir_p(File.join(artifacts, "real"))
      File.write(File.join(artifacts, "real", "x.md"), "x")
      expect(check({"nonempty" => "real/x.md"})).to be_nil
    end

    it "passes when the artifacts directory is itself reached through a link" do
      File.symlink(artifacts, File.join(@dir, "alias"))
      File.write(File.join(artifacts, "x.md"), "x")
      run["artifacts_dir"] = File.join(@dir, "alias")
      expect(check({"nonempty" => "x.md"})).to be_nil
    end

    it "is unproven when the file can't be resolved" do
      File.write(File.join(artifacts, "x.md"), "x")
      allow(File).to receive(:realpath).and_raise(Errno::EACCES)
      expect(check({"nonempty" => "x.md"})).to include("unproven" => true, "detail" => /could not be read/)
    end
  end

  describe "plan_status" do
    def plan(status)
      File.write(File.join(notes, "IMPLEMENTATION_PLAN.md"), "---\nplan: 1\nstatus: #{status}\n---\n\n## Tasks\n\n- [ ] T1 One\n")
    end

    it "passes when the plan's status is the one required" do
      plan("done")
      expect(check({"plan_status" => "done"})).to be_nil
    end

    it "fails naming the status found" do
      plan("active")
      expect(check({"plan_status" => "done"})).to include("code" => "require_plan_status", "detail" => "required plan status done, found active")
    end

    it "fails as unproven on a missing, unknown or malformed status, even for active" do
      File.write(File.join(notes, "IMPLEMENTATION_PLAN.md"), "---\nplan: 1\n---\n\n## Tasks\n\n- [ ] T1 One\n")
      expect(check({"plan_status" => "active"})).to include("unproven" => true, "detail" => /status: is missing/)
      ["finished", "ACTIVE", "[active]"].each do |value|
        plan(value)
        expect(check({"plan_status" => "active"})).to include("unproven" => true, "detail" => /not one of active, paused, done/)
      end
      File.write(File.join(notes, "IMPLEMENTATION_PLAN.md"), "no frontmatter\n\n## Tasks\n\n- [ ] T1 One\n")
      expect(check({"plan_status" => "active"})).to include("unproven" => true)
    end

    it "fails when there is no plan" do
      expect(check({"plan_status" => "done"})).to include("detail" => /found no IMPLEMENTATION_PLAN.md/)
    end

    it "fails as unproven when the notes directory can't be found or the plan can't be read" do
      plan("done")
      File.chmod(0o000, File.join(notes, "IMPLEMENTATION_PLAN.md"))
      expect(check({"plan_status" => "done"})).to include("unproven" => true) unless Process.uid.zero?
      File.chmod(0o644, File.join(notes, "IMPLEMENTATION_PLAN.md"))
      requirer = described_class.new(guard: guard, notes_dir_of: ->(_workspace) {})
      expect(requirer.check(run: run, step: {"require" => [{"plan_status" => "done"}]}, attempt: {})).to include("unproven" => true)
    end
  end

  describe "tracked_clean" do
    it "passes a clean checkout, untracked files included" do
      File.write(File.join(repo, "new.txt"), "x")
      expect(check({"tracked_clean" => true})).to be_nil
    end

    context "with the config changed since the run's base" do
      let(:marker) { File.join(@dir, "ran") }

      before do
        git("config", "filter.up.clean", "tr a-z A-Z")
        File.write(File.join(repo, ".gitattributes"), "a.txt filter=up\n")
        git("add", ".gitattributes")
        git("add", "--renormalize", ".")
        git("commit", "-q", "-m", "filter")
      end

      let(:started) { run.merge(guard.base(repo)) }

      def tracked_clean(with)
        stamp = Time.now - 300
        File.utime(stamp, stamp, File.join(repo, "a.txt"))
        requirer.check(run: with, step: {"require" => [{"tracked_clean" => true}]}, attempt: {"head" => {"before" => base}})
      end

      it "passes after a harmless change, the project's filter still working" do
        started
        git("config", "branch.main.remote", "origin")

        expect(tracked_clean(started)).to be_nil
      end

      it "fails with a changed filter turned off, and never runs it" do
        started
        File.write(File.join(@dir, "planted.sh"), "#!/bin/sh\ntouch #{marker}\ncat\n")
        File.chmod(0o755, File.join(@dir, "planted.sh"))
        git("config", "filter.up.clean", File.join(@dir, "planted.sh"))

        expect(tracked_clean(started)).to include("code" => "require_tracked_clean", "paths" => ["a.txt"])
        expect(File.exist?(marker)).to be(false)
      end
    end

    it "fails naming the changed tracked paths" do
      File.write(File.join(repo, "a.txt"), "changed\n")
      expect(check({"tracked_clean" => true})).to include("code" => "require_tracked_clean", "paths" => ["a.txt"], "detail" => /found 1 \(a.txt\)/)
    end

    it "fails while a rebase, merge, cherry-pick, revert or bisect is in progress" do
      %w[MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG].each do |name|
        File.write(File.join(repo, ".git", name), "x\n")
        expect(check({"tracked_clean" => true})).to include("code" => "require_tracked_clean", "detail" => /in progress/)
        File.delete(File.join(repo, ".git", name))
      end
      FileUtils.mkdir_p(File.join(repo, ".git", "rebase-merge"))
      expect(check({"tracked_clean" => true})).to include("detail" => /in progress/)
    end

    it "does not see an assume-unchanged file" do
      git("update-index", "--assume-unchanged", "a.txt")
      File.write(File.join(repo, "a.txt"), "changed\n")
      expect(check({"tracked_clean" => true})).to be_nil
    end

    it "fails as unproven when git can't answer" do
      run["worktree"] = File.join(@dir, "gone")
      expect(check({"tracked_clean" => true})).to include("unproven" => true)
    end
  end

  describe "a walk over the list" do
    let(:commands) { instance_double(Workspace::CommandsConfig, for_project: {test: "bin/test"}) }
    let(:checker) { instance_double(Workspace::WorkflowCheck) }
    subject(:requirer) { described_class.new(guard: guard, notes_dir_of: ->(_) { notes }, commands_config: commands, checker: checker) }
    let(:step) { {"require" => [{"tracked_clean" => true}, {"command" => "test"}, {"commits" => 1}]} }

    it "stops at the first proof to run outside the lock, runs nothing, and says where" do
      expect(requirer.check(run: run.merge("current" => "build"), step: step, attempt: {"n" => 1})["outside"]).to match(
        "proof" => "command", "role" => "test", "command" => "bin/test", "index" => 1, "token" => /\A\h{8}\z/,
        "log" => %r{/steps/build\.1\.require-test\.\h{8}\.log\z}, "timeout" => described_class::COMMAND_TIMEOUT
      )
    end

    it "fails an earlier proof first" do
      File.write(File.join(repo, "a.txt"), "two\n")
      expect(requirer.check(run: run, step: step, attempt: {"n" => 1})).to include("code" => "require_tracked_clean")
    end

    it "goes on from the entry it is given" do
      expect(requirer.check(run: run, step: step, attempt: {"head" => {"before" => base}}, from: 2)).to include("code" => "require_commits")
    end

    it "answers require_unknown when a proof outside the lock raises" do
      allow(checker).to receive(:call).and_raise(ArgumentError, "boom")
      pending_proof = {"proof" => "command", "role" => "test", "command" => "x", "log" => "/l", "timeout" => 1}
      expect(requirer.run_outside(pending_proof, cwd: repo)).to include("record" => {"error" => "ArgumentError: boom"}, "unmet" => hash_including("code" => "require_unknown", "unproven" => true))
    end
  end

  describe "command" do
    let(:commands) { instance_double(Workspace::CommandsConfig, for_project: {test: "bin/test", lint: nil}) }
    let(:checker) { instance_double(Workspace::WorkflowCheck, call: {exit_code: 0, timed_out: false}) }
    subject(:requirer) { described_class.new(guard: guard, notes_dir_of: ->(_) { notes }, commands_config: commands, checker: checker) }

    before { run.merge!("id" => "wr_1", "project" => "app", "current" => "build", "base_sha" => "b" * 40) }

    it "passes when the project's command exits 0, run in the checkout with the given environment, stop and time limit" do
      expect(proven({"command" => "test"}, attempt: {"n" => 2})).to be_nil
      expect(checker).to have_received(:call).with(command: "bin/test", cwd: repo, timeout: described_class::COMMAND_TIMEOUT,
        log: %r{/steps/build\.2\.require-test\.\h{8}\.log\z}, env: {"X" => "1"}, stop_when: stop_when)
    end

    it "fails with the exit code and the log" do
      allow(checker).to receive(:call).and_return({exit_code: 3, timed_out: false})
      expect(proven({"command" => "test"}, attempt: {"n" => 1})).to include("proof" => "command", "code" => "require_command", "exit_code" => 3,
        "log" => %r{/steps/build\.1\.require-test\.\h{8}\.log\z}, "detail" => /exit 3 \(log .*build\.1\.require-test\.\h{8}\.log\)/)
        .and(satisfy { |found| !found.key?("unproven") })
    end

    it "is unproven when the command is not set, and runs nothing" do
      expect(check({"command" => "lint"}, attempt: {"n" => 1})).to include("code" => "require_command", "unproven" => true, "detail" => /not set/)
      expect(checker).not_to have_received(:call)
    end

    it "reads an optional command written before its command: key, as the definition stores it" do
      yaml = "steps:\n  build:\n    prompt: B.\n    require:\n      - optional: true\n        command: lint\n"
      step = Workspace::WorkflowDefinition.parse(yaml, id: "demo", source: "global", path: "/defs/demo.yml").steps.first

      expect(requirer.check(run: run, step: step, attempt: {"n" => 1})).to eq("skipped" => {"proof" => "command", "role" => "lint", "skipped" => "command_unset", "optional" => true, "index" => 0})
    end

    it "is unproven on a timeout or a check that could not run" do
      allow(checker).to receive(:call).and_return({exit_code: nil, timed_out: true})
      expect(proven({"command" => "test"}, attempt: {"n" => 1})).to include("unproven" => true, "detail" => /ran past 300 seconds/)
      allow(checker).to receive(:call).and_return({exit_code: nil, timed_out: false, error: "could not run the check (Errno::ENOENT)"})
      expect(proven({"command" => "test"}, attempt: {"n" => 1})).to include("unproven" => true, "detail" => /could not run the check/)
    end

    it "gives each run of the proof its own token and log" do
      runs = Array.new(2) { requirer.check(run: run, step: {"require" => [{"command" => "test"}]}, attempt: {"n" => 1})["outside"] }
      expect(runs.map { |each| each["token"] }.uniq.size).to eq(2)
      expect(runs.map { |each| each["log"] }.uniq.size).to eq(2)
    end

    it "keeps the result for the attempt" do
      allow(checker).to receive(:call).and_return({exit_code: 3, timed_out: false})
      pending_proof = requirer.check(run: run, step: {"require" => [{"command" => "test"}]}, attempt: {"n" => 1})["outside"]
      expect(requirer.run_outside(pending_proof, cwd: repo)["record"]).to eq("exit_code" => 3, "timed_out" => false)
    end

    it "is unproven with no checker wired" do
      bare = described_class.new(guard: guard, notes_dir_of: ->(_) { notes })
      expect(bare.check(run: run, step: {"require" => [{"command" => "test"}]}, attempt: {})).to include("code" => "require_command", "unproven" => true)
    end
  end

  describe "inbox_item" do
    let(:started) { "2026-10-04T12:00:00.500Z" }
    let(:attempt) { {"started_at" => started} }
    let(:items) { [{"dedupe_key" => "verify:wr_1", "state" => "done", "updated_at" => "2026-10-04T12:05:00Z"}] }
    let(:inboxes) { {} }
    subject(:requirer) do
      described_class.new(guard: guard, notes_dir_of: ->(_) { notes },
        inbox_for: ->(workspace) { inboxes[workspace] = instance_double(Workspace::InboxStore, list: items) })
    end

    before { run.merge!("id" => "wr_1", "inputs" => {"task" => "x"}) }

    it "passes when the workspace's inbox holds an item with the rendered key, in any state" do
      expect(check({"inbox_item" => "verify:{{run}}"}, attempt: attempt)).to be_nil
      expect(inboxes.keys).to eq(["app"])
    end

    it "renders {{workspace}} and {{inputs.NAME}}" do
      items.replace([{"dedupe_key" => "app-x", "updated_at" => "2026-10-04T12:05:00Z"}])
      expect(check({"inbox_item" => "{{workspace}}-{{inputs.task}}"}, attempt: attempt)).to be_nil
    end

    it "fails, naming the key and the scope it searched, when there is no such item" do
      expect(check({"inbox_item" => "other:{{run}}"}, attempt: attempt)).to include("code" => "require_inbox_item",
        "detail" => /other:wr_1 in workspace app's inbox, found none \(an item added with --project or --global/)
    end

    it "does not count an item left from before the attempt, and says how to post over a closed one" do
      items.first["updated_at"] = "2026-10-04T11:59:59Z"
      expect(check({"inbox_item" => "verify:{{run}}"}, attempt: attempt)).to include("code" => "require_inbox_item",
        "detail" => /last updated at "2026-10-04T11:59:59Z".*--reopen/)
    end

    it "counts an item stamped in the second the attempt began: the store keeps whole seconds" do
      items.first["updated_at"] = "2026-10-04T12:00:00Z"
      expect(check({"inbox_item" => "verify:{{run}}"}, attempt: attempt)).to be_nil
    end

    it "does not count an item with no readable update time" do
      items.first.delete("updated_at")
      expect(check({"inbox_item" => "verify:{{run}}"}, attempt: attempt)).to include("code" => "require_inbox_item")
    end

    it "is unproven when the key renders to something that is not a dedupe key, or no inbox is wired" do
      run["inputs"] = {"task" => "has space"}
      expect(check({"inbox_item" => "k:{{inputs.task}}"}, attempt: attempt)).to include("unproven" => true, "detail" => /not a valid dedupe key/)
      bare = described_class.new(guard: guard, notes_dir_of: ->(_) { notes })
      expect(bare.check(run: run, step: {"require" => [{"inbox_item" => "a"}]}, attempt: {})).to include("unproven" => true)
    end

    context "with a real store" do
      let(:clock) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
      let(:store) { Workspace::InboxStore.new(path: File.join(@dir, "inbox.json"), clock: -> { clock.first }) }
      subject(:requirer) { described_class.new(guard: guard, notes_dir_of: ->(_) { notes }, inbox_for: ->(_) { store }) }
      let(:record) { {"title" => "t", "dedupe_key" => "verify:wr_1"} }

      it "passes after the item is closed during the attempt, and after a re-post to a live item" do
        store.upsert(record)
        clock[0] += 60
        store.transition_by_key("verify:wr_1", to: "done")
        expect(check({"inbox_item" => "verify:wr_1"}, attempt: {"started_at" => "2026-10-04T12:00:30.000Z"})).to be_nil
        store.upsert(record, reopen: true)
        clock[0] += 60
        store.upsert(record)
        expect(check({"inbox_item" => "verify:wr_1"}, attempt: {"started_at" => "2026-10-04T12:01:30.000Z"})).to be_nil
      end

      it "does not pass on a post to a closed item without --reopen, which changes nothing" do
        store.upsert(record)
        store.transition_by_key("verify:wr_1", to: "done")
        clock[0] += 60
        expect(store.upsert(record).outcome).to eq("suppressed")
        expect(check({"inbox_item" => "verify:wr_1"}, attempt: {"started_at" => "2026-10-04T12:00:30.000Z"})).to include("detail" => /--reopen/)
      end
    end
  end

  describe "remote_unchanged" do
    let(:before_state) { {"remote" => "origin", "ref" => "refs/heads/main", "sha" => "a" * 40} }
    let(:attempt) { {"remote" => before_state} }

    it "reads nothing while the run's lock is held" do
      allow(guard).to receive(:remote_head)
      expect(check({"remote_unchanged" => true}, attempt: attempt)["outside"]).to include("proof" => "remote_unchanged", "index" => 0, "before" => before_state)
      expect(guard).not_to have_received(:remote_head)
    end

    it "passes when the branch on the remote is where it was" do
      allow(guard).to receive(:remote_head).with(repo).and_return(before_state.dup)
      expect(proven({"remote_unchanged" => true}, attempt: attempt)).to be_nil
    end

    it "fails with both shas when the remote branch moved or was created" do
      allow(guard).to receive(:remote_head).and_return(before_state.merge("sha" => "b" * 40))
      expect(proven({"remote_unchanged" => true}, attempt: attempt)).to include("code" => "require_remote_unchanged", "before" => "a" * 40, "after" => "b" * 40,
        "detail" => "required refs/heads/main on origin to stay at aaaaaaa, found bbbbbbb")
      allow(guard).to receive(:remote_head).and_return(before_state.merge("sha" => nil))
      expect(proven({"remote_unchanged" => true}, attempt: attempt)).to include("detail" => /found \(absent\)/)
    end

    it "is unproven with its own code when the remote can't be read now, naming the credential it needs" do
      allow(guard).to receive(:remote_head).and_return({"unread" => "unreachable"})
      expect(proven({"remote_unchanged" => true}, attempt: attempt)).to include("code" => "require_remote_unreachable", "unproven" => true,
        "detail" => /non-interactive credential.*credential helper, insteadOf or core\.sshCommand/)
    end

    it "is unproven saying why when the branch has no remote to read now" do
      allow(guard).to receive(:remote_head).and_return({"unread" => "detached_head"})
      expect(proven({"remote_unchanged" => true}, attempt: attempt)).to include("code" => "require_remote_unchanged", "unproven" => true, "detail" => /now HEAD was detached/)
    end

    it "is unproven when the branch came to track something else" do
      allow(guard).to receive(:remote_head).and_return(before_state.merge("ref" => "refs/heads/other"))
      expect(proven({"remote_unchanged" => true}, attempt: attempt)).to include("code" => "require_remote_unchanged", "unproven" => true, "detail" => %r{now tracks refs/heads/other})
    end

    it "is unproven when the attempt recorded no remote state (an older attempt)" do
      allow(guard).to receive(:remote_head)
      expect(check({"remote_unchanged" => true}, attempt: {})).to include("code" => "require_remote_unchanged", "unproven" => true, "detail" => /recorded no remote state/)
      expect(guard).not_to have_received(:remote_head)
    end

    it "does not blame credentials for a repository with no such remote" do
      allow(guard).to receive(:remote_head).and_return({"unread" => "no_remote"})
      found = proven({"remote_unchanged" => true}, attempt: attempt)
      expect(found).to include("code" => "require_remote_unchanged", "unproven" => true, "detail" => /no such remote/)
      expect(found["detail"]).not_to match(/credential/)
    end

    it "says why the attempt has no reading, and reads nothing" do
      allow(guard).to receive(:remote_head)
      expect(check({"remote_unchanged" => true}, attempt: {"remote" => {"unread" => "detached_head"}})).to include("code" => "require_remote_unchanged", "unproven" => true, "detail" => /HEAD was detached/)
      expect(check({"remote_unchanged" => true}, attempt: {"remote" => {"unread" => "local_upstream"}})).to include("detail" => /tracks a local branch/)
      expect(check({"remote_unchanged" => true}, attempt: {"remote" => {"unread" => "unreachable"}})).to include("detail" => /non-interactive credential/)
      expect(guard).not_to have_received(:remote_head)
    end
  end
  it "puts the exception class and message in error when a proof raises" do
    allow(guard).to receive(:commits_since).and_raise("boom")
    expect(check({"commits" => 1})).to include("code" => "require_unknown", "unproven" => true, "error" => "RuntimeError: boom")
  end

  it "stops at the first proof that fails" do
    expect(check({"tracked_clean" => true}, {"commits" => 1}, {"nonempty" => "x.md"})).to include("proof" => "commits")
  end

  describe "exec" do
    let(:test_files) { ["spec/**/*_spec.rb"] }
    let(:commands) { instance_double(Workspace::CommandsConfig, test_files: test_files) }
    let(:calls) { [] }
    let(:answer) { {exit_code: 0, timed_out: false} }
    let(:checker) do
      double(Workspace::WorkflowCheck).tap do |fake|
        allow(fake).to receive(:call) do |**kwargs|
          files = kwargs[:env].select { |name, path| path && name.start_with?("WORKSPACE_") && name.end_with?("FILES", "TESTS") }
          calls << kwargs.merge(lists: files.transform_values { |path| File.binread(path).split("\0") })
          answer
        end
      end
    end
    subject(:requirer) { described_class.new(guard: guard, notes_dir_of: ->(_) { notes }, commands_config: commands, checker: checker) }
    let(:attempt) { {"n" => 2, "head" => {"before" => base}} }

    def exec_entry(text, timeout: 300)
      {"exec" => Workspace::WorkflowArgv.split(text).first, "timeout" => timeout}
    end

    def write(path, text = "x\n")
      FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
      File.write(File.join(repo, path), text)
    end

    before do
      run.merge!("id" => "wr_1", "project" => "app", "current" => "verify", "base_sha" => base, "inputs" => {"task" => "a b;c"})
      write("spec/new_spec.rb")
      write("lib/new.rb")
    end

    it "passes when the program exits 0, run with no shell in the checkout with each placeholder filled in" do
      entry = exec_entry("bin/check {{workspace}} {{run}} {{branch}} {{inputs.task}} {{attempt.head_before}} -- {{changed.files}}")
      expect(proven(entry, attempt: attempt)).to be_nil
      call = calls.first
      expect(call).to include(cwd: repo, timeout: 300, stop_when: stop_when, log: %r{/steps/verify\.2\.require-exec-0\.\h{8}\.log\z})
      expect(call[:argv]).to eq(["bin/check", "app", "wr_1", "main", "a b;c", base, "--", "lib/new.rb", "spec/new_spec.rb"])
      expect(call[:env]).to include("X" => "1")
    end

    it "fails with the exit code, the log and the program as written" do
      answer.replace(exit_code: 4, timed_out: false)
      found = proven(exec_entry("bin/check -- {{changed.files}}"), attempt: attempt)
      expect(found).to include("proof" => "exec", "code" => "require_exec", "program" => "bin/check", "exit_code" => 4,
        "log" => %r{require-exec-0\.\h{8}\.log\z}, "detail" => /required bin\/check to exit 0, found exit 4 \(log /)
      expect(found).not_to have_key("unproven")
    end

    it "is unproven on a timeout, a program that can't start, or no exit" do
      answer.replace(exit_code: nil, timed_out: true)
      expect(proven(exec_entry("bin/check", timeout: 30), attempt: attempt)).to include("unproven" => true, "program" => "bin/check", "detail" => /ran past 30 seconds/)
      answer.replace(exit_code: nil, timed_out: false, error: "could not run the check (Errno::ENOENT)")
      expect(proven(exec_entry("bin/check"), attempt: attempt)).to include("unproven" => true, "detail" => /Errno::ENOENT/)
      answer.replace(exit_code: nil, timed_out: false, error: "stopped: the run moved on")
      expect(proven(exec_entry("bin/check"), attempt: attempt)).to include("unproven" => true, "detail" => /stopped/)
    end

    it "names the list's file and variable when the arguments are too long" do
      answer.replace(exit_code: nil, timed_out: false, error: "could not run the check (Errno::E2BIG)")
      found = proven(exec_entry("bin/check -- {{changed.files}}"), attempt: attempt)
      expect(found).to include("unproven" => true, "detail" => /E2BIG.*\{\{changed\.files\}\} from the file \$WORKSPACE_CHANGED_FILES names instead/)
    end

    it "keeps only the exit code, timeout flag and error as the record" do
      answer.replace(exit_code: 4, timed_out: false)
      pending_proof = requirer.check(run: run, step: {"require" => [exec_entry("bin/check")]}, attempt: attempt)["outside"]
      expect(pending_proof).to include("proof" => "exec", "index" => 0, "program" => "bin/check", "timeout" => 300, "facts" => hash_including("argv" => ["bin/check"]))
      expect(requirer.run_outside(pending_proof, cwd: repo)["record"]).to eq("exit_code" => 4, "timed_out" => false)
    end

    context "with no starting commit" do
      let(:attempt) { {"n" => 1, "head" => {"before" => nil}} }

      it "is unproven and runs nothing when the template uses a list that needs it" do
        expect(proven(exec_entry("bin/check -- {{changed.files}}"), attempt: attempt)).to include("code" => "require_exec", "unproven" => true, "program" => "bin/check",
          "detail" => /\{\{changed\.files\}\} needs the commit this attempt began at, and this attempt has none recorded/)
        run["base_sha"] = ""
        expect(proven(exec_entry("bin/check -- {{run.changed.files}}"), attempt: {"n" => 1, "head" => {"before" => base}}))
          .to include("unproven" => true, "detail" => /\{\{run\.changed\.files\}\} needs the commit the run began at/)
        expect(calls).to be_empty
      end

      it "runs a template that does not use it, without that list's variable" do
        expect(proven(exec_entry("bin/check {{attempt.head_before}}"), attempt: attempt)).to be_nil
        expect(calls.first[:argv]).to eq(["bin/check", ""])
        expect(calls.first[:env].keys).to include("WORKSPACE_RUN_CHANGED_FILES")
        expect(calls.first[:env]).to include("WORKSPACE_CHANGED_FILES" => nil, "WORKSPACE_CHANGED_TESTS" => nil)
      end
    end

    it "points each variable at a file holding its NUL-separated list, and filters changed.tests by the globs" do
      git("add", "-A")
      git("commit", "-q", "-m", "run so far")
      later = guard.head(repo)
      write("spec/later_spec.rb")
      write("spec/deep/nested_spec.rb")
      write("spec_helper_spec.rb")
      expect(proven(exec_entry("bin/check -- {{changed.tests}}"), attempt: {"n" => 1, "head" => {"before" => later}})).to be_nil
      call = calls.first
      expect(call[:lists]).to eq(
        "WORKSPACE_CHANGED_FILES" => ["spec/deep/nested_spec.rb", "spec/later_spec.rb", "spec_helper_spec.rb"],
        "WORKSPACE_RUN_CHANGED_FILES" => ["lib/new.rb", "spec/deep/nested_spec.rb", "spec/later_spec.rb", "spec/new_spec.rb", "spec_helper_spec.rb"],
        "WORKSPACE_CHANGED_TESTS" => ["spec/deep/nested_spec.rb", "spec/later_spec.rb"]
      )
      paths = call[:env].values_at("WORKSPACE_CHANGED_FILES", "WORKSPACE_RUN_CHANGED_FILES", "WORKSPACE_CHANGED_TESTS")
      expect(paths.map { |path| File.basename(path) }).to eq(%w[changed-files run-changed-files changed-tests])
      expect(paths.map { |path| File.dirname(path) }.uniq.size).to eq(1)
      expect(paths.first).not_to start_with(repo)
      expect(File.exist?(File.dirname(paths.first))).to be false
      expect(call[:argv]).to eq(["bin/check", "--", "spec/deep/nested_spec.rb", "spec/later_spec.rb"])
    end

    context "with commands.test_files unset when the proof runs" do
      let(:test_files) { [] }

      it "is unproven for a template using {{changed.tests}}, never an empty list" do
        expect(proven(exec_entry("bin/check -- {{changed.tests}}"), attempt: attempt)).to include("unproven" => true, "detail" => /commands\.test_files, which is not set for app/)
        expect(calls).to be_empty
      end

      it "runs another template with no tests variable" do
        expect(proven(exec_entry("bin/check"), attempt: attempt)).to be_nil
        expect(calls.first[:env]).to include("WORKSPACE_CHANGED_TESTS" => nil)
      end
    end

    it "reads commands.test_files for the run's own workspace, so a worktree's setting counts" do
      run["workspace"] = "app.worktree-feature"
      proven(exec_entry("bin/check -- {{changed.tests}}"), attempt: attempt)
      expect(commands).to have_received(:test_files).with("app.worktree-feature")
    end

    it "is unproven when git can't list a list the template uses" do
      allow(guard).to receive(:changed_paths).and_return(nil)
      expect(proven(exec_entry("bin/check -- {{changed.files}}"), attempt: attempt)).to include("unproven" => true, "detail" => /git could not list the files for \{\{changed\.files\}\}/)
      expect(calls).to be_empty
    end

    it "is unproven when the program's ~/ path can't be expanded" do
      allow(Workspace::WorkflowArgv).to receive(:render).and_raise(ArgumentError, "couldn't find login name")
      expect(proven(exec_entry("~/bin/check"), attempt: attempt)).to include("unproven" => true, "program" => "~/bin/check", "detail" => /could not be expanded/)
    end

    it "is unproven when git can't say which branch is checked out and the template uses {{branch}}" do
      allow(guard).to receive(:branch).and_return(nil)
      expect(proven(exec_entry("bin/check {{branch}}"), attempt: attempt)).to include("unproven" => true, "program" => "bin/check", "detail" => /git could not say which branch is checked out/)
      expect(calls).to be_empty
    end

    it "is unproven when the changed-file lists can't be written" do
      failing = described_class.new(guard: guard, notes_dir_of: ->(_) { notes }, commands_config: commands, checker: checker,
        tmpdir: ->(*) { raise Errno::EACCES })
      found = failing.check(run: run, step: {"require" => [exec_entry("bin/check")]}, attempt: attempt)["outside"]
      unmet = failing.run_outside(found, cwd: repo, env: {}, stop_when: stop_when)["unmet"]
      expect(unmet).to include("unproven" => true, "detail" => /changed-file lists could not be written \(Errno::EACCES\)/)
    end

    it "reads {{ changed.tests }} written with spaces as the list" do
      expect(proven(exec_entry("bin/check -- '{{ changed.tests }}'"), attempt: attempt)).to be_nil
      expect(calls.first[:argv]).to eq(["bin/check", "--", "spec/new_spec.rb"])
    end

    context "with commands.test_files unreadable" do
      before { allow(commands).to receive(:test_files).and_raise(Workspace::ConfigParseError.new("/x.yml", "bad yaml")) }

      it "is unproven only for a template using {{changed.tests}}" do
        expect(proven(exec_entry("bin/check -- {{changed.tests}}"), attempt: attempt)).to include("unproven" => true, "detail" => /could not be read .*bad yaml/)
      end

      it "runs a template that does not use it" do
        expect(proven(exec_entry("bin/check"), attempt: attempt)).to be_nil
      end
    end

    it "gives two exec entries their own log and token" do
      step = {"require" => [exec_entry("bin/one"), exec_entry("bin/two")]}
      first = requirer.check(run: run, step: step, attempt: attempt)["outside"]
      second = requirer.check(run: run, step: step, attempt: attempt, from: first["index"] + 1)["outside"]
      expect([first["index"], second["index"]]).to eq([0, 1])
      expect(first["token"]).not_to eq(second["token"])
      expect(first["log"]).to match(/require-exec-0\.#{first["token"]}\.log\z/)
      expect(second["log"]).to match(/require-exec-1\.#{second["token"]}\.log\z/)
    end

    it "is unproven with no checker wired" do
      bare = described_class.new(guard: guard, notes_dir_of: ->(_) { notes })
      expect(bare.check(run: run, step: {"require" => [exec_entry("bin/check")]}, attempt: attempt)).to include("code" => "require_exec", "unproven" => true)
    end

    it "writes the lists only into a private directory it removes, never through a link planted in the checkout" do
      victim = File.join(@dir, "victim")
      File.write(victim, "keep\n")
      FileUtils.mkdir_p(File.join(artifacts, "steps"))
      %w[changed-files run-changed-files changed-tests].each { |suffix| File.symlink(victim, File.join(artifacts, "steps", "verify.2.#{suffix}")) }
      outside = File.join(@dir, "elsewhere")
      FileUtils.mkdir_p(outside)
      seen = nil
      allow(checker).to receive(:call) do |**kwargs|
        dir = File.dirname(kwargs[:env]["WORKSPACE_CHANGED_FILES"])
        seen = [dir, File.stat(dir).mode & 0o777, File.lstat(kwargs[:env]["WORKSPACE_CHANGED_FILES"]).file?]
        answer
      end

      expect(proven(exec_entry("bin/check -- {{changed.tests}}"), attempt: attempt)).to be_nil
      expect(File.read(victim)).to eq("keep\n")
      expect(seen[1..]).to eq([0o700, true])
      expect(seen[0]).not_to start_with(repo)
      expect(File.exist?(seen[0])).to be false
    end

    it "removes the private directory when the program raises" do
      dirs = []
      allow(checker).to receive(:call) do |**kwargs|
        dirs << File.dirname(kwargs[:env]["WORKSPACE_CHANGED_FILES"])
        raise ArgumentError, "boom"
      end
      expect(proven(exec_entry("bin/check"), attempt: attempt)).to include("code" => "require_unknown")
      expect(File.exist?(dirs.first)).to be false
    end

    it "allows for its git reads before calling an exec proof lost, and nothing more for another proof" do
      expect(described_class.lost_after({"proof" => "exec", "timeout" => 30})).to eq(30 + 60 + described_class::EXEC_SETUP_SECONDS)
      expect(described_class.lost_after({"proof" => "command", "timeout" => 30})).to eq(90)
    end

    it "hands a changed file named like a shell command to a real program as one argument" do
      write("x;touch pwned|sh")
      script = File.join(@dir, "check.sh")
      File.write(script, "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"$OUT\"\ntr '\\0' '\\n' < \"$WORKSPACE_CHANGED_FILES\" > \"$OUT.env\"\n")
      File.chmod(0o755, script)
      real = described_class.new(guard: guard, notes_dir_of: ->(_) { notes }, commands_config: commands, checker: Workspace::WorkflowCheck.new)
      out = File.join(@dir, "args.txt")
      entry = {"exec" => [script, "--", "{{changed.files}}"], "timeout" => 30}
      pending_proof = real.check(run: run, step: {"require" => [entry]}, attempt: attempt)["outside"]
      result = real.run_outside(pending_proof, cwd: repo, env: {"OUT" => out})
      expect(result).to eq("record" => {"exit_code" => 0, "timed_out" => false}, "unmet" => nil)
      expect(File.read(out).lines(chomp: true)).to eq(["--", "lib/new.rb", "spec/new_spec.rb", "x;touch pwned|sh"])
      expect(File.read("#{out}.env").lines(chomp: true)).to eq(["lib/new.rb", "spec/new_spec.rb", "x;touch pwned|sh"])
      expect(File.exist?(File.join(repo, "pwned"))).to be false
    end
  end

  it "answers a failed proof, never an error, when a collaborator raises" do
    allow(guard).to receive(:commits_since).and_raise("boom")
    expect(check({"commits" => 1})).to include("code" => "require_unknown", "unproven" => true)
  end
end
