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

    it "upserts on a dedupe_key and accepts null" do
      post({"title" => "x", "dedupe_key" => nil, "scope" => {"kind" => "global"}})
      first = post({"title" => "CI", "dedupe_key" => "ci:1", "scope" => {"kind" => "global"}})
      second = post({"title" => "CI again", "dedupe_key" => "ci:1", "scope" => {"kind" => "global"}})

      expect(first[:results].first["outcome"]).to eq("created")
      expect(second[:results].first).to include("outcome" => "updated", "id" => first[:results].first["id"])
      expect(stored(config.inbox_path("global")).map { |i| i["title"] }).to eq(["x", "CI again"])
    end

    it "refuses a bad dedupe_key" do
      expect(refused({"title" => "x", "dedupe_key" => "has space"})).to eq("dedupe_key")
      expect(refused({"title" => "x", "dedupe_key" => 5})).to eq("dedupe_key")
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

  describe "#add with a dedupe key" do
    let(:key) { "github_check:zdennis/api:rspec:9f3c2e1" }

    def put(**opts)
      command.add(title: "CI failed", type: "alert", working_dir: "/app", dedupe_key: key, **opts)[:results].first
    end

    def rows
      stored(config.inbox_path("workspace", "api.fix"))
    end

    it "creates once, then updates the same item" do
      first = put
      second = put(body: "3 failures")

      expect(first["outcome"]).to eq("created")
      expect(second).to include("outcome" => "updated", "id" => first["id"])
      expect(rows.size).to eq(1)
      expect(rows.first).to include("body" => "3 failures", "dedupe_key" => key)
      expect(output.string).to include("Updated inbox item #{first["id"]}")
    end

    it "does not nag after a dismissal and reopens only with --reopen" do
      id = put["id"]
      command.dismiss([id], working_dir: "/app")

      suppressed = put
      expect(suppressed).to include("outcome" => "suppressed", "id" => id)
      expect(suppressed["item"]["state"]).to eq("dismissed")
      expect(output.string).to include("pass --reopen")

      reopened = put(reopen: true)
      expect(reopened).to include("outcome" => "reopened", "id" => id)
      expect(rows.first["state"]).to eq("open")
    end

    it "keys per scope, so the same key in another scope is a new item" do
      put
      other = put(target: {global: true})

      expect(other["outcome"]).to eq("created")
    end

    it "refuses --reopen without a key, and a malformed key, writing nothing" do
      expect { command.add(title: "x", working_dir: "/app", reopen: true) }.to raise_error(Workspace::UsageError, /--dedupe-key/)
      expect(refused_field { put(dedupe_key: "a b") }).to eq("dedupe_key")
      expect(refused_field { command.add(title: "x", working_dir: "/app", dedupe_key: "a" * 201) }).to eq("dedupe_key")
      expect(refused_field { command.add(title: "x", working_dir: "/app", dedupe_key: "") }).to eq("dedupe_key")
      expect(File.exist?(config.inbox_path("workspace", "api.fix"))).to be(false)
    end

    it "accepts every character the key allows" do
      expect(put(dedupe_key: "A-z_0.9:/#@")["outcome"]).to eq("created")
    end
  end

  describe "#done and #dismiss with a dedupe key" do
    let(:key) { "ci:1" }

    def add_keyed
      command.add(title: "CI", working_dir: "/app", dedupe_key: key)[:results].first
    end

    before { output.truncate(0) && output.rewind }

    it "resolves the item holding the key in the workspace scope" do
      id = add_keyed["id"]

      result = command.done([], working_dir: "/app", dedupe_key: key)

      expect(result[:exit_code]).to eq(0)
      expect(result[:results]).to contain_exactly(a_hash_including("id" => id, "dedupe_key" => key, "outcome" => "resolved"))
      expect(stored(config.inbox_path("workspace", "api.fix")).first).to include("state" => "done")
    end

    it "dismisses by key in an explicit scope" do
      command.add(title: "CI", target: {global: true}, working_dir: "/app", dedupe_key: key)

      result = command.dismiss([], target: {global: true}, working_dir: "/app", dedupe_key: key)

      expect(result[:results].first).to include("outcome" => "resolved", "scope" => "global")
      expect(stored(config.inbox_path("global")).first).to include("state" => "dismissed", "resolved_by" => a_hash_including("kind" => "cli"))
    end

    it "reports unchanged with exit 0 when nothing holds the key, and when it is already resolved" do
      none = command.done([], working_dir: "/app", dedupe_key: key)
      expect(none[:exit_code]).to eq(0)
      expect(none[:results]).to eq([{"id" => nil, "dedupe_key" => key, "outcome" => "unchanged", "scope" => "workspace:api.fix", "item" => nil}])

      add_keyed
      command.done([], working_dir: "/app", dedupe_key: key)
      again = command.done([], working_dir: "/app", dedupe_key: key)
      expect(again[:results].first).to include("outcome" => "unchanged")
    end

    it "fails the row for an unreadable scope file without overwriting it" do
      path = config.inbox_path("workspace", "api.fix")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "not json")

      result = command.done([], working_dir: "/app", dedupe_key: key)

      expect(result[:exit_code]).to eq(1)
      expect(result[:results]).to contain_exactly(a_hash_including("outcome" => "failed", "code" => "inbox_store_unreadable", "dedupe_key" => key))
      expect(File.read(path)).to eq("not json")
    end

    it "refuses ids together with a key, and a malformed key" do
      expect { command.done(["abc"], working_dir: "/app", dedupe_key: key) }.to raise_error(Workspace::UsageError, /not both/)
      expect(refused_field { command.done([], working_dir: "/app", dedupe_key: "a b") }).to eq("dedupe_key")
    end

    it "raises not_in_workspace outside a workspace with no scope" do
      allow(project_detector).to receive(:detect).and_return(nil)

      expect { command.done([], working_dir: "/x", dedupe_key: key) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_in_workspace") }
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

    it "refuses --all with --global or --project, naming the flag and what to run" do
      expect { command.list(all: true, target: {global: true}, working_dir: "/app") }
        .to raise_error(Workspace::UsageError, /--all cannot be combined with --global.*inbox list --global/m)
      expect { command.list(all: true, target: {project: "api"}, working_dir: "/app") }
        .to raise_error(Workspace::UsageError, /--all cannot be combined with --project/)
    end

    it "reads the named workspace, its project and the global list with --all --name" do
      member = Workspace::ProjectCatalog::Member.new(workspace: "api.fix", path: "/src/fix", kind: "worktree", configured: true, exists: true)
      project = Workspace::ProjectCatalog::Project.new(name: "api", id: "/src/api/.git", path: "/src/api", vcs: "git", members: [member])
      allow(project_catalog).to receive(:all).and_return([project])

      titles = listed(all: true, target: {name: "api.fix"})["items"].map { |i| i["title"] }

      expect(titles).to contain_exactly("ws item", "project item", "global item")
    end

    it "reads only that workspace and the global list with --all --name when no project has it" do
      allow(project_catalog).to receive(:all).and_return([api_project])

      titles = listed(all: true, target: {name: "other"})["items"].map { |i| i["title"] }

      expect(titles).to contain_exactly("other ws item", "global item")
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

  describe "#list with include_derived" do
    # Mirrors InboxDerived#rows: `rows:` in the derived row shape and `warnings:` as {"code", "message"}.
    let(:derived_calls) { [] }
    let(:derived) do
      calls = derived_calls
      Class.new do
        define_method(:rows) do |workspaces:, projects:|
          calls << [workspaces, projects]
          {rows: [{"id" => "pane:waiting:api.fix:%5", "derived" => true, "kind" => "pane_waiting", "fingerprint" => "2026-10-16T11:50:00Z",
                   "type" => "alert", "state" => "open", "scope" => {"kind" => "workspace", "key" => "api.fix", "name" => "api.fix"},
                   "title" => "An agent is waiting in api.fix (%5)", "body" => "Allow Bash?",
                   "links" => {"pane" => "%5", "plan_task" => nil, "pr" => nil, "run_id" => nil},
                   "created_at" => "2026-10-16T11:50:00Z", "updated_at" => "2026-10-16T11:50:00Z"}],
           warnings: [{"code" => "daemons_unavailable", "workspace" => "api", "message" => "The agent daemon for 'api' did not answer (timeout)."}]}
        end
      end.new
    end
    let(:with_derived) do
      described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
        session_ledger: session_ledger, store_factory: store_factory, env: env, input: input, derived: derived,
        clock: -> { now }, output: output, error_output: error_output)
    end

    before { with_derived.add(title: "ws item", working_dir: "/app") }

    def listed(**opts)
      output.truncate(0)
      output.rewind
      with_derived.list(working_dir: "/app", json: true, **opts)
      JSON.parse(output.string)
    end

    it "reads no derived source without the flag" do
      listed

      expect(derived_calls).to be_empty
    end

    it "adds the derived rows and their warnings, newest first with the stored items" do
      doc = listed(include_derived: true)

      expect(doc["items"].map { |i| i["title"] }).to eq(["ws item", "An agent is waiting in api.fix (%5)"])
      expect(doc["items"].last).to include("derived" => true, "fingerprint" => "2026-10-16T11:50:00Z")
      expect(doc["warnings"].map { |w| w["code"] }).to eq(["daemons_unavailable"])
    end

    it "reads the detected workspace and its project by default" do
      listed(include_derived: true)

      expect(derived_calls).to eq([[["api.fix"], [api_project]]])
    end

    it "reads only the named workspace, only the project, or nothing for the global list" do
      listed(include_derived: true, target: {name: "other"})
      listed(include_derived: true, target: {project: "api"})
      listed(include_derived: true, target: {global: true})

      expect(derived_calls).to eq([[["other"], []], [[], [api_project]], [[], []]])
    end

    it "reads nothing derived outside a workspace" do
      allow(project_detector).to receive(:detect).and_return(nil)

      listed(include_derived: true)

      expect(derived_calls).to eq([[[], []]])
    end

    it "reads every configured workspace with a checkout and every project with --all" do
      members = [Workspace::ProjectCatalog::Member.new(workspace: "api", path: "/src/api", kind: "main", configured: true, exists: true),
        Workspace::ProjectCatalog::Member.new(workspace: "api.gone", path: "/src/gone", kind: "worktree", configured: true, exists: false),
        Workspace::ProjectCatalog::Member.new(workspace: "api.loose", path: "/src/loose", kind: "worktree", configured: false, exists: true)]
      project = Workspace::ProjectCatalog::Project.new(name: "api", id: "/src/api/.git", path: "/src/api", vcs: "git", members: members)
      allow(project_catalog).to receive(:all).and_return([project])

      listed(include_derived: true, all: true)

      expect(derived_calls).to eq([[["api"], [project]]])
    end

    it "reads the named workspace and its project with --all --name" do
      member = Workspace::ProjectCatalog::Member.new(workspace: "api.fix", path: "/src/fix", kind: "worktree", configured: true, exists: true)
      project = Workspace::ProjectCatalog::Project.new(name: "api", id: "/src/api/.git", path: "/src/api", vcs: "git", members: [member])
      allow(project_catalog).to receive(:all).and_return([project])

      listed(include_derived: true, all: true, target: {name: "api.fix"})

      expect(derived_calls).to eq([[["api.fix"], [project]]])
    end

    it "reads nothing derived when the states or type leave open alerts out" do
      listed(include_derived: true, states: %w[done])
      listed(include_derived: true, type: "note")
      listed(include_derived: true, type: "alert")

      expect(derived_calls.size).to eq(1)
    end

    it "prints derived rows in the table and their warnings on stderr" do
      with_derived.list(working_dir: "/app", include_derived: true)

      expect(output.string).to include("pane:waiting:api.fix:%5", "An agent is waiting in api.fix (%5)")
      expect(error_output.string).to include("did not answer")
    end

    it "fails when no derived reader is wired" do
      expect { command.list(working_dir: "/app", include_derived: true) }.to raise_error(Workspace::Error, /not available/)
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

  describe "#edit" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }
    let(:logged) do
      described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
        session_ledger: session_ledger, store_factory: store_factory, env: env, input: input,
        clock: -> { now }, event_log: event_log, output: output, error_output: error_output)
    end

    def add_item(**opts)
      command.add(title: "Old title", working_dir: "/app", **opts)[:results].first["item"]
    end

    def edit_row(*args, **opts)
      command.edit(*args, working_dir: "/app", **opts)[:results].first
    end

    it "changes the title, body, expiry and links, keeping the rest, and stamps updated_at" do
      item = add_item(body: "old", links: {pane: "%1", pr: 3})
      later = now + 60
      editor = described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
        session_ledger: session_ledger, store_factory: ->(path:, scope:, error_output:) { Workspace::InboxStore.new(path: path, scope: scope, clock: -> { later }, error_output: error_output) },
        env: env, input: input, clock: -> { later }, output: output, error_output: error_output)

      row = editor.edit(item["id"], title: " New title ", body: "new body", expires: "2h", links: {pr: 9, run_id: "r1"},
        working_dir: "/app")[:results].first

      expect(row).to include("outcome" => "updated", "id" => item["id"], "scope" => "workspace:api.fix")
      stored_item = stored(config.inbox_path("workspace", "api.fix")).first
      expect(stored_item).to include("title" => "New title", "body" => "new body", "expires_at" => "2026-10-16T14:01:00Z",
        "state" => "open", "created_at" => item["created_at"], "updated_at" => "2026-10-16T12:01:00Z",
        "links" => {"pane" => "%1", "plan_task" => nil, "pr" => 9, "run_id" => "r1"})
      expect(row["item"]).to eq(stored_item)
      expect(output.string).to include("Updated inbox item #{item["id"]} in workspace:api.fix: New title")
    end

    it "clears the body, a link and the expiry" do
      item = add_item(body: "old", expires: "2h", links: {pane: "%1", pr: 3})

      edit_row(item["id"], body: "", links: {pane: "", pr: ""}, no_expires: true)

      expect(stored(config.inbox_path("workspace", "api.fix")).first).to include("body" => nil, "expires_at" => nil,
        "links" => {"pane" => nil, "plan_task" => nil, "pr" => nil, "run_id" => nil})
    end

    it "reads the body from a file" do
      item = add_item
      path = File.join(tmpdir, "body.txt")
      File.write(path, "from file\n")

      edit_row(item["id"], body_file: path)

      expect(stored(config.inbox_path("workspace", "api.fix")).first["body"]).to eq("from file")
    end

    it "is unchanged, and writes nothing, when every value is what the item holds" do
      item = add_item(body: "b", links: {pr: 3})
      before = File.read(config.inbox_path("workspace", "api.fix"))

      result = command.edit(item["id"], title: "Old title", body: "b", links: {pr: 3}, working_dir: "/app")

      expect(result).to include(exit_code: 0)
      expect(result[:results].first).to include("outcome" => "unchanged", "id" => item["id"])
      expect(File.read(config.inbox_path("workspace", "api.fix"))).to eq(before)
      expect(output.string).to include("No change to inbox item #{item["id"]}")
    end

    it "is unchanged when it clears a field a hand-edited record never had" do
      item = add_item
      path = config.inbox_path("workspace", "api.fix")
      data = stored(path)
      data.first.delete("expires_at")
      data.first["links"] = {}
      File.write(path, JSON.generate(data))

      row = edit_row(item["id"], no_expires: true, links: {pane: ""})
      expect(row["outcome"]).to eq("unchanged")

      data.first.delete("links")
      File.write(path, JSON.generate(data))
      expect(edit_row(item["id"], title: "Old title")["outcome"]).to eq("unchanged")
    end

    it "refuses an empty body file instead of clearing the body" do
      item = add_item(body: "keep")
      path = File.join(tmpdir, "empty.txt")
      File.write(path, "\n")

      expect(refused_field { command.edit(item["id"], body_file: path, working_dir: "/app") }).to eq("body")
      expect(stored(config.inbox_path("workspace", "api.fix")).first["body"]).to eq("keep")
    end

    it "edits a done item without reopening it" do
      item = add_item
      command.done([item["id"]], working_dir: "/app")

      row = edit_row(item["id"], title: "Renamed")

      expect(row["outcome"]).to eq("updated")
      expect(stored(config.inbox_path("workspace", "api.fix")).first).to include("title" => "Renamed", "state" => "done")
    end

    it "edits an item in another scope when no scope flag is given" do
      item = add_item(target: {global: true})

      row = command.edit(item["id"], title: "Renamed", working_dir: "/app")[:results].first

      expect(row).to include("outcome" => "updated", "scope" => "global")
    end

    it "checks each field like add and writes nothing when one is refused" do
      item = add_item
      before = File.read(config.inbox_path("workspace", "api.fix"))

      expect(refused_field { command.edit(item["id"], title: "  ", working_dir: "/app") }).to eq("title")
      expect(refused_field { command.edit(item["id"], title: "a\e[2Jb", working_dir: "/app") }).to eq("title")
      expect(refused_field { command.edit(item["id"], body: "x" * 8193, working_dir: "/app") }).to eq("body")
      expect(refused_field { command.edit(item["id"], expires: "soon", working_dir: "/app") }).to eq("expires")
      expect(refused_field { command.edit(item["id"], expires: "2020-01-01T00:00:00Z", working_dir: "/app") }).to eq("expires")
      expect(refused_field { command.edit(item["id"], links: {pr: "x"}, working_dir: "/app") }).to eq("links.pr")
      expect(refused_field { command.edit(item["id"], links: {pane: "p" * 65}, working_dir: "/app") }).to eq("links.pane")
      expect(File.read(config.inbox_path("workspace", "api.fix"))).to eq(before)
    end

    it "refuses with usage when nothing is given, or options conflict" do
      item = add_item

      expect { command.edit(item["id"], working_dir: "/app") }.to raise_error(Workspace::UsageError, /Nothing to change/)
      expect { command.edit(item["id"], body: "a", body_file: "-", working_dir: "/app") }.to raise_error(Workspace::UsageError)
      expect { command.edit(item["id"], expires: "2h", no_expires: true, working_dir: "/app") }.to raise_error(Workspace::UsageError)
    end

    it "raises unknown_inbox_item for an id no scope holds" do
      add_item

      expect { command.edit("0000000000", title: "x", working_dir: "/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_inbox_item")
      }
    end

    it "raises ambiguous_inbox_item when two scopes hold the id, and a scope flag picks one" do
      item = add_item
      other = config.inbox_path("global")
      FileUtils.mkdir_p(File.dirname(other))
      File.write(other, JSON.generate([item.merge("scope" => {"kind" => "global", "key" => nil, "name" => nil})]))

      expect { command.edit(item["id"], title: "x", working_dir: "/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("ambiguous_inbox_item")
      }
      expect(edit_row(item["id"], title: "x", target: {global: true})["scope"]).to eq("global")
    end

    it "writes one updated event, with no text, only when something changed" do
      item = logged.add(title: "Secret", working_dir: "/app")[:results].first["item"]
      event_log.events.clear

      logged.edit(item["id"], title: "Secret", working_dir: "/app")
      expect(event_log.events).to be_empty

      logged.edit(item["id"], title: "Other secret", working_dir: "/app")
      data = {"id" => item["id"], "scope" => "workspace", "scope_key" => "api.fix", "state" => "open", "change" => "updated"}
      expect(event_log.events).to eq([{"type" => "inbox_changed", "project" => "api.fix", "data" => data}])
    end

    it "prints the title with control characters escaped" do
      item = add_item

      edit_row(item["id"], title: "plain")
      stored_path = config.inbox_path("workspace", "api.fix")
      data = stored(stored_path)
      data.first["title"] = "bad\e[2J"
      File.write(stored_path, JSON.generate(data))
      output.truncate(0)
      output.rewind

      edit_row(item["id"], body: "b")

      expect(output.string).to include("bad\\e[2J")
      expect(output.string).not_to include("\e")
    end
  end

  describe "inbox_changed events" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }

    subject(:command) do
      described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
        session_ledger: session_ledger, store_factory: store_factory, env: env, input: input,
        clock: -> { now }, event_log: event_log, output: output, error_output: error_output)
    end

    def add_item(title, **opts)
      command.add(title: title, working_dir: "/app", **opts)[:results].first["item"]
    end

    it "writes one created event for a workspace item, with ids and states only" do
      item = add_item("Secret title", body: "secret body", source: {ref: "SECRET-1"})

      data = {"id" => item["id"], "scope" => "workspace", "scope_key" => "api.fix", "state" => "open", "change" => "created"}
      expect(event_log.events).to eq([{"type" => "inbox_changed", "project" => "api.fix", "data" => data}])
      expect(event_log.events.to_s).not_to match(/Secret|secret|SECRET/)
    end

    it "uses the project's display name for a project item" do
      item = add_item("x", target: {project: "api"})

      expect(event_log.events.last).to eq({"type" => "inbox_changed", "project" => "api",
        "data" => {"id" => item["id"], "scope" => "project", "scope_key" => "/src/api/.git", "state" => "open", "change" => "created"}})
    end

    it "uses an empty project for a global item" do
      item = add_item("x", target: {global: true})

      expect(event_log.events.last).to eq({"type" => "inbox_changed", "project" => "",
        "data" => {"id" => item["id"], "scope" => "global", "scope_key" => nil, "state" => "open", "change" => "created"}})
    end

    it "writes updated and reopened for upserts, and nothing for suppressed" do
      id = command.add(title: "CI", working_dir: "/app", dedupe_key: "ci:1")[:results].first["id"]
      command.add(title: "CI 2", working_dir: "/app", dedupe_key: "ci:1")
      command.dismiss([id], working_dir: "/app")
      command.add(title: "CI 3", working_dir: "/app", dedupe_key: "ci:1")
      command.add(title: "CI 4", working_dir: "/app", dedupe_key: "ci:1", reopen: true)

      expect(event_log.events.map { |e| [e["data"]["change"], e["data"]["state"]] }).to eq(
        [%w[created open], %w[updated open], %w[resolved dismissed], %w[reopened open]]
      )
    end

    it "writes resolved for a done by dedupe key, and nothing when no item holds it" do
      command.add(title: "CI", working_dir: "/app", dedupe_key: "ci:1")
      command.done([], working_dir: "/app", dedupe_key: "ci:1")
      command.done([], working_dir: "/app", dedupe_key: "none")

      expect(event_log.events.map { |e| e["data"]["change"] }).to eq(%w[created resolved])
    end

    it "writes resolved for done and dismiss,
 and reopened for reopen, each with the new state" do
      a = add_item("a")
      b = add_item("b")
      event_log.events.clear

      command.done([a["id"]], working_dir: "/app")
      command.dismiss([b["id"]], working_dir: "/app")
      command.reopen([a["id"]], working_dir: "/app")

      expect(event_log.events.map { |e| [e["data"]["id"], e["data"]["state"], e["data"]["change"]] }).to eq([
        [a["id"], "done", "resolved"], [b["id"], "dismissed", "resolved"], [a["id"], "open", "reopened"]
      ])
    end

    it "writes nothing for an unchanged outcome or a failed row" do
      a = add_item("a")
      event_log.events.clear

      command.reopen([a["id"]], working_dir: "/app")
      command.done(["nosuchid"], working_dir: "/app")

      expect(event_log.events).to be_empty
    end

    it "writes nothing when an add is refused" do
      expect { command.add(title: "", working_dir: "/app") }.to raise_error(Workspace::Error)

      expect(event_log.events).to be_empty
    end

    it "still succeeds when the log cannot be written" do
      unwritable = instance_double(Workspace::Config, event_log_file: File.join(tmpdir, "missing-dir", "events.jsonl"))
      real = Workspace::EventLog.new(config: unwritable, error_output: StringIO.new)
      failing = described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
        session_ledger: session_ledger, store_factory: store_factory, env: env, input: input,
        clock: -> { now }, event_log: real, output: output, error_output: error_output)

      result = failing.add(title: "x", working_dir: "/app")

      expect(result[:exit_code]).to eq(0)
    end
  end
  # Commands built on a clock of their own, over the same temp store.
  def inbox_at(time, **extra)
    described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
      session_ledger: session_ledger, env: env, input: input, clock: -> { time },
      output: extra.delete(:output) || StringIO.new, error_output: error_output,
      store_factory: ->(path:, scope:, error_output:) { Workspace::InboxStore.new(path: path, scope: scope, clock: -> { time }, error_output: error_output) },
      **extra)
  end

  def listed_at(time, **opts)
    io = StringIO.new
    inbox_at(time, output: io).list(working_dir: "/app", json: true, **opts)
    JSON.parse(io.string)["items"]
  end

  describe "#snooze" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }

    def add_item(title = "one", **opts)
      command.add(title: title, working_dir: "/app", **opts)[:results].first["item"]
    end

    def stored_item(id)
      stored(config.inbox_path("workspace", "api.fix")).find { |r| r["id"] == id }
    end

    it "snoozes for a duration and reports the wake time" do
      item = add_item

      result = command.snooze([item["id"]], for_duration: "2h", working_dir: "/app")

      expect(result[:exit_code]).to eq(0)
      expect(result[:results]).to contain_exactly(a_hash_including("id" => item["id"], "outcome" => "snoozed", "scope" => "workspace:api.fix",
        "item" => a_hash_including("state" => "snoozed", "snooze_until" => "2026-10-16T14:00:00Z")))
      expect(stored_item(item["id"])).to include("state" => "snoozed", "snooze_until" => "2026-10-16T14:00:00Z")
      expect(output.string).to include("#{item["id"]} snoozed until 2026-10-16T14:00:00Z (workspace:api.fix): one")
    end

    it "snoozes until an ISO 8601 time, converted to UTC" do
      item = add_item

      command.snooze([item["id"]], until_time: "2026-10-17T09:00:00+02:00", working_dir: "/app")

      expect(stored_item(item["id"])["snooze_until"]).to eq("2026-10-17T07:00:00Z")
    end

    it "needs exactly one of --until and --for, and an id" do
      item = add_item

      expect { command.snooze([item["id"]], working_dir: "/app") }.to raise_error(Workspace::UsageError, /--until or --for/)
      expect { command.snooze([item["id"]], until_time: "2026-10-17T09:00:00Z", for_duration: "1h", working_dir: "/app") }
        .to raise_error(Workspace::UsageError, /not both/)
      expect { command.snooze([], for_duration: "1h", working_dir: "/app") }.to raise_error(Workspace::UsageError)
    end

    it "refuses a time that is not in the future, a bad time and a bad duration, naming the field" do
      item = add_item

      expect(refused_field { command.snooze([item["id"]], until_time: "2026-10-16T12:00:00Z", working_dir: "/app") }).to eq("until")
      expect(refused_field { command.snooze([item["id"]], until_time: "tomorrow", working_dir: "/app") }).to eq("until")
      expect(refused_field { command.snooze([item["id"]], for_duration: "soon", working_dir: "/app") }).to eq("for")
      expect(refused_field { command.snooze([item["id"]], for_duration: "0", working_dir: "/app") }).to eq("for")
      expect(stored_item(item["id"])["state"]).to eq("open")
    end

    it "hides the item from the default list until the wake time, then it reads open" do
      item = add_item
      command.snooze([item["id"]], for_duration: "2h", working_dir: "/app")

      expect(listed_at(now + 3599).map { |i| i["id"] }).not_to include(item["id"])
      woke = listed_at(now + 7200).find { |i| i["id"] == item["id"] }
      expect(woke).to include("state" => "open", "snooze_until" => nil)
    end

    it "lists a snoozed item under --state snoozed" do
      item = add_item
      command.snooze([item["id"]], for_duration: "2h", working_dir: "/app")

      expect(listed_at(now + 60, states: %w[snoozed]).map { |i| i["id"] }).to eq([item["id"]])
    end

    it "changes the wake time of a snoozed item, and reports the same time as unchanged" do
      item = add_item
      command.snooze([item["id"]], until_time: "2026-10-16T14:00:00Z", working_dir: "/app")

      same = command.snooze([item["id"]], until_time: "2026-10-16T14:00:00Z", working_dir: "/app")[:results].first
      moved = command.snooze([item["id"]], until_time: "2026-10-16T16:00:00Z", working_dir: "/app")[:results].first

      expect(same["outcome"]).to eq("unchanged")
      expect(moved["outcome"]).to eq("snoozed")
      expect(stored_item(item["id"])["snooze_until"]).to eq("2026-10-16T16:00:00Z")
    end

    it "refuses to snooze a done or dismissed item, as a failed row" do
      item = add_item
      command.done([item["id"]], working_dir: "/app")

      result = command.snooze([item["id"]], for_duration: "1h", working_dir: "/app")

      expect(result[:exit_code]).to eq(1)
      expect(result[:results].first).to include("outcome" => "failed", "code" => "invalid_inbox_item",
        "details" => {"field" => "state", "reason" => a_string_matching(/done.*reopen/)})
      expect(stored_item(item["id"])["state"]).to eq("done")
    end

    it "handles several ids, with a failed row for an unknown one" do
      a = add_item("a")

      result = command.snooze([a["id"], "nosuchid"], for_duration: "1h", working_dir: "/app")

      expect(result[:exit_code]).to eq(3)
      expect(result[:results].map { |r| r["outcome"] }).to eq(%w[snoozed failed])
    end

    it "is cleared by reopen" do
      item = add_item
      command.snooze([item["id"]], for_duration: "1h", working_dir: "/app")

      row = command.reopen([item["id"]], working_dir: "/app")[:results].first

      expect(row["outcome"]).to eq("reopened")
      expect(stored_item(item["id"])).to include("state" => "open", "snooze_until" => nil)
    end

    it "writes inbox_changed with change snoozed, and nothing for an unchanged or refused snooze" do
      logged = inbox_at(now, event_log: event_log)
      item = logged.add(title: "x", working_dir: "/app")[:results].first["item"]
      event_log.events.clear

      logged.snooze([item["id"]], until_time: "2026-10-16T14:00:00Z", working_dir: "/app")
      logged.snooze([item["id"]], until_time: "2026-10-16T14:00:00Z", working_dir: "/app")
      expect { logged.snooze([item["id"]], for_duration: "bad", working_dir: "/app") }.to raise_error(Workspace::Error)

      expect(event_log.events).to eq([{"type" => "inbox_changed", "project" => "api.fix",
                                       "data" => {"id" => item["id"], "scope" => "workspace", "scope_key" => "api.fix", "state" => "snoozed", "change" => "snoozed"}}])
    end

    it "keeps the item's text out of the event log" do
      logged = inbox_at(now, event_log: event_log)
      item = logged.add(title: "secret title", body: "secret body", working_dir: "/app")[:results].first["item"]

      logged.snooze([item["id"]], for_duration: "1h", working_dir: "/app")

      expect(event_log.events.to_s).not_to include("secret")
    end
  end

  describe "expiry" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }
    let(:later) { now + 4 * 3600 }

    it "leaves an expired item out of the default list and shows it as dismissed by expiry" do
      item = command.add(title: "short lived", expires: "1h", working_dir: "/app")[:results].first["item"]

      expect(listed_at(now + 1800).map { |i| i["id"] }).to include(item["id"])
      expect(listed_at(later).map { |i| i["id"] }).not_to include(item["id"])
      expired = listed_at(later, states: %w[dismissed]).find { |i| i["id"] == item["id"] }
      expect(expired).to include("state" => "dismissed", "resolved_by" => {"kind" => "expiry"})
    end

    it "stores the expiry on the next write and logs expired once for each item" do
      a = command.add(title: "a", expires: "1h", working_dir: "/app")[:results].first["item"]
      b = command.add(title: "b", expires: "2h", working_dir: "/app")[:results].first["item"]
      command.add(title: "c", expires: "9h", working_dir: "/app")
      event_log.events.clear

      inbox_at(later, event_log: event_log).add(title: "d", working_dir: "/app")
      inbox_at(later, event_log: event_log).add(title: "e", working_dir: "/app")

      expired = event_log.events.select { |e| e["data"]["change"] == "expired" }
      expect(expired.map { |e| e["data"]["id"] }).to contain_exactly(a["id"], b["id"])
      expect(expired.first).to include("type" => "inbox_changed", "project" => "api.fix")
      expect(expired.first["data"]).to include("scope" => "workspace", "scope_key" => "api.fix", "state" => "dismissed")
      expect(stored(config.inbox_path("workspace", "api.fix")).find { |r| r["id"] == a["id"] })
        .to include("state" => "dismissed", "resolved_by" => {"kind" => "expiry"})
    end

    it "logs expired for an item that expired during a done on another item" do
      a = command.add(title: "a", expires: "1h", working_dir: "/app")[:results].first["item"]
      b = command.add(title: "b", working_dir: "/app")[:results].first["item"]
      event_log.events.clear

      inbox_at(later, event_log: event_log).done([b["id"]], working_dir: "/app")

      changes = event_log.events.map { |e| [e["data"]["id"], e["data"]["change"]] }
      expect(changes).to contain_exactly([a["id"], "expired"], [b["id"], "resolved"])
    end

    it "logs nothing for a read of an expired item" do
      command.add(title: "a", expires: "1h", working_dir: "/app")
      event_log.events.clear

      listed_at(later)

      expect(event_log.events).to be_empty
    end
  end

  describe "derived ids: #ack, #snooze and #list" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }
    let(:fingerprint) { {"pane" => "2026-10-16T11:50:00Z"} }
    let(:derived_calls) { [] }
    let(:warnings) { [] }
    # Mirrors InboxDerived#rows: rows in the derived shape, `fingerprint` read at the time of the call.
    let(:derived) do
      calls = derived_calls
      prints = fingerprint
      noted = warnings
      Class.new do
        define_method(:rows) do |workspaces:, projects:|
          calls << [workspaces, projects]
          scope = {"kind" => "workspace", "key" => "api.fix", "name" => "api.fix"}
          links = {"pane" => nil, "plan_task" => nil, "pr" => nil, "run_id" => nil}
          {rows: [
            {"id" => "pane:waiting:api.fix:%5", "derived" => true, "kind" => "pane_waiting", "fingerprint" => prints["pane"], "type" => "alert",
             "state" => "open", "scope" => scope, "title" => "An agent is waiting in api.fix (%5)", "body" => "Allow Bash?", "links" => links,
             "created_at" => prints["pane"], "updated_at" => prints["pane"]},
            {"id" => "ask:api.fix:q1", "derived" => true, "kind" => "ask", "fingerprint" => "2026-10-16T11:00:00Z", "type" => "alert",
             "state" => "open", "scope" => scope, "title" => "Which db?", "body" => "Which db?", "links" => links,
             "created_at" => "2026-10-16T11:00:00Z", "updated_at" => "2026-10-16T11:00:00Z"},
            {"id" => "lock:stale:abc123abc123:devenv", "derived" => true, "kind" => "lock_stale", "fingerprint" => "1760000000", "type" => "alert",
             "state" => "open", "scope" => {"kind" => "project", "key" => "/src/api/.git", "name" => "api"}, "title" => "Lock devenv in api is stuck",
             "body" => nil, "links" => links, "created_at" => "2026-10-16T11:00:00Z", "updated_at" => "2026-10-16T11:00:00Z"}
          ], warnings: noted}
        end
      end.new
    end
    let(:acks_path) { File.join(tmpdir, ".inbox", "acks.json") }
    let(:acks) { Workspace::InboxAcks.new(path: acks_path, clock: -> { now }) }
    let(:with_acks) do
      described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
        session_ledger: session_ledger, store_factory: store_factory, env: env, input: input, derived: derived, acks: acks,
        clock: -> { now }, event_log: event_log, output: output, error_output: error_output)
    end
    let(:pane_id) { "pane:waiting:api.fix:%5" }

    before { allow(project_catalog).to receive(:all).and_return([api_project]) }

    def listed(**opts)
      output.truncate(0)
      output.rewind
      with_acks.list(working_dir: "/app", json: true, include_derived: true, **opts)
      JSON.parse(output.string)
    end

    def acks_file
      JSON.parse(File.read(acks_path))
    end

    describe "#ack" do
      it "stores the id and fingerprint, and the row leaves list" do
        result = with_acks.ack([pane_id], working_dir: "/app")

        expect(result[:exit_code]).to eq(0)
        expect(result[:results]).to contain_exactly(a_hash_including("id" => pane_id, "outcome" => "acked", "scope" => "workspace:api.fix",
          "item" => a_hash_including("derived" => true, "fingerprint" => "2026-10-16T11:50:00Z")))
        expect(acks_file).to contain_exactly(a_hash_including("id" => pane_id, "fingerprint" => "2026-10-16T11:50:00Z"))
        expect(listed["items"].map { |i| i["id"] }).not_to include(pane_id)
      end

      it "brings the row back when its fingerprint changes" do
        with_acks.ack([pane_id], working_dir: "/app")
        fingerprint["pane"] = "2026-10-16T11:59:00Z"

        expect(listed["items"].map { |i| i["id"] }).to include(pane_id)
      end

      it "is unchanged for an ack already stored, and writes no event" do
        with_acks.ack([pane_id], working_dir: "/app")
        event_log.events.clear

        result = with_acks.ack([pane_id], working_dir: "/app")

        expect(result[:results].first["outcome"]).to eq("unchanged")
        expect(event_log.events).to be_empty
      end

      it "writes one inbox_changed event with the id and no text" do
        with_acks.ack([pane_id], working_dir: "/app")

        expect(event_log.events).to eq([{"type" => "inbox_changed", "project" => "api.fix",
                                         "data" => {"id" => pane_id, "scope" => "workspace", "scope_key" => "api.fix", "state" => "open", "change" => "acked"}}])
      end

      it "refuses an ask: id as use_ask_answer without reading any derived source" do
        result = with_acks.ack(["ask:api.fix:q1"], working_dir: "/app")

        expect(result[:exit_code]).to eq(1)
        expect(result[:results].first).to include("outcome" => "failed", "code" => "use_ask_answer", "details" => {"id" => "ask:api.fix:q1"})
        expect(result[:results].first["error"]).to include("ask answer")
        expect(derived_calls).to be_empty
        expect(File.exist?(acks_path)).to be(false)
      end

      it "refuses an id no derived source produces right now as unknown_derived_item" do
        result = with_acks.ack(["pane:waiting:api.fix:%9"], working_dir: "/app")

        expect(result[:results].first).to include("outcome" => "failed", "code" => "unknown_derived_item", "details" => {"id" => "pane:waiting:api.fix:%9"})
        expect(File.exist?(acks_path)).to be(false)
      end

      it "refuses a stored item id as unknown_derived_item" do
        item = with_acks.add(title: "todo", working_dir: "/app")[:results].first["item"]

        result = with_acks.ack([item["id"]], working_dir: "/app")

        expect(result[:results].first).to include("outcome" => "failed", "code" => "unknown_derived_item")
        expect(derived_calls).to be_empty
      end

      it "points a stored item id at done and dismiss" do
        result = with_acks.ack(["a1b2c3d4e5"], working_dir: "/app")

        expect(result[:results].first["error"]).to include("done")
      end

      it "refuses a row with no fingerprint, so a later episode is not hidden by it" do
        derived_rows = derived.rows(workspaces: [], projects: [])[:rows]
        derived_rows.first["fingerprint"] = ""
        allow(derived).to receive(:rows).and_return({rows: derived_rows, warnings: []})

        result = with_acks.ack([pane_id], working_dir: "/app")

        expect(result[:results].first).to include("outcome" => "failed", "code" => "unknown_derived_item")
        expect(result[:results].first["error"]).to include("no fingerprint")
        expect(File.exist?(acks_path)).to be(false)
      end

      it "carries on with the other ids when the acks file can't be written" do
        File.write(File.join(tmpdir, ".inbox"), "in the way")

        result = with_acks.ack([pane_id, "lock:stale:abc123abc123:devenv"], working_dir: "/app")

        expect(result[:results].map { |r| r["code"] }).to eq(%w[inbox_store_unreadable inbox_store_unreadable])
        expect(result[:exit_code]).to eq(1)
      end

      it "does each id on its own: partial is exit 3, all failed is 1" do
        result = with_acks.ack([pane_id, "ask:api.fix:q1", "lock:stale:abc123abc123:devenv"], working_dir: "/app")

        expect(result[:results].map { |r| r["outcome"] }).to eq(%w[acked failed acked])
        expect(result[:exit_code]).to eq(3)
      end

      it "reads every workspace and project without a scope flag, and the named scope with one" do
        with_acks.ack([pane_id], working_dir: "/app")
        with_acks.ack([pane_id], target: {name: "api.fix"}, working_dir: "/app")

        expect(derived_calls).to eq([[[], [api_project]], [["api.fix"], []]])
      end

      it "prints the derived warnings on stderr" do
        warnings << {"code" => "daemons_unavailable", "message" => "The agent daemon did not answer."}

        with_acks.ack([pane_id], working_dir: "/app")

        expect(error_output.string).to include("The agent daemon did not answer.")
      end

      it "prints the title with control characters escaped" do
        derived_rows = derived.rows(workspaces: [], projects: [])[:rows]
        derived_rows.first["title"] = "x\e[2Jy"
        allow(derived).to receive(:rows).and_return({rows: derived_rows, warnings: []})

        with_acks.ack([pane_id], working_dir: "/app")

        expect(output.string).to include('x\e[2Jy')
        expect(output.string).not_to include("\e")
      end

      it "needs an id" do
        expect { with_acks.ack([], working_dir: "/app") }.to raise_error(Workspace::UsageError, /at least one id/)
      end

      it "fails when no acks store is wired" do
        expect { with_derived_only.ack([pane_id], working_dir: "/app") }.to raise_error(Workspace::Error, /not available/)
      end

      it "refuses an unreadable acks file as a failed row and leaves it alone" do
        FileUtils.mkdir_p(File.dirname(acks_path))
        File.write(acks_path, "{nope")

        result = with_acks.ack([pane_id], working_dir: "/app")

        expect(result[:results].first).to include("outcome" => "failed", "code" => "inbox_store_unreadable")
        expect(File.read(acks_path)).to eq("{nope")
      end
    end

    describe "#snooze of a derived id" do
      it "stores the same record with an until, and the row leaves list until then" do
        result = with_acks.snooze([pane_id], for_duration: "2h", working_dir: "/app")

        expect(result[:results]).to contain_exactly(a_hash_including("id" => pane_id, "outcome" => "snoozed", "scope" => "workspace:api.fix"))
        expect(acks_file).to contain_exactly(a_hash_including("id" => pane_id, "fingerprint" => "2026-10-16T11:50:00Z", "until" => "2026-10-16T14:00:00Z"))
        expect(listed["items"].map { |i| i["id"] }).not_to include(pane_id)
      end

      it "shows the row again after until" do
        with_acks.snooze([pane_id], until_time: "2026-10-16T13:00:00Z", working_dir: "/app")
        later = Workspace::InboxAcks.new(path: acks_path, clock: -> { Time.utc(2026, 10, 16, 13, 0, 1) })
        reader = described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
          session_ledger: session_ledger, store_factory: store_factory, env: env, input: input, derived: derived, acks: later,
          clock: -> { Time.utc(2026, 10, 16, 13, 0, 1) }, output: output, error_output: error_output)
        output.truncate(0)
        output.rewind

        reader.list(working_dir: "/app", json: true, include_derived: true)

        expect(JSON.parse(output.string)["items"].map { |i| i["id"] }).to include(pane_id)
      end

      it "is unchanged for the same time, moves for a new one, and writes the snoozed event" do
        with_acks.snooze([pane_id], until_time: "2026-10-16T13:00:00Z", working_dir: "/app")
        event_log.events.clear

        same = with_acks.snooze([pane_id], until_time: "2026-10-16T13:00:00Z", working_dir: "/app")
        moved = with_acks.snooze([pane_id], until_time: "2026-10-16T15:00:00Z", working_dir: "/app")

        expect(same[:results].first["outcome"]).to eq("unchanged")
        expect(moved[:results].first["outcome"]).to eq("snoozed")
        expect(event_log.events.map { |e| e["data"]["change"] }).to eq(["snoozed"])
      end

      it "refuses an ask: id as use_ask_answer and an unknown id as unknown_derived_item" do
        result = with_acks.snooze(["ask:api.fix:q1", "plan:blocked:api.fix"], for_duration: "1h", working_dir: "/app")

        expect(result[:results].map { |r| r["code"] }).to eq(%w[use_ask_answer unknown_derived_item])
        expect(result[:exit_code]).to eq(1)
      end

      it "snoozes stored and derived ids together, in order" do
        item = with_acks.add(title: "todo", working_dir: "/app")[:results].first["item"]

        result = with_acks.snooze([pane_id, item["id"]], for_duration: "2h", working_dir: "/app")

        expect(result[:results].map { |r| r["outcome"] }).to eq(%w[snoozed snoozed])
        expect(result[:results].last["item"]).to include("state" => "snoozed")
        expect(result[:exit_code]).to eq(0)
      end

      it "reads no derived source for stored ids only" do
        item = with_acks.add(title: "todo", working_dir: "/app")[:results].first["item"]

        with_acks.snooze([item["id"]], for_duration: "2h", working_dir: "/app")

        expect(derived_calls).to be_empty
      end

      it "still refuses a time that is not in the future before reading anything" do
        expect { with_acks.snooze([pane_id], until_time: "2026-10-16T11:00:00Z", working_dir: "/app") }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("invalid_inbox_item")
        }
        expect(derived_calls).to be_empty
      end
    end

    describe "#list" do
      it "warns, and shows every row, when the acks file cannot be read" do
        FileUtils.mkdir_p(File.dirname(acks_path))
        File.write(acks_path, "{nope")

        doc = listed

        expect(doc["items"].map { |i| i["id"] }).to include(pane_id)
        expect(doc["warnings"].map { |w| w["code"] }).to include("inbox_store_unreadable")
      end

      it "reads no acks without the flag" do
        with_acks.ack([pane_id], working_dir: "/app")
        output.truncate(0)
        output.rewind

        with_acks.list(working_dir: "/app", json: true)

        expect(JSON.parse(output.string)["items"]).to eq([])
      end
    end

    def with_derived_only
      described_class.new(config: config, project_detector: project_detector, project_catalog: project_catalog,
        session_ledger: session_ledger, store_factory: store_factory, env: env, input: input, derived: derived,
        clock: -> { now }, output: output, error_output: error_output)
    end
  end
end
