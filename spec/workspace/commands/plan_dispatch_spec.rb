require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::PlanDispatch do
  around do |example|
    Dir.mktmpdir("plan-dispatch") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:now) { Time.utc(2026, 10, 12, 14, 0, 0) }
  let(:notes_dirs) { {"api" => File.join(@dir, "api-notes")} }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:tmux) { instance_double(Workspace::Tmux, sessions: ["api", "api-worktree-x"], custom_socket_option: nil, close_pane: true) }
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:sender) { instance_double(Workspace::Commands::Send, deliver: {"pane" => "%19", "mode" => "text", "submitted" => true}) }
  let(:binder) { instance_double(Workspace::Commands::Binding, live: nil, bind: {}) }
  let(:play) { {"ref" => "play/implementation-plan", "path" => "/lib/play/implementation-plan.md"} }
  let(:library) do
    instance_double(Workspace::Library, pack: [play, "body"]).tap do |lib|
      allow(lib).to receive(:play_prompt) { |entry, prompt, **| "Read \"#{entry["path"]}\" and follow it.\n\n#{prompt}" }
      allow(lib).to receive(:play_binding) { |entry, packs: []| {"kind" => "play", "id" => entry["ref"], "instructions" => entry["path"]}.merge(packs.any? ? {"packs" => packs} : {}) }
    end
  end
  let(:events_log) { [] }
  let(:event_log) do
    instance_double(Workspace::EventLog).tap do |log|
      allow(log).to receive(:record) { |type:, project:, data: {}| events_log << {type: type, project: project, data: data} }
    end
  end
  let(:launcher) { double("launcher", call: nil) }
  let(:runner) { instance_double(Workspace::Commands::Run, call: "%23") }
  let(:main_agent) { instance_double(Workspace::MainAgent).tap { |agent| allow(agent).to receive(:spawn_command) { |_ws, kind| "#{kind} --from-config" } } }
  let(:readiness) do
    instance_double(Workspace::AgentReadiness, deadline_in: 99.0,
      wait: Workspace::AgentReadiness::Result.new(ready: true, pane: "0.2", pane_id: "%23", label: "Claude Code"))
  end
  let(:access) { Workspace::PlanAccess.new(notes: notes, tmux: tmux, event_log: event_log) }
  subject(:command) do
    panes = Workspace::PaneDispatch.new(snapshot_client: snapshot_client, sender: sender, binder: binder, library: library,
      runner: runner, readiness: readiness, main_agent: main_agent, tmux: tmux, project_config: double("project_config", project_root_for: "/w/api"), prompt_timeout: 30)
    described_class.new(access: access, panes: panes, library: library, output: output)
  end
  let(:plan_command) do
    Workspace::Commands::Plan.new(notes: notes, access: access, dispatch: command, catalog: instance_double(Workspace::ProjectCatalog), groups: instance_double(Workspace::ProjectGroups),
      plan_state: Workspace::PlanState.new(clock: -> { now }), plan_config: instance_double(Workspace::PlanConfig),
      snapshot_client: snapshot_client, ask_store_for: ->(_workspace) {}, task_store: instance_double(Workspace::TaskStore),
      clock: -> { now }, output: output)
  end

  before do
    allow(notes).to receive(:info) do |name:, create: false|
      dir = notes_dirs.fetch(name) { raise Workspace::Error.new("Unknown workspace '#{name}'.", code: "unknown_workspace", details: {"name" => name}) }
      FileUtils.mkdir_p(dir) if create
      {"workspace" => name, "dir" => dir, "source" => "default", "exists" => Dir.exist?(dir)}
    end
    allow(tmux).to receive(:session_name_for) { |name| name.tr(".", "-") }
  end

  def plan_path(name = "api") = File.join(notes_dirs.fetch(name), "IMPLEMENTATION_PLAN.md")

  def write_plan(name, text)
    FileUtils.mkdir_p(notes_dirs.fetch(name))
    File.write(plan_path(name), text)
  end

  let(:paused_text) { "---\ntitle: T\nstatus: paused\nowner_pane: \"%19\"\n---\n## Tasks\n- [~] T1 a\n- [ ] T2 b\n" }
  let(:active_text) { paused_text.sub("status: paused", "status: active") }

  def written = Workspace::PlanFile.read(plan_path)

  def events = events_log.map { |event| [event[:project], event[:type], event[:data]] }

  describe "#start" do
    let(:pane_rows) { [{"pane_id" => "%19", "kind" => "claude", "state" => "idle"}, {"pane_id" => "%20", "kind" => "claude", "state" => "idle"}] }
    let(:launch_ok) { {ok: true, reason: nil, message: nil, pane: "%31"} }

    before do
      allow(snapshot_client).to receive(:fetch).with("api", timeout: 1.0).and_return("panes" => pane_rows)
      allow(launcher).to receive(:call).and_return(launch_ok)
    end

    def start = command.start(name: "api", launch: launcher)

    it "fails with no_plan when there is no plan, launching and typing nothing" do
      expect { start }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_plan") }
      expect(launcher).not_to have_received(:call)
      expect(sender).not_to have_received(:deliver)
    end

    it "fails with plan_done when nothing is left, and does not launch" do
      write_plan("api", "## Tasks\n- [x] T1 a\n")

      expect { start }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("plan_done") }
      expect(launcher).not_to have_received(:call)
    end

    it "fails with plan_done when status is done" do
      write_plan("api", "---\nstatus: done\n---\n## Tasks\n- [ ] T1 a\n")

      expect { start }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("plan_done") }
    end

    context "when the workspace has no session" do
      before { allow(tmux).to receive(:sessions).and_return([]) }

      it "sets status: active, launches with the play, and records the pane it came up in as the owner" do
        write_plan("api", paused_text)

        result = start

        expect(result).to eq("outcome" => "launched", "reason" => nil, "message" => nil, "path" => plan_path, "pane" => "%31")
        expect(launcher).to have_received(:call).with("api")
        expect(written).to have_attributes(status: "active", owner_pane: "%31")
        expect(output.string).to eq("Started the plan for api: launched it with the implementation-plan play.\n")
        expect(events.map { |e| e[1] }).to eq(%w[plan_changed plan_changed])
        expect(events.map { |e| e[2] }).to all(eq("workspace" => "api", "status" => "active"))
        expect(sender).not_to have_received(:deliver)
      end

      it "launches an active plan too, writing the status only when it changes" do
        write_plan("api", active_text.sub("owner_pane: \"%19\"", "owner_pane: \"%31\""))
        before = File.stat(plan_path).mtime

        result = start

        expect(result["outcome"]).to eq("launched")
        expect(File.stat(plan_path).mtime).to eq(before)
        expect(events).to eq([])
      end

      it "reports a launch that failed as a failed row, keeping the status it set" do
        write_plan("api", paused_text)
        allow(launcher).to receive(:call).and_return(ok: false, reason: "prompt_not_sent", message: "never ready", pane: nil)

        result = start

        expect(result).to eq("outcome" => "failed", "reason" => "prompt_not_sent", "message" => "never ready", "path" => plan_path, "pane" => nil)
        expect(written).to have_attributes(status: "active", owner_pane: "%19")
        expect(output.string).to eq("")
      end

      it "leaves owner_pane alone when the launch did not say which pane" do
        write_plan("api", paused_text)
        allow(launcher).to receive(:call).and_return(launch_ok.merge(pane: nil))

        result = start

        expect(result["pane"]).to be_nil
        expect(written.owner_pane).to eq("%19")
      end

      it "writes the owner pane into a plan with no frontmatter" do
        write_plan("api", "## Tasks\n- [ ] T1 a\n")

        start

        expect(written).to have_attributes(status: "active", owner_pane: "%31")
      end

      it "still launches when the owner pane can't be written, and says so" do
        write_plan("api", paused_text)
        allow(Workspace::PlanFile).to receive(:set_owner_pane).and_raise(Errno::EACCES)

        result = start

        expect(result["outcome"]).to eq("launched")
        expect(result["message"]).to include("Could not record the owner pane")
      end

      it "launches a plan with no tasks with the draft line, as drafting" do
        write_plan("api", "---\nstatus: paused\n---\n## Tasks\n")

        result = start

        expect(result["outcome"]).to eq("drafting")
        expect(result["pane"]).to eq("%31")
        expect(launcher).to have_received(:call).with("api", described_class::DRAFT_PROMPT)
        expect(output.string).to include("to draft the tasks")
      end

      it "launches a plan with tasks with the default continue line" do
        write_plan("api", paused_text)

        start

        expect(launcher).to have_received(:call).with("api")
      end

      it "fails with notes_dir_unwritable, before launching, when the status can't be written" do
        write_plan("api", paused_text)
        allow(Workspace::PlanFile).to receive(:set_status).and_raise(Errno::EACCES)

        expect { start }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("notes_dir_unwritable") }
        expect(launcher).not_to have_received(:call)
      end
    end

    context "when the workspace has a session" do
      before { write_plan("api", paused_text) }

      it "sends the play and the line to the idle owner pane, binds the pane to the play, and leaves the owner as it was" do
        result = start

        expect(result).to eq("outcome" => "sent", "reason" => nil, "message" => nil, "path" => plan_path, "pane" => "%19")
        expect(sender).to have_received(:deliver).with(name: "api", pane: "%19", body: "Read \"/lib/play/implementation-plan.md\" and follow it.\n\nContinue the plan.")
        expect(binder).to have_received(:bind).with(:workspace => "api", :pane => "%19", "kind" => "play", "id" => "play/implementation-plan", "instructions" => "/lib/play/implementation-plan.md")
        expect(written).to have_attributes(status: "active", owner_pane: "%19")
        expect(output.string).to eq("Started the plan for api: sent it to pane %19.\n")
        expect(events).to eq([["api", "plan_changed", {"workspace" => "api", "status" => "active"}]])
        expect(launcher).not_to have_received(:call)
      end

      it "sends the draft line, as drafting, to a plan with no tasks, bound to the play" do
        write_plan("api", "---\nstatus: paused\n---\n## Tasks\n")

        result = start

        expect(result["outcome"]).to eq("drafting")
        expect(result["pane"]).to eq("%19")
        expect(sender).to have_received(:deliver).with(name: "api", pane: "%19",
          body: "Read \"/lib/play/implementation-plan.md\" and follow it.\n\n#{described_class::DRAFT_PROMPT}")
        expect(binder).to have_received(:bind).with(hash_including("kind" => "play", "id" => "play/implementation-plan"))
        expect(written.status).to eq("active")
        expect(output.string).to eq("Started the plan for api: sent the draft request to pane %19.\n")
      end

      it "is already_working, typing and binding nothing, when the owner pane is working, and still sets the plan active" do
        pane_rows[0]["state"] = "working"

        result = start

        expect(result).to eq("outcome" => "already_working", "reason" => nil, "message" => nil, "path" => plan_path, "pane" => "%19")
        expect(sender).not_to have_received(:deliver)
        expect(binder).not_to have_received(:bind)
        expect(written.status).to eq("active")
        expect(output.string).to eq("The plan for api is already being worked on in pane %19.\n")
      end

      it "refuses with pane_busy when the pane waits on a person, after setting the plan active" do
        pane_rows[0]["state"] = "waiting"

        expect { start }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("pane_busy")
          expect(e.details).to eq("workspace" => "api", "pane" => "%19")
        }
        expect(sender).not_to have_received(:deliver)
        expect(written.status).to eq("active")
      end

      it "picks the first Claude Code pane and records it as the owner when the plan names none" do
        write_plan("api", paused_text.sub("owner_pane: \"%19\"\n", ""))
        pane_rows.unshift("pane_id" => "%18", "kind" => "shell", "state" => "idle")

        result = start

        expect(result["pane"]).to eq("%19")
        expect(written.owner_pane).to eq("%19")
      end

      it "moves the owner to a live Claude Code pane when the recorded one is gone, as after a restore" do
        write_plan("api", paused_text.sub("%19", "%3"))

        result = start

        expect(result["pane"]).to eq("%19")
        expect(written.owner_pane).to eq("%19")
      end

      it "prefers the owner pane over an earlier Claude Code pane" do
        pane_rows.reverse!
        write_plan("api", paused_text.sub("%19", "%20"))

        expect(start["pane"]).to eq("%20")
      end

      it "sends the plan to a Codex pane, which handoff now restarts" do
        write_plan("api", paused_text.sub("owner_pane: \"%19\"\n", ""))
        pane_rows.replace([{"pane_id" => "%18", "kind" => "shell", "state" => "idle"}, {"pane_id" => "%21", "kind" => "codex", "state" => "idle"}])

        result = start

        expect(result["pane"]).to eq("%21")
        expect(written.owner_pane).to eq("%21")
      end

      it "fails with no_agent_pane when no pane runs Claude Code or Codex" do
        pane_rows.replace([{"pane_id" => "%18", "kind" => "shell", "state" => "idle"}])

        expect { start }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_agent_pane") }
        expect(sender).not_to have_received(:deliver)
      end

      it "fails with no_daemon when the agent daemon does not answer" do
        allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("No agent daemon for 'api'.", reason: :no_daemon))

        expect { start }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_daemon") }
        expect(sender).not_to have_received(:deliver)
      end

      it "treats a workspace whose session can't be asked about as having one" do
        allow(tmux).to receive(:custom_socket_option).with("api").and_return("-L x")

        expect(start["outcome"]).to eq("sent")
      end

      it "passes on a send that did not reach the pane" do
        allow(sender).to receive(:deliver).and_raise(Workspace::Error.new("never arrived", code: "not_delivered"))

        expect { start }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_delivered") }
        expect(binder).not_to have_received(:bind)
      end

      it "keeps the packs of a play binding the pane already has" do
        allow(binder).to receive(:live).with(pane: "%19").and_return("kind" => "play", "packs" => %w[notes])

        start

        expect(library).to have_received(:play_binding).with(anything, packs: %w[notes])
      end

      it "leaves a pane bound to a run or a review as it is" do
        allow(binder).to receive(:live).with(pane: "%19").and_return("kind" => "run", "id" => "wr_1")

        expect(start["outcome"]).to eq("sent")
        expect(binder).not_to have_received(:bind)
      end

      it "says the pane was not bound, and still reports sent, when the binding can't be written" do
        allow(binder).to receive(:bind).and_raise(Workspace::Error, "bindings.json is locked")

        result = start

        expect(result["outcome"]).to eq("sent")
        expect(result["message"]).to eq("Sent, but could not bind pane %19 to the play (bindings.json is locked).")
      end

      it "can be repeated: a plan that is already active is not written again, and no event is recorded" do
        write_plan("api", active_text)
        before = File.stat(plan_path).mtime

        start

        expect(File.stat(plan_path).mtime).to eq(before)
        expect(events).to eq([])
      end

      it "still sends when the owner pane can't be recorded, and says so" do
        write_plan("api", paused_text.sub("%19", "%3"))
        allow(Workspace::PlanFile).to receive(:set_owner_pane).and_raise(Workspace::Error.new("changed", code: "plan_write_conflict"))

        result = start

        expect(result["outcome"]).to eq("sent")
        expect(result["message"]).to include("Could not record the owner pane")
      end

      it "puts both notes in the message when the bind and the owner write fail" do
        write_plan("api", paused_text.sub("%19", "%3"))
        allow(binder).to receive(:bind).and_raise(Workspace::Error, "locked")
        allow(Workspace::PlanFile).to receive(:set_owner_pane).and_raise(Errno::EACCES)

        expect(start["message"]).to include("could not bind").and include("Could not record the owner pane")
      end
    end
  end

  describe "one task" do
    let(:task_text) { "---\nstatus: paused\nowner_pane: \"%19\"\n---\n## Tasks\n- [x] T1 a\n- [ ] T2 b\n- [~] T3 c <!-- owner: %20 -->\n- [-] T4 d -- no\n" }
    let(:pane_rows) do
      [{"pane_id" => "%19", "kind" => "claude", "state" => "idle"}, {"pane_id" => "%20", "kind" => "claude", "state" => "idle"},
        {"pane_id" => "%21", "kind" => "codex", "state" => "idle"}, {"pane_id" => "%22", "kind" => nil, "state" => "idle"}]
    end
    let(:task_body) { "Read \"/lib/play/implementation-plan.md\" and follow it.\n\n#{described_class.task_prompt("T2")}" }

    before do
      write_plan("api", task_text)
      allow(snapshot_client).to receive(:fetch).with("api", timeout: 1.0).and_return("panes" => pane_rows)
      allow(sender).to receive(:locate) { |_name, pane| {id: pane, session: "api"} }
      allow(launcher).to receive(:call).and_return(ok: true, reason: nil, message: nil, pane: "%31")
    end

    def start_task(id = "T2", **options) = command.start_task(name: "api", task_id: id, launch: launcher, **options)

    def task(id) = Workspace::PlanFile.read(plan_path).tasks.find { |t| t.id == id }

    describe "#start_task" do
      it "sends the task to the named pane, binds it with the task as focus, and writes the pane onto the line as owner, in progress" do
        result = start_task(pane: "%21")

        expect(result).to eq("outcome" => "sent", "reason" => nil, "message" => nil, "path" => plan_path, "pane" => "%21", "task" => "T2")
        expect(sender).to have_received(:deliver).with(name: "api", pane: "%21", body: task_body)
        expect(binder).to have_received(:bind).with(:workspace => "api", :pane => "%21", "kind" => "play", "id" => "play/implementation-plan",
          "instructions" => "/lib/play/implementation-plan.md", "focus" => "plan task T2")
        expect(File.read(plan_path)).to include("- [ ] T2 b".sub("[ ]", "[~]") + " <!-- owner: %21 -->\n")
        expect(Workspace::PlanFile.read(plan_path)).to have_attributes(status: "active", owner_pane: "%19")
        expect(output.string).to eq("Started task T2 of the plan for api: sent it to pane %21.\n")
        expect(events_log.map { |e| e[:data]["status"] }).to eq(%w[active active])
      end

      it "sends a task with no owner to the main agent pane, and one with a live owner to its owner" do
        expect(start_task["pane"]).to eq("%19")
        expect(start_task("T3")["pane"]).to eq("%20")
        expect(task("T3")).to have_attributes(state: "in_progress", owner: "%20")
      end

      it "is already_working, typing nothing, when the task's own owner pane works" do
        pane_rows[1]["state"] = "working"

        result = start_task("T3")

        expect(result).to include("outcome" => "already_working", "pane" => "%20", "task" => "T3")
        expect(sender).not_to have_received(:deliver)
      end

      it "refuses task_owned when the owner works and another pane is named, or a spawn is asked for" do
        pane_rows[1]["state"] = "working"

        [{pane: "%21"}, {spawn: "claude"}].each do |options|
          expect { start_task("T3", **options) }.to raise_error(Workspace::Error) { |e|
            expect(e.code).to eq("task_owned")
            expect(e.details).to include("task" => "T3", "owner" => "%20")
          }
        end
        expect(sender).not_to have_received(:deliver)
        expect(runner).not_to have_received(:call)
      end

      it "refuses pane_busy for a named pane that works on something else or waits on a person" do
        {"working" => "working", "waiting" => "waiting"}.each do |state, detail|
          pane_rows[2]["state"] = state
          expect { start_task(pane: "%21") }.to raise_error(Workspace::Error) { |e|
            expect(e.code).to eq("pane_busy")
            expect(e.details).to include("pane" => "%21", "state" => detail)
          }
        end
        expect(sender).not_to have_received(:deliver)
      end

      it "refuses no_agent_pane for a named pane that runs no coding agent or that the daemon does not list" do
        %w[%22 %40].each do |pane|
          expect { start_task(pane: pane) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_agent_pane") }
        end
      end

      it "passes the locator's refusal through for a pane outside the session" do
        allow(sender).to receive(:locate).and_raise(Workspace::Error.new("no", code: "wrong_session"))

        expect { start_task(pane: "%99") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("wrong_session") }
      end

      it "leaves a paused plan paused, and records nothing, when the task is refused at the pane" do
        pane_rows[2]["state"] = "waiting"

        expect { start_task(pane: "%21") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("pane_busy") }
        expect(File.read(plan_path)).to eq(task_text)
        expect(events_log).to eq([])
      end

      it "refuses no_daemon before spawning when the task has an owner and the daemon does not answer" do
        allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("down", reason: :no_daemon))

        expect { start_task("T3", spawn: "claude") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_daemon") }
        expect(runner).not_to have_received(:call)
      end

      it "rejects a pane and a spawn together, and an unknown kind, as programming errors" do
        expect { start_task(pane: "%21", spawn: "claude") }.to raise_error(ArgumentError)
        expect { start_task(spawn: "vim") }.to raise_error(ArgumentError)
      end

      it "refuses unknown_task, task_done and plan_done before writing anything" do
        expect { start_task("T9") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_task") }
        %w[T1 T4].each do |id|
          expect { start_task(id) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("task_done") }
        end
        expect(File.read(plan_path)).to eq(task_text)
        write_plan("api", "---\nstatus: done\n---\n## Tasks\n- [ ] T2 b\n")
        expect { start_task }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("plan_done") }
      end

      it "spawns a new agent pane, waits on that pane alone, and sends the task there" do
        result = start_task(spawn: "codex")

        expect(main_agent).to have_received(:spawn_command).with("api", "codex")
        expect(runner).to have_received(:call).with("api", "codex --from-config", split: true, cwd: "/w/api")
        expect(readiness).to have_received(:deadline_in).with(30)
        expect(readiness).to have_received(:wait).with("api", deadline: 99.0, only_pane: "%23")
        expect(sender).to have_received(:deliver).with(name: "api", pane: "%23", body: task_body)
        expect(result).to include("outcome" => "spawned", "pane" => "%23", "task" => "T2")
        expect(task("T2")).to have_attributes(state: "in_progress", owner: "%23")
        expect(output.string).to eq("Started task T2 of the plan for api: sent it to new pane %23.\n")
      end

      it "reports a spawned agent that never got ready as failed with prompt_not_sent and the new pane, typing nothing" do
        allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "still starting up"))

        result = start_task(spawn: "claude")

        expect(result).to include("outcome" => "failed", "reason" => "prompt_not_sent", "pane" => "%23", "task" => "T2")
        expect(result["message"]).to include("still starting up", "the pane was closed")
        expect(result["details"]).to eq("pane_id" => "%23", "pane_closed" => true)
        expect(tmux).to have_received(:close_pane).with("%23")
        expect(sender).not_to have_received(:deliver)
        expect(task("T2").owner).to be_nil
      end

      it "says the pane stays when it could not be closed" do
        allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "timeout"))
        allow(tmux).to receive(:close_pane).and_return(false)

        result = start_task(spawn: "claude")

        expect(result["message"]).not_to include("closed")
        expect(result["details"]).to eq("pane_id" => "%23", "pane_closed" => false)
      end

      it "names the new pane, left open, when typing the task fails after the agent was ready" do
        allow(sender).to receive(:deliver).and_raise(Workspace::Error.new("typing failed", code: "send_failed"))

        expect { start_task(spawn: "claude") }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("send_failed")
          expect(e.details).to include("pane_id" => "%23", "pane_closed" => false)
        }
        expect(tmux).not_to have_received(:close_pane)
      end

      it "never closes a pane the caller named" do
        start_task(pane: "%21")

        expect(tmux).not_to have_received(:close_pane)
      end

      it "launches a workspace with no session with the task's line, and records the launched pane as owner" do
        allow(tmux).to receive(:sessions).and_return([])

        result = start_task

        expect(launcher).to have_received(:call).with("api", described_class.task_prompt("T2"))
        expect(result).to include("outcome" => "launched", "pane" => "%31", "task" => "T2")
        expect(task("T2").owner).to eq("%31")
      end

      it "refuses no_session with --pane or --spawn when there is no session, after nothing was written" do
        allow(tmux).to receive(:sessions).and_return([])

        [{pane: "%19"}, {spawn: "claude"}].each do |options|
          expect { start_task(**options) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_session") }
        end
        expect(File.read(plan_path)).to eq(task_text)
      end

      it "keeps the send and says so in message when the owner can't be written" do
        allow(Workspace::PlanFile).to receive(:set_task).and_raise(Workspace::Error.new("boom"))

        result = start_task

        expect(result["outcome"]).to eq("sent")
        expect(result["message"]).to include("Could not record the owner on task T2 (boom)")
      end

      it "leaves the box as it is when the agent already moved the task on" do
        allow(sender).to receive(:deliver) do
          File.write(plan_path, File.read(plan_path).sub("- [ ] T2 b", "- [x] T2 b"))
          {"pane" => "%19", "mode" => "text", "submitted" => true}
        end

        start_task

        expect(task("T2")).to have_attributes(state: "done", owner: "%19")
      end
    end

    describe "#pause with interrupt" do
      it "presses each working owner pane's interrupt key and lists every owner of the plan and of the tasks left" do
        write_plan("api", task_text.sub("paused", "active").sub("- [ ] T2 b", "- [ ] T2 b <!-- owner: %21 -->").sub("- [x] T1 a", "- [x] T1 a <!-- owner: %22 -->"))
        pane_rows[0]["state"] = "working"
        pane_rows[1]["state"] = "working"
        pane_rows[1]["kind"] = "opencode"

        result = plan_command.pause(name: "api", interrupt: true)

        expect(result).to include("outcome" => "paused", "warnings" => [])
        expect(result["interrupts"]).to eq([
          {"pane" => "%19", "kind" => "claude", "outcome" => "sent", "message" => nil},
          {"pane" => "%21", "kind" => "codex", "outcome" => "not_working", "message" => nil},
          {"pane" => "%20", "kind" => "opencode", "outcome" => "unsupported", "message" => nil}
        ])
        expect(sender).to have_received(:deliver).once.with(name: "api", pane: "%19", keys: ["Escape"])
        expect(Workspace::PlanFile.read(plan_path).status).to eq("paused")
      end

      it "reports an owner the daemon does not list as gone, and a key that did not arrive as failed" do
        write_plan("api", task_text.sub("%20", "%44"))
        pane_rows[0]["state"] = "working"
        allow(sender).to receive(:deliver).and_raise(Workspace::Error.new("tmux said no", code: "not_delivered"))

        result = plan_command.pause(name: "api", interrupt: true)

        expect(result["interrupts"]).to eq([
          {"pane" => "%19", "kind" => "claude", "outcome" => "failed", "message" => "tmux said no"},
          {"pane" => "%44", "kind" => nil, "outcome" => "gone", "message" => nil}
        ])
      end

      it "still pauses, with a no_daemon warning and no interrupts, when the daemon does not answer" do
        write_plan("api", task_text.sub("paused", "active"))
        allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no daemon", reason: :no_daemon))

        result = plan_command.pause(name: "api", interrupt: true)

        expect(result).to include("outcome" => "paused", "interrupts" => [], "warnings" => [{"code" => "no_daemon", "message" => "no daemon"}])
        expect(Workspace::PlanFile.read(plan_path).status).to eq("paused")
      end

      it "asks nothing of the daemon when no pane owns anything, and nothing at all without interrupt" do
        write_plan("api", "## Tasks\n- [ ] T1 a\n")

        expect(plan_command.pause(name: "api", interrupt: true)).to include("interrupts" => [], "warnings" => [])
        expect(plan_command.pause(name: "api")).not_to have_key("interrupts")
        expect(snapshot_client).not_to have_received(:fetch)
      end
    end
  end
end
