require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::Inbox do
  let(:tmpdir) { Dir.mktmpdir("ws-inbox-command") }
  let(:config) do
    state = tmpdir
    Class.new(Workspace::Config) { define_method(:state_dir) { state } }.new
  end
  let(:now) { Time.utc(2026, 10, 16, 12, 0, 0) }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:env) { {} }
  let(:detected) { "api.fix" }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: detected) }
  let(:api_project) do
    Workspace::ProjectCatalog::Project.new(name: "api", id: "/src/api/.git", path: "/src/api", vcs: "git", members: [])
  end
  let(:project_catalog) { instance_double(Workspace::ProjectCatalog, for_cwd: api_project, find: api_project) }
  let(:session_ledger) { instance_double(Workspace::SessionLedger, open_session_for: nil) }
  let(:store_factory) do
    ->(path:, scope:, error_output:) { Workspace::InboxStore.new(path: path, scope: scope, clock: -> { now }, error_output: error_output) }
  end

  subject(:command) do
    described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
      session_ledger: session_ledger, store_factory: store_factory, env: env, input: input,
      clock: -> { now }, output: output, error_output: error_output)
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def stored(path)
    JSON.parse(File.read(path))
  end

  def refused_field(&block)
    expect(&block).to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("invalid_inbox_item")
      @details = e.details
    }
    @details["field"]
  end

  describe "#add" do
    it "creates an open item in the detected workspace's scope" do
      result = command.add(title: "Check the deploy", working_dir: "/app")

      item = stored(config.inbox_path("workspace", "api.fix")).first
      expect(item).to include("title" => "Check the deploy", "type" => "todo", "state" => "open", "body" => nil,
        "scope" => {"kind" => "workspace", "key" => "api.fix", "name" => "api.fix"}, "dedupe_key" => nil)
      expect(result[:exit_code]).to eq(0)
      expect(result[:results]).to contain_exactly(a_hash_including("outcome" => "created", "id" => item["id"], "item" => item))
      expect(output.string).to include("Added inbox item #{item["id"]} to workspace:api.fix: Check the deploy")
    end

    it "fills type, source, links, body and expiry from the options" do
      command.add(title: "CI failed", type: "alert", body: "3 failures", working_dir: "/app",
        source: {kind: "github_check", ref: "zdennis/api#412/rspec", url: "https://github.com/zdennis/api/runs/1"},
        links: {pane: "%19", plan_task: "T4", pr: 412, run_id: "r1"}, expires: "2h")

      item = stored(config.inbox_path("workspace", "api.fix")).first
      expect(item).to include("type" => "alert", "body" => "3 failures", "expires_at" => "2026-10-16T14:00:00Z",
        "source" => {"kind" => "github_check", "ref" => "zdennis/api#412/rspec", "url" => "https://github.com/zdennis/api/runs/1"},
        "links" => {"pane" => "%19", "plan_task" => "T4", "pr" => 412, "run_id" => "r1"})
    end

    it "accepts an ISO 8601 expiry in the future" do
      command.add(title: "x", expires: "2026-10-20T09:00:00+02:00", working_dir: "/app")

      expect(stored(config.inbox_path("workspace", "api.fix")).first["expires_at"]).to eq("2026-10-20T07:00:00Z")
    end

    it "adds to the global list with --global, without detecting a workspace" do
      allow(project_detector).to receive(:detect).and_return(nil)

      command.add(title: "x", target: {global: true}, working_dir: "/elsewhere")

      expect(stored(config.inbox_path("global")).first["scope"]).to eq("kind" => "global", "key" => nil, "name" => nil)
    end

    it "adds to a project's scope with --project, keyed by its git common dir" do
      command.add(title: "x", target: {project: "api"}, working_dir: "/app")

      expect(project_catalog).to have_received(:find).with("api")
      expect(stored(config.inbox_path("project", "/src/api/.git", name: "api")).first["scope"])
        .to eq("kind" => "project", "key" => "/src/api/.git", "name" => "api")
    end

    it "adds to the named workspace with --name" do
      command.add(title: "x", target: {name: "other"}, working_dir: "/app")

      expect(File.exist?(config.inbox_path("workspace", "other"))).to be(true)
    end

    it "says projects are unavailable when no catalog was wired" do
      bare = described_class.new(config: config, project_detector: project_detector, store_factory: store_factory, output: output)

      expect { bare.add(title: "x", target: {project: "api"}, working_dir: "/app") }
        .to raise_error(Workspace::Error, /Projects are not available/)
    end

    it "refuses a workspace name that can't name a scope file" do
      allow(project_detector).to receive(:detect).and_return("../escape")

      expect { command.add(title: "x", working_dir: "/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_workspace")
      }
    end

    it "refuses more than one scope flag" do
      expect { command.add(title: "x", target: {name: "a", global: true}, working_dir: "/app") }
        .to raise_error(Workspace::UsageError)
    end

    it "fails with not_in_workspace outside any workspace without a scope flag" do
      allow(project_detector).to receive(:detect).and_return(nil)

      expect { command.add(title: "x", working_dir: "/elsewhere") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("not_in_workspace")
        expect(e.details).to eq("path" => "/elsewhere")
      }
      expect(Dir.exist?(config.inbox_dir)).to be(false)
    end

    it "refuses a title with an escape sequence and writes nothing" do
      field = refused_field { command.add(title: "\e[31mred", working_dir: "/app") }

      expect(field).to eq("title")
      expect(File.exist?(config.inbox_path("workspace", "api.fix"))).to be(false)
    end

    it "refuses a title with a newline, a C1 control, or a line separator" do
      ["a\nb", "a\u009bb", "a b", "a\tb", "a\0b"].each do |title|
        expect(refused_field { command.add(title: title, working_dir: "/app") }).to eq("title")
      end
    end

    it "refuses an empty or over-long title" do
      expect(refused_field { command.add(title: "  ", working_dir: "/app") }).to eq("title")
      expect(refused_field { command.add(title: "a" * 201, working_dir: "/app") }).to eq("title")
      expect { command.add(title: "a" * 200, working_dir: "/app") }.not_to raise_error
    end

    it "refuses invalid UTF-8" do
      expect(refused_field { command.add(title: +"bad \xFF", working_dir: "/app") }).to eq("title")
    end

    it "refuses invalid UTF-8 in a body read from stdin" do
      input.string = "bad \xFF".b

      expect(refused_field { command.add(title: "x", body_file: "-", working_dir: "/app") }).to eq("body")
    end

    it "keeps a body's newlines and tabs but refuses other control characters and over-long text" do
      command.add(title: "x", body: "a\n\tb\n", working_dir: "/app")

      expect(stored(config.inbox_path("workspace", "api.fix")).first["body"]).to eq("a\n\tb")
      expect(refused_field { command.add(title: "x", body: "a\eb", working_dir: "/app") }).to eq("body")
      expect(refused_field { command.add(title: "x", body: "a\rb", working_dir: "/app") }).to eq("body")
      expect(refused_field { command.add(title: "x", body: "a" * 8193, working_dir: "/app") }).to eq("body")
    end

    it "refuses an unknown type and source kind" do
      expect(refused_field { command.add(title: "x", type: "bug", working_dir: "/app") }).to eq("type")
      expect(refused_field { command.add(title: "x", source: {kind: "slack"}, working_dir: "/app") }).to eq("source.kind")
    end

    it "refuses a source URL that is not https, and an over-long ref" do
      ["http://x.test/", "javascript:alert(1)", "not a url", "https://", "https://x.test/\e"].each do |url|
        expect(refused_field { command.add(title: "x", source: {url: url}, working_dir: "/app") }).to eq("source.url")
      end
      expect(refused_field { command.add(title: "x", source: {ref: "r" * 201}, working_dir: "/app") }).to eq("source.ref")
    end

    it "refuses bad links" do
      expect(refused_field { command.add(title: "x", links: {pr: 0}, working_dir: "/app") }).to eq("links.pr")
      expect(refused_field { command.add(title: "x", links: {plan_task: "t" * 65}, working_dir: "/app") }).to eq("links.plan_task")
      expect(refused_field { command.add(title: "x", links: {pane: "%1\e"}, working_dir: "/app") }).to eq("links.pane")
    end

    it "refuses an expiry that is not a time, or is not in the future" do
      expect(refused_field { command.add(title: "x", expires: "soon", working_dir: "/app") }).to eq("expires")
      expect(refused_field { command.add(title: "x", expires: "2026-10-16T11:00:00Z", working_dir: "/app") }).to eq("expires")
    end

    it "keeps the offending text out of the error message" do
      expect { command.add(title: "a\e[31m", working_dir: "/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.message).not_to include("\e")
      }
    end

    describe "created_by" do
      it "is cli with no pane" do
        command.add(title: "x", working_dir: "/app")

        expect(stored(config.inbox_path("workspace", "api.fix")).first["created_by"])
          .to eq("kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil)
      end

      it "is agent, with the pane and session, when the ledger shows a session open in the pane" do
        env.merge!("TMUX_PANE" => "%19", "TMUX" => "/tmp/sock,4242,0")
        allow(session_ledger).to receive(:open_session_for).with(pane_id: "%19", tmux_server: "4242").and_return("sess-1")

        command.add(title: "x", working_dir: "/app")

        expect(stored(config.inbox_path("workspace", "api.fix")).first["created_by"])
          .to eq("kind" => "agent", "pane" => "%19", "session_id" => "sess-1", "tmux_server" => "4242")
      end

      it "stays cli for a shell pane the ledger knows nothing about" do
        env.merge!("TMUX_PANE" => "%3", "TMUX" => "/tmp/sock,4242,0")

        command.add(title: "x", working_dir: "/app")

        expect(stored(config.inbox_path("workspace", "api.fix")).first["created_by"])
          .to include("kind" => "cli", "pane" => "%3")
      end

      it "is user with --as-user, and the source kind follows" do
        command.add(title: "x", as_user: true, working_dir: "/app")

        item = stored(config.inbox_path("workspace", "api.fix")).first
        expect(item["created_by"]["kind"]).to eq("user")
        expect(item["source"]).to eq("kind" => "user", "ref" => nil, "url" => nil)
      end

      it "ignores a TMUX_PANE that is not a pane id" do
        env["TMUX_PANE"] = "%1; rm -rf /"

        command.add(title: "x", working_dir: "/app")

        expect(stored(config.inbox_path("workspace", "api.fix")).first["created_by"]["pane"]).to be_nil
      end
    end

    describe "--body-file" do
      it "reads stdin for -" do
        input.string = "from stdin\nline two\n"

        command.add(title: "x", body_file: "-", working_dir: "/app")

        expect(stored(config.inbox_path("workspace", "api.fix")).first["body"]).to eq("from stdin\nline two")
      end

      it "reads a file" do
        path = File.join(tmpdir, "body.txt")
        File.write(path, "from file")

        command.add(title: "x", body_file: path, working_dir: "/app")

        expect(stored(config.inbox_path("workspace", "api.fix")).first["body"]).to eq("from file")
      end

      it "refuses input over 64 KB and writes nothing" do
        input.string = "a" * (64 * 1024 + 1)

        expect(refused_field { command.add(title: "x", body_file: "-", working_dir: "/app") }).to eq("body")
        expect(File.exist?(config.inbox_path("workspace", "api.fix"))).to be(false)
      end

      it "refuses a file that can't be read" do
        expect(refused_field { command.add(title: "x", body_file: File.join(tmpdir, "missing"), working_dir: "/app") }).to eq("body")
      end

      it "refuses a directory as the body file" do
        expect(refused_field { command.add(title: "x", body_file: tmpdir, working_dir: "/app") }).to eq("body")
      end

      it "refuses --body with --body-file" do
        expect { command.add(title: "x", body: "a", body_file: "-", working_dir: "/app") }.to raise_error(Workspace::UsageError)
      end
    end

    it "refuses to write into a scope file it can't parse" do
      path = config.inbox_path("workspace", "api.fix")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{nope")

      expect { command.add(title: "x", working_dir: "/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("inbox_store_unreadable")
      }
      expect(File.read(path)).to eq("{nope")
    end
  end

  describe "#add_from_json" do
    def post(object)
      input.string = object.is_a?(String) ? object : JSON.generate(object)
      command.add_from_json("-", working_dir: "/app")
    end

    def refused(object)
      expect { post(object) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("invalid_inbox_item")
        @details = e.details
      }
      @details["field"]
    end

    it "creates the item from every writable key" do
      result = post({"type" => "alert", "title" => "CI failed", "body" => "3 failures", "dedupe_key" => nil,
                     "source" => {"kind" => "github_check", "ref" => "api#412", "url" => "https://github.com/x/y/runs/1"},
                     "expires_at" => "2h", "links" => {"pr" => 412, "pane" => "%2"},
                     "scope" => {"kind" => "global"}})

      item = stored(config.inbox_path("global")).first
      expect(item).to include("type" => "alert", "title" => "CI failed", "body" => "3 failures",
        "source" => {"kind" => "github_check", "ref" => "api#412", "url" => "https://github.com/x/y/runs/1"},
        "links" => {"pane" => "%2", "plan_task" => nil, "pr" => 412, "run_id" => nil},
        "expires_at" => "2026-10-16T14:00:00Z", "scope" => {"kind" => "global", "key" => nil, "name" => nil})
      expect(result[:results]).to contain_exactly(a_hash_including("outcome" => "created", "scope" => "global", "id" => item["id"]))
    end

    it "uses the working directory's workspace and type todo when they are left out" do
      post({"title" => "Check"})

      expect(stored(config.inbox_path("workspace", "api.fix")).first).to include("title" => "Check", "type" => "todo")
    end

    it "targets a named workspace or project from the scope object" do
      post({"title" => "a", "scope" => {"kind" => "workspace", "name" => "other"}})
      post({"title" => "b", "scope" => {"kind" => "project", "name" => "api"}})

      expect(stored(config.inbox_path("workspace", "other")).first["title"]).to eq("a")
      expect(stored(config.inbox_path("project", api_project.id, name: "api")).first["title"]).to eq("b")
    end

    it "reads a file" do
      path = File.join(tmpdir, "item.json")
      File.write(path, JSON.generate({"title" => "from file", "scope" => {"kind" => "global"}}))

      command.add_from_json(path, working_dir: "/app")

      expect(stored(config.inbox_path("global")).first["title"]).to eq("from file")
    end

    it "refuses an unknown key, naming it" do
      expect(refused({"title" => "x", "state" => "done"})).to eq("state")
      expect(refused({"title" => "x", "source" => {"host" => "a"}})).to eq("source.host")
      expect(refused({"title" => "x", "links" => {"issue" => "a"}})).to eq("links.issue")
      expect(refused({"title" => "x", "scope" => {"kind" => "global", "key" => "a"}})).to eq("scope.key")
    end

    it "refuses anything but one object" do
      expect(refused("[]")).to eq("json")
      expect(refused("\"x\"")).to eq("json")
      expect(refused("{nope")).to eq("json")
      expect(refused("")).to eq("json")
    end

    it "refuses input over 64 KB and writes nothing" do
      expect(refused("{\"title\":\"#{"a" * (64 * 1024)}\"}")).to eq("json")
      expect(Dir.glob(File.join(tmpdir, "**", "*.json"))).to be_empty
    end

    it "refuses a file that can't be read" do
      expect { command.add_from_json(File.join(tmpdir, "missing")) }.to raise_error(Workspace::Error) { |e|
        expect([e.code, e.details["field"]]).to eq(["invalid_inbox_item", "json"])
      }
    end

    it "refuses invalid UTF-8" do
      expect(refused("{\"title\":\"\xff\"}".b)).to eq("json")
    end

    it "requires a title" do
      expect(refused({"body" => "x"})).to eq("title")
    end

    it "refuses values that are not strings, and an integer-less pr" do
      expect(refused({"title" => 5})).to eq("title")
      expect(refused({"title" => "x", "body" => ["a"]})).to eq("body")
      expect(refused({"title" => "x", "type" => 1})).to eq("type")
      expect(refused({"title" => "x", "source" => "jira"})).to eq("source")
      expect(refused({"title" => "x", "links" => {"pane" => 2}})).to eq("links.pane")
      expect(refused({"title" => "x", "links" => {"pr" => "7"}})).to eq("links.pr")
      expect(refused({"title" => "x", "expires_at" => 3})).to eq("expires_at")
    end

    it "applies the same checks as add" do
      expect(refused({"title" => "red \e[31m"})).to eq("title")
      expect(refused({"title" => "x", "body" => "a\u0000b"})).to eq("body")
      expect(refused({"title" => "x", "type" => "bogus"})).to eq("type")
      expect(refused({"title" => "x", "source" => {"url" => "http://a.test"}})).to eq("source.url")
      expect(refused({"title" => "x", "expires_at" => "2020-01-01T00:00:00Z"})).to eq("expires_at")
      expect(refused({"title" => "x", "expires_at" => "soon"})).to eq("expires_at")
    end

    it "refuses a bad scope" do
      expect(refused({"title" => "x", "scope" => {"kind" => "team"}})).to eq("scope.kind")
      expect(refused({"title" => "x", "scope" => {"kind" => "workspace"}})).to eq("scope.name")
      expect(refused({"title" => "x", "scope" => {"kind" => "global", "name" => "a"}})).to eq("scope.name")
      expect(refused({"title" => "x", "scope" => []})).to eq("scope")
    end

    it "refuses a dedupe key until the upsert exists, and accepts null" do
      expect(refused({"title" => "x", "dedupe_key" => "k"})).to eq("dedupe_key")
    end

    it "writes nothing when a field is refused" do
      refused({"title" => "x", "type" => "bogus"})

      expect(File.exist?(config.inbox_path("workspace", "api.fix"))).to be(false)
    end

    it "raises not_in_workspace outside a workspace with no scope" do
      allow(project_detector).to receive(:detect).and_return(nil)
      input.string = JSON.generate({"title" => "x"})

      expect { command.add_from_json("-", working_dir: "/tmp") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_in_workspace") }
    end
  end

  describe "#list" do
    before do
      command.add(title: "ws item", working_dir: "/app")
      command.add(title: "project item", target: {project: "api"}, working_dir: "/app")
      command.add(title: "global item", target: {global: true}, working_dir: "/app")
      command.add(title: "other ws item", target: {name: "other"}, working_dir: "/app")
      output.truncate(0)
      output.rewind
    end

    def listed(**opts)
      output.truncate(0)
      output.rewind
      command.list(working_dir: "/app", json: true, **opts)
      JSON.parse(output.string)
    end

    it "reads the workspace, its project and the global list by default, not other workspaces" do
      doc = listed

      expect(doc).to include("schema_version" => 1, "ok" => true, "warnings" => [])
      expect(doc["items"].map { |i| i["title"] }).to contain_exactly("ws item", "project item", "global item")
    end

    it "reads every scope with --all" do
      expect(listed(all: true)["items"].map { |i| i["title"] }).to contain_exactly("ws item", "project item", "global item", "other ws item")
    end

    it "reads only the global list outside a workspace" do
      allow(project_detector).to receive(:detect).and_return(nil)

      expect(listed["items"].map { |i| i["title"] }).to eq(["global item"])
    end

    it "limits to one scope with a scope flag" do
      expect(listed(target: {project: "api"})["items"].map { |i| i["title"] }).to eq(["project item"])
      expect(listed(target: {name: "other"})["items"].map { |i| i["title"] }).to eq(["other ws item"])
    end

    it "skips the project scope when the directory belongs to no project" do
      allow(project_catalog).to receive(:for_cwd).and_raise(Workspace::Error, "No project found")

      expect(listed["items"].map { |i| i["title"] }).to contain_exactly("ws item", "global item")
    end

    it "refuses --all with a scope flag" do
      expect { command.list(all: true, target: {global: true}, working_dir: "/app") }.to raise_error(Workspace::UsageError)
    end

    it "filters by type and state" do
      command.add(title: "a note", type: "note", target: {global: true}, working_dir: "/app")
      id = JSON.parse(File.read(config.inbox_path("global"))).first["id"]
      Workspace::InboxStore.new(path: config.inbox_path("global"), clock: -> { now }).transition(id, to: "done")

      expect(listed(type: "note")["items"].map { |i| i["title"] }).to eq(["a note"])
      expect(listed(states: %w[done])["items"].map { |i| i["title"] }).to eq(["global item"])
      expect(listed(states: %w[open done])["items"].size).to eq(4)
    end

    it "refuses an unknown state or type" do
      expect { command.list(states: %w[bogus], working_dir: "/app") }.to raise_error(Workspace::UsageError)
      expect { command.list(type: "bug", working_dir: "/app") }.to raise_error(Workspace::UsageError)
    end

    it "lists newest change first" do
      later = Time.utc(2026, 10, 16, 13, 0, 0)
      newer = described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
        session_ledger: session_ledger, env: env, clock: -> { later }, output: StringIO.new, error_output: error_output,
        store_factory: ->(path:, scope:, error_output:) { Workspace::InboxStore.new(path: path, scope: scope, clock: -> { later }, error_output: error_output) })
      newer.add(title: "newest", target: {global: true}, working_dir: "/app")

      expect(listed["items"].first["title"]).to eq("newest")
    end

    it "prints a table, one line per item, with control characters escaped" do
      path = config.inbox_path("global")
      records = JSON.parse(File.read(path))
      records.first["title"] = "red \e[31m and\nnewline"
      File.write(path, JSON.generate(records))

      command.list(working_dir: "/app")

      lines = output.string.lines
      expect(lines.first).to match(/\AID\s+STATE\s+TYPE\s+SCOPE\s+TITLE/)
      expect(lines.size).to eq(4)
      expect(output.string).to include('red \e[31m and\nnewline')
      expect(output.string).not_to include("\e")
    end

    it "says so when there is nothing" do
      allow(project_detector).to receive(:detect).and_return(nil)
      FileUtils.rm_f(config.inbox_path("global"))

      command.list(working_dir: "/app")

      expect(output.string).to eq("No items to show. Try --all, or --state open,snoozed,done,dismissed.\n")
    end

    it "reads an unreadable scope file as empty, with one warning" do
      File.write(config.inbox_path("global"), "{nope")

      doc = listed
      expect(doc["items"].map { |i| i["title"] }).to contain_exactly("ws item", "project item")
      expect(doc["warnings"]).to contain_exactly(a_hash_including("code" => "inbox_store_unreadable", "message" => a_string_including("global.json")))
    end

    it "sends the warning to stderr in text mode" do
      File.write(config.inbox_path("global"), "{nope")

      command.list(working_dir: "/app")

      expect(error_output.string).to include("ignoring inbox store")
    end

    it "shows a snooze that has passed as open" do
      path = config.inbox_path("global")
      records = JSON.parse(File.read(path))
      records.first.merge!("state" => "snoozed", "snooze_until" => "2026-10-16T11:00:00Z")
      File.write(path, JSON.generate(records))

      expect(listed["items"].map { |i| [i["title"], i["state"]] }).to include(["global item", "open"])
    end
  end

  describe "#show" do
    let(:item) do
      command.add(title: "Look at this", body: "line1\nline2", source: {kind: "jira", ref: "ABC-1"}, links: {pr: 5},
        target: {name: "other"}, working_dir: "/app")
      JSON.parse(File.read(config.inbox_path("workspace", "other"))).first
    end

    before do
      item
      output.truncate(0)
      output.rewind
    end

    it "prints the item as JSON, found in any scope" do
      command.show(item["id"], working_dir: "/app", json: true)

      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "item" => item, "warnings" => [])
    end

    it "shows an item in any state" do
      Workspace::InboxStore.new(path: config.inbox_path("workspace", "other"), clock: -> { now }).transition(item["id"], to: "dismissed")

      command.show(item["id"], working_dir: "/app", json: true)

      expect(JSON.parse(output.string)["item"]["state"]).to eq("dismissed")
    end

    it "prints text with the body indented and control characters escaped" do
      path = config.inbox_path("workspace", "other")
      records = JSON.parse(File.read(path))
      records.first["title"] = "t\e[2J"
      records.first["body"] = "line1\nbad\e[31m\n\tkept"
      File.write(path, JSON.generate(records))

      command.show(item["id"], working_dir: "/app")

      expect(output.string).to include('t\e[2J')
      expect(output.string).to include("  line1\n").and include('  bad\e[31m').and include("  \tkept")
      expect(output.string).to include("Scope:    workspace:other").and include("jira ABC-1").and include("pr=5")
      expect(output.string).not_to include("\e")
    end

    it "raises unknown_inbox_item for an id no scope has" do
      expect { command.show("0000000000", working_dir: "/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_inbox_item")
        expect(e.details).to eq("id" => "0000000000")
      }
    end

    it "raises ambiguous_inbox_item when two scopes have the id" do
      FileUtils.cp(config.inbox_path("workspace", "other"), config.inbox_path("global"))

      expect { command.show(item["id"], working_dir: "/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("ambiguous_inbox_item")
        expect(e.details["scopes"]).to contain_exactly("workspace:other", "global")
      }
    end

    it "finds an item by id in a scope known only by its file name" do
      project_file = config.inbox_path("project", "/src/api/.git", name: "api")
      FileUtils.mkdir_p(File.dirname(project_file))
      FileUtils.cp(config.inbox_path("workspace", "other"), project_file)
      FileUtils.rm(config.inbox_path("workspace", "other"))

      command.show(item["id"], working_dir: "/app")

      expect(output.string).to include("Scope:    workspace:other")
      command.list(all: true, working_dir: "/app", json: true)
      expect(JSON.parse(output.string.lines.last)["items"].size).to eq(1)
    end

    it "searches only the named scope with a scope flag" do
      expect { command.show(item["id"], target: {global: true}, working_dir: "/app") }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_inbox_item") }
      expect { command.show(item["id"], target: {name: "other"}, working_dir: "/app") }.not_to raise_error
    end
  end

  describe "#done, #dismiss and #reopen" do
    def add_item(title, **opts)
      command.add(title: title, working_dir: "/app", **opts)[:results].first["item"]
    end

    def stored_item(id, kind: "workspace", key: "api.fix")
      stored(config.inbox_path(kind, key)).find { |r| r["id"] == id }
    end

    before { output.truncate(0) && output.rewind }

    it "marks several ids done, one row each, stamping resolved_by" do
      a = add_item("one")
      b = add_item("two")

      result = command.done([a["id"], b["id"]], working_dir: "/app")

      expect(result[:exit_code]).to eq(0)
      expect(result[:results]).to match([
        a_hash_including("id" => a["id"], "outcome" => "resolved", "scope" => "workspace:api.fix"),
        a_hash_including("id" => b["id"], "outcome" => "resolved")
      ])
      expect(stored_item(a["id"])).to include("state" => "done", "resolved_at" => "2026-10-16T12:00:00Z",
        "resolved_by" => {"kind" => "cli", "pane" => nil})
      expect(output.string).to include("#{a["id"]} resolved (workspace:api.fix): one")
    end

    it "dismisses an item" do
      a = add_item("one")

      result = command.dismiss([a["id"]], working_dir: "/app")

      expect(result[:results].first).to include("outcome" => "resolved")
      expect(stored_item(a["id"])["state"]).to eq("dismissed")
    end

    it "records the calling pane, and agent only when the ledger shows an open session" do
      a = add_item("one")
      b = add_item("two")
      env.merge!("TMUX_PANE" => "%7", "TMUX" => "/tmp/tmux-1/default,4242,0")
      allow(session_ledger).to receive(:open_session_for).with(pane_id: "%7", tmux_server: "4242").and_return(nil, "sess-1")

      command.done([a["id"]], working_dir: "/app")
      command.done([b["id"]], working_dir: "/app")

      expect(stored_item(a["id"])["resolved_by"]).to eq("kind" => "cli", "pane" => "%7")
      expect(stored_item(b["id"])["resolved_by"]).to eq("kind" => "agent", "pane" => "%7")
    end

    it "reports an already resolved item as unchanged without rewriting its resolution" do
      a = add_item("one")
      command.done([a["id"]], working_dir: "/app")
      before = stored_item(a["id"])

      result = command.done([a["id"]], working_dir: "/app")

      expect(result[:exit_code]).to eq(0)
      expect(result[:results].first).to include("outcome" => "unchanged")
      expect(stored_item(a["id"])).to eq(before)
      expect(output.string).to include("is already done")
    end

    it "moves a done item to dismissed" do
      a = add_item("one")
      command.done([a["id"]], working_dir: "/app")

      result = command.dismiss([a["id"]], working_dir: "/app")

      expect(result[:results].first["outcome"]).to eq("resolved")
      expect(stored_item(a["id"])["state"]).to eq("dismissed")
    end

    it "gives an unknown id a failed row and exit 1 when all fail" do
      result = command.done(["0000000000"], working_dir: "/app")

      expect(result[:exit_code]).to eq(1)
      expect(result[:results]).to eq([
        {"id" => "0000000000", "outcome" => "failed", "code" => "unknown_inbox_item",
         "error" => "No inbox item '0000000000'.", "details" => {"id" => "0000000000"}}
      ])
      expect(error_output.string).to include("No inbox item '0000000000'.")
    end

    it "is partial (exit 3) when some ids fail, and still resolves the rest" do
      a = add_item("one")

      result = command.done(["0000000000", a["id"]], working_dir: "/app")

      expect(result[:exit_code]).to eq(3)
      expect(result[:results].map { |r| r["outcome"] }).to eq(%w[failed resolved])
      expect(Workspace::JsonEnvelope.action_status(result[:results])).to eq("partial")
      expect(stored_item(a["id"])["state"]).to eq("done")
    end

    it "fails a row whose id is in more than one scope, and resolves it with a scope flag" do
      a = add_item("one")
      FileUtils.cp(config.inbox_path("workspace", "api.fix"), config.inbox_path("global"))

      result = command.done([a["id"]], working_dir: "/app")
      expect(result[:results].first).to include("outcome" => "failed", "code" => "ambiguous_inbox_item")

      result = command.done([a["id"]], target: {global: true}, working_dir: "/app")
      expect(result[:results].first).to include("outcome" => "resolved", "scope" => "global")
      expect(stored_item(a["id"])["state"]).to eq("open")
    end

    it "fails a row for an unreadable scope file (read as empty) without overwriting it" do
      a = add_item("one")
      File.write(config.inbox_path("workspace", "api.fix"), "{not json")

      result = command.done([a["id"]], target: {name: "api.fix"}, working_dir: "/app")

      expect(result[:results].first).to include("outcome" => "failed", "code" => "unknown_inbox_item")
      expect(error_output.string).not_to be_empty
      expect(File.read(config.inbox_path("workspace", "api.fix"))).to eq("{not json")
    end

    it "reopens a done item, clearing the resolution" do
      a = add_item("one")
      command.done([a["id"]], working_dir: "/app")

      result = command.reopen([a["id"]], working_dir: "/app")

      expect(result[:results].first).to include("outcome" => "reopened")
      expect(stored_item(a["id"])).to include("state" => "open", "resolved_at" => nil, "resolved_by" => nil)
    end

    it "reports reopening an open item as unchanged" do
      a = add_item("one")

      expect(command.reopen([a["id"]], working_dir: "/app")[:results].first["outcome"]).to eq("unchanged")
    end

    it "escapes control characters in a title it prints" do
      a = add_item("one")
      path = config.inbox_path("workspace", "api.fix")
      records = stored(path)
      records.first["title"] = "t\e[2J"
      File.write(path, JSON.generate(records))

      command.done([a["id"]], working_dir: "/app")

      expect(output.string).to include('t\e[2J')
      expect(output.string).not_to include("\e")
    end
  end
end
