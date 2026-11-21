require "spec_helper"

RSpec.describe Workspace::PermissionPolicyConfig do
  let(:rules_key) { Workspace::ConfigSchema.key("agent.permissions.rules") }
  let(:default_key) { Workspace::ConfigSchema.key("agent.permissions.default") }
  let(:logger) { instance_double(Workspace::Logger, debug: nil) }
  let(:run_id) { nil }
  let(:run) { nil }
  let(:bound_run) { instance_double(Workspace::BoundRun, run_id_strict: run_id) }
  let(:run_store) { instance_double(Workspace::WorkflowRunStore) }
  # hits by key name, highest layer first; turned into each layer's raw file data
  let(:hits) { {} }
  let(:raw_data) { nil }
  let(:data_by_layer) do
    next raw_data if raw_data
    Workspace::ConfigLayering::LAYERED_ORDER.each_with_object({}) do |layer, data|
      found = hits.flat_map { |name, list| list.select { |h| h.layer == layer }.map { |h| [name.delete_prefix("agent.permissions."), h.value] } }
      data[layer] = found.empty? ? {} : {"agent" => {"permissions" => found.to_h}}
    end.reject { |_, content| content.empty? }
  end
  let(:view) { instance_double(Workspace::ConfigResolver::View, data_by_layer: data_by_layer) }
  let(:resolver) { instance_double(Workspace::ConfigResolver, view: view) }

  subject(:config) { described_class.new(config_resolver: resolver, bound_run: bound_run, run_store: run_store, logger: logger) }

  def hit(layer, value) = Workspace::ConfigLayering::Hit.new(layer: layer, value: value)

  def rule(tool, action, pattern = nil)
    {"tool" => tool, "action" => action}.merge(pattern ? {"pattern" => pattern} : {})
  end

  def policy = config.policy(workspace: "app.worktree-x", project: "app")

  def configured? = config.configured?(workspace: "app.worktree-x", project: "app")

  def decide(tool = "Bash", command = "ls") = policy.decide(tool_name: tool, tool_input: {"command" => command}, cwd: "/")

  def live_run(permissions: nil, state: "running")
    definition = permissions ? {"permissions" => permissions} : {}
    instance_double(Workspace::WorkflowRun, state: state, definition: definition)
  end

  it "asks the resolver for the workspace and project" do
    hits["agent.permissions.default"] = [hit("project", "allow")]
    policy

    expect(resolver).to have_received(:view).with(workspace: "app.worktree-x", project: "app", strict_global: true)
  end

  describe "#policy" do
    it "is nil when no layer sets either key and there is no run" do
      expect(policy).to be_nil
    end

    it "concatenates rules from every layer, so a global deny holds against a project allow" do
      hits["agent.permissions.rules"] = [hit("project", [rule("Bash", "allow")]), hit("global", [rule("Bash", "deny", "rm *")])]

      expect(decide("Bash", "rm x")).to eq(action: "deny", rule: "global:rules[0]")
      expect(decide("Bash", "ls")).to eq(action: "allow", rule: "project:rules[0]")
    end

    it "takes the most restrictive default across layers" do
      hits["agent.permissions.default"] = [hit("worktree", "allow"), hit("project", "deny"), hit("global", "ask")]

      expect(decide("Edit")).to eq(action: "deny", rule: "project:default")
    end

    it "builds a policy from a default alone" do
      hits["agent.permissions.default"] = [hit("global", "allow")]

      expect(decide("Edit")).to eq(action: "allow", rule: "global:default")
    end

    it "builds a policy from rules alone, asking when none match" do
      hits["agent.permissions.rules"] = [hit("project", [rule("Read", "allow")])]

      expect(decide("Edit")).to eq(action: "ask", rule: "default")
    end

    it "treats an empty rules list as set" do
      hits["agent.permissions.rules"] = [hit("project", [])]

      expect(policy).to be_a(Workspace::PermissionPolicy)
    end

    describe "the bound run's rules" do
      let(:run_id) { "wr_1" }

      it "adds a live run's permissions as the run layer" do
        allow(run_store).to receive(:run).with("wr_1").and_return(live_run(permissions: [rule("Bash", "ask", "git push*")]))
        hits["agent.permissions.default"] = [hit("project", "allow")]

        expect(decide("Bash", "git push")).to eq(action: "ask", rule: "run:permissions[0]")
        expect(decide("Bash", "ls")).to eq(action: "allow", rule: "project:default")
      end

      it "decides from a live run's rules when no config layer sets a key" do
        allow(run_store).to receive(:run).and_return(live_run(permissions: [rule("Bash", "deny", "rm *")]))

        expect(decide("Bash", "rm x")).to eq(action: "deny", rule: "run:permissions[0]")
      end

      it "ignores a finished run" do
        %w[completed failed cancelled].each do |state|
          allow(run_store).to receive(:run).and_return(live_run(permissions: [rule("Bash", "deny")], state: state))

          expect(policy).to be_nil
        end
      end

      it "is nil for a live run with no permissions and no config" do
        allow(run_store).to receive(:run).and_return(live_run)

        expect(policy).to be_nil
      end

      it "is nil when the run can't be read, even with config set" do
        hits["agent.permissions.default"] = [hit("project", "allow")]
        allow(run_store).to receive(:run).and_raise(Workspace::Error.new("no such run", code: "unknown_run"))

        expect(policy).to be_nil
      end

      it "is nil when the stored permissions are malformed" do
        hits["agent.permissions.default"] = [hit("project", "allow")]
        allow(run_store).to receive(:run).and_return(live_run(permissions: [{"tool" => "Bash", "action" => "allow"}]))

        expect(policy).to be_nil
      end
    end

    it "does not read the run for an unbound pane" do
      hits["agent.permissions.default"] = [hit("project", "allow")]
      allow(run_store).to receive(:run)

      policy

      expect(run_store).not_to have_received(:run)
    end

    describe "errors give nil" do
      it "for a global file that can't be parsed, whatever the project says" do
        hits["agent.permissions.default"] = [hit("project", "allow")]
        allow(view).to receive(:data_by_layer).and_raise(Workspace::ConfigParseError.new("/g.yml", "bad"))

        expect(policy).to be_nil
      end

      it "for an agent node that is not a mapping" do
        raw = {"global" => {"agent" => ["permissions"]}, "project" => {"agent" => {"permissions" => {"default" => "allow"}}}}
        allow(view).to receive(:data_by_layer).and_return(raw)

        expect(policy).to be_nil
        expect(configured?).to be(true)
      end

      it "for a permissions node that is a scalar" do
        allow(view).to receive(:data_by_layer).and_return("project" => {"agent" => {"permissions" => "deny"}})

        expect(policy).to be_nil
        expect(configured?).to be(true)
      end

      it "for rules placed directly under permissions" do
        allow(view).to receive(:data_by_layer).and_return("project" => {"agent" => {"permissions" => [{"tool" => "Bash", "action" => "deny"}]}})

        expect(policy).to be_nil
        expect(configured?).to be(true)
      end

      it "for a flat dotted key at the top level, beside a valid layer" do
        allow(view).to receive(:data_by_layer).and_return(
          "project" => {"agent.permissions.rules" => [{"tool" => "Bash", "action" => "deny"}]},
          "global" => {"agent" => {"permissions" => {"default" => "allow"}}}
        )

        expect(policy).to be_nil
        expect(configured?).to be(true)
      end

      it "for a misspelled key under permissions, beside a looser valid layer" do
        %w[rule defualt Rules].each do |typo|
          allow(view).to receive(:data_by_layer).and_return(
            "project" => {"agent" => {"permissions" => {"default" => "allow"}}},
            "global" => {"agent" => {"permissions" => {typo => "deny"}}}
          )

          expect(policy).to be_nil
          expect(configured?).to be(true)
        end
      end

      it "reads an explicit null rules or default as absent" do
        allow(view).to receive(:data_by_layer).and_return("project" => {"agent" => {"permissions" => {"rules" => nil, "default" => nil}}})

        expect(policy).to be_nil
        expect(configured?).to be(false)
      end

      it "for a flat dotted key under agent" do
        allow(view).to receive(:data_by_layer).and_return("project" => {"agent" => {"permissions.default" => "allow"}})

        expect(policy).to be_nil
        expect(configured?).to be(true)
      end

      it "treats an empty agent or permissions node as unset" do
        allow(view).to receive(:data_by_layer).and_return("project" => {"agent" => nil}, "global" => {"agent" => {"permissions" => nil}})

        expect(policy).to be_nil
        expect(configured?).to be(false)
      end

      it "when the binding can't be read, even with config set" do
        hits["agent.permissions.default"] = [hit("project", "allow")]
        allow(bound_run).to receive(:run_id_strict).and_raise(Workspace::Error.new("tmux gone", code: "tmux_failed"))

        expect(policy).to be_nil
      end

      it "for a config file that can't be parsed" do
        allow(view).to receive(:data_by_layer).and_raise(Workspace::ConfigParseError.new("/x.yml", "bad"))

        expect(policy).to be_nil
        expect(logger).to have_received(:debug)
      end

      it "for a rules value that is not a list" do
        hits["agent.permissions.rules"] = [hit("project", "allow everything")]

        expect(policy).to be_nil
      end

      it "for an invalid rule" do
        hits["agent.permissions.rules"] = [hit("project", [{"tool" => "Bash", "action" => "maybe"}])]

        expect(policy).to be_nil
      end

      it "for a broken global rules value, not an empty list, even beside a valid project value" do
        hits["agent.permissions.rules"] = [hit("project", [rule("Bash", "deny")]), hit("global", {"tool" => "Bash"})]

        expect(policy).to be_nil
      end

      it "for an invalid default" do
        hits["agent.permissions.default"] = [hit("global", "yes")]

        expect(policy).to be_nil
      end

      it "when the resolver raises" do
        allow(resolver).to receive(:view).and_raise(KeyError, "undeclared")

        expect(policy).to be_nil
      end
    end
  end

  describe "#configured?" do
    it "is false when no key is set anywhere" do
      expect(configured?).to be(false)
    end

    it "is true for a default in any layer" do
      hits["agent.permissions.default"] = [hit("global", "allow")]

      expect(configured?).to be(true)
    end

    it "is true for a rules value that does not parse" do
      hits["agent.permissions.rules"] = [hit("project", "not a list")]

      expect(configured?).to be(true)
      expect(policy).to be_nil
    end

    it "is true for an invalid default" do
      hits["agent.permissions.default"] = [hit("global", "yes")]

      expect(configured?).to be(true)
    end

    context "with a bound run" do
      let(:run_id) { "wr_1" }

      it "is true when the live run has permissions rules, parsed or not" do
        allow(run_store).to receive(:run).and_return(live_run(permissions: "junk"))

        expect(configured?).to be(true)
      end

      it "is false for a finished run" do
        allow(run_store).to receive(:run).and_return(live_run(permissions: [rule("Bash", "deny")], state: "completed"))

        expect(configured?).to be(false)
      end

      it "is false for a live run with no permissions or an empty list" do
        allow(run_store).to receive(:run).and_return(live_run(permissions: []))

        expect(configured?).to be(false)
      end

      it "is still true from config when the run can't be read" do
        hits["agent.permissions.default"] = [hit("project", "ask")]
        allow(run_store).to receive(:run).and_raise(Workspace::Error.new("no such run", code: "unknown_run"))

        expect(configured?).to be(true)
      end

      it "is false, logged, when presence can't be read from the run" do
        allow(run_store).to receive(:run).and_raise(Workspace::Error.new("no such run", code: "unknown_run"))

        expect(configured?).to be(false)
        expect(logger).to have_received(:debug)
      end
    end

    it "is true when a config file can't be parsed, the global one included" do
      allow(view).to receive(:data_by_layer).and_raise(Workspace::ConfigParseError.new("/x.yml", "bad"))

      expect(configured?).to be(true)
    end

    it "is false, logged, on an error that stops presence being read" do
      allow(view).to receive(:data_by_layer).and_raise(IOError, "gone")

      expect(configured?).to be(false)
      expect(logger).to have_received(:debug)
    end
  end
end
