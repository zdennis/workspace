require "tmpdir"
require "socket"
require "stringio"

# Adversarial CLI/UX spec for batch 4 (locks + sessions). See
# lib/workspace/commands/sessions.rb for the documented contract this
# exercises.
RSpec.describe "batch 4 adversarial CLI/UX findings" do
  describe "BU1: `sessions --json --watch` does not honor the documented JSON error contract" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:config) { instance_double(Workspace::Config) }
    let(:socket_path) { File.join(tmpdir, "agent.sock") }
    let(:output) { StringIO.new }
    let(:error_output) { StringIO.new }
    let(:sleeper) { ->(_seconds) { raise Interrupt } }

    subject(:command) do
      Workspace::Commands::Sessions.new(config: config, output: output, error_output: error_output, sleeper: sleeper)
    end

    before do
      allow(config).to receive(:agent_socket_path).with("proj").and_return(socket_path)
      FileUtils.rm_f(socket_path)
    end

    after { FileUtils.remove_entry(tmpdir) }

    # `call`'s own @return doc says: "if `--json` was given and no agent
    # daemon answered (the error is then written to stdout as
    # `{"schema_version":1,"error":...}` instead of being raised, matching
    # `lock status --json` and `dev status --json`)". That contract is only
    # honored on the non-watch path: `watch: true` runs the fetch inside a
    # bare `loop`, and only `Interrupt` is rescued around it, so a
    # Workspace::Error from `fetch` propagates instead of being turned into
    # the documented JSON-on-stdout, exit-1 shape.
    it "writes the schema_version error JSON to stdout instead of raising, per its own documented contract" do
      expect {
        command.call(name: "proj", json: true, watch: true)
      }.not_to raise_error

      parsed = JSON.parse(output.string)
      expect(parsed["schema_version"]).to eq(1)
      expect(parsed["error"]).to include("No agent daemon for 'proj'")
    end
  end
end
