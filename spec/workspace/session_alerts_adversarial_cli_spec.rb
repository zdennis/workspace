require "spec_helper"
require "stringio"
require "tmpdir"
require "socket"

# Adversarial probes for T2 ("waiting" session state + alerts: commits
# 4cbcb9e, 365f8e5, 756117c). Each example is a confirmed CLI/UX defect, not
# a spec bug — see the ID prefix in the description for cross-reference with
# the review report. Concurrency and lower-level session_monitor/notifier
# behavior are covered by the sibling
# session_alerts_adversarial_concurrency_spec.rb.
RSpec.describe "session alerts CLI/UX" do
  # SU1: `workspace sessions --help` never says that `waiting` is only
  # detected for Claude Code (the STATE column description talks about "the
  # agent" generically, and doesn't mention that Codex/OpenCode/Pi panes
  # never leave working/idle). The Claude-only limitation is documented only
  # in docs/autonomous-development.md, a doc a `--help` reader is unlikely to
  # find. A user monitoring a non-Claude agent has no way to learn from
  # `sessions --help` why their pane never shows `waiting`.
  describe "SU1: sessions --help omits the Claude-Code-only scope of `waiting`" do
    it "mentions that waiting detection is Claude Code only" do
      output = StringIO.new
      error_output = StringIO.new
      cli = Workspace.build_cli(output: output, error_output: error_output)

      real_stdout = StringIO.new
      $stdout = real_stdout
      begin
        expect { cli.run(["sessions", "--help"]) }.to raise_error(SystemExit)
      ensure
        $stdout = STDOUT
      end

      expect(real_stdout.string).to match(/claude code only|only.*claude code/i)
    end
  end

  # SU2: `workspace config set alerts.notify` / `alerts.idle_after` print the
  # same generic "Set <key> = <value> for '<project>'." confirmation as every
  # other config key, even though docs/README.sessions.md and
  # docs/README.config.md both state that these two keys only take effect
  # the next time the session-monitor daemon starts. Nothing in the command's
  # own output tells the operator their change is inert until they run
  # `workspace agent <project> --force` (or relaunch) — a person who only
  # reads `workspace config set --help` or the confirmation line has no way
  # to discover this from the CLI itself.
  describe "SU2: `config set alerts.*` gives no restart-required notice" do
    def build_command(output:)
      dir = Dir.mktmpdir("ws-config-su2")
      fake_path_config = Struct.new(:workspace_config_dir).new(dir)
      project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
      lineage = Workspace::WorkspaceLineage.new
      file_backup = Workspace::FileBackup.new(output: output)
      Workspace::Commands::Config.new(project_settings: project_settings, lineage: lineage,
        file_backup: file_backup, output: output)
    end

    it "warns that alerts.notify only takes effect after a daemon restart" do
      output = StringIO.new
      command = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-su2-project")

      command.set("alerts.notify", 'say "$WORKSPACE_ALERT_TEXT"', cwd: project_dir)

      expect(output.string).to match(/restart|takes effect.*next.*start|agent.*--force/i)
    end

    it "warns that alerts.idle_after only takes effect after a daemon restart" do
      output = StringIO.new
      command = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-su2-project2")

      command.set("alerts.idle_after", "15m", cwd: project_dir)

      expect(output.string).to match(/restart|takes effect.*next.*start|agent.*--force/i)
    end
  end

  # SU3: `workspace sessions` strips control characters from an agent's
  # waiting message before rendering it in the table
  # (lib/workspace/commands/sessions.rb#render_waiting uses
  # `gsub(/[[:space:][:cntrl:]]+/, " ")`), but `--json` hands the same
  # `waiting_message` straight through, control characters and all. Since
  # docs/README.sessions.md tells operators to wire `alerts.notify` (and, by
  # the same daemon code path, any `--json` consumer) straight to the
  # message via unquoted-looking but shell-quoted environment variables
  # (`say "$WORKSPACE_ALERT_TEXT"`), an agent-supplied message containing
  # ANSI/terminal control sequences reaches a terminal, log, or `say`
  # invocation unsanitized through --json/env, while the interactive table
  # view of the very same field is sanitized. That is an inconsistent
  # (and for --json, absent) sanitization boundary for attacker- or
  # bug-controlled agent output.
  describe "SU3: --json waiting_message is not sanitized the way the table view is" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:control_message) { "needs your \e[31mpermission\e[0m to use Bash\x07\x01" }

    let(:payload) do
      {
        "workspace" => "proj",
        "updated_at" => "2026-09-26T12:00:00Z",
        "panes" => [
          {"pane_id" => "%1", "index" => 0, "kind" => "claude", "label" => "Claude Code",
           "state" => "waiting", "idle_seconds" => 0, "waiting_message" => control_message,
           "agents" => []}
        ]
      }
    end

    after { FileUtils.remove_entry(tmpdir) }

    def with_daemon(socket_path, reply)
      server = UNIXServer.new(socket_path)
      listener = Thread.new do
        client = server.accept
        client.gets
        client.puts(JSON.generate(reply))
        client.close
      end
      yield
      listener.join(2)
    ensure
      server&.close
    end

    it "strips control characters from the table row but leaves them in --json" do
      table_output = StringIO.new
      json_output = StringIO.new
      table_socket = File.join(tmpdir, "table.sock")
      json_socket = File.join(tmpdir, "json.sock")

      table_command = Workspace::Commands::Sessions.new(
        config: instance_double(Workspace::Config, agent_socket_path: table_socket, ask_state_path: File.join(tmpdir, "table-asks.json")),
        output: table_output, error_output: StringIO.new
      )
      with_daemon(table_socket, payload) { table_command.call(name: "proj") }
      expect(table_output.string).not_to match(/\e\[31m/)

      json_command = Workspace::Commands::Sessions.new(
        config: instance_double(Workspace::Config, agent_socket_path: json_socket, ask_state_path: File.join(tmpdir, "json-asks.json")),
        output: json_output, error_output: StringIO.new
      )
      with_daemon(json_socket, payload) { json_command.call(name: "proj", json: true) }
      parsed = JSON.parse(json_output.string)
      json_message = parsed["panes"].first["waiting_message"]

      expect(json_message).not_to match(/\e\[31m/), "expected --json waiting_message to be sanitized like the table view, but it carried the raw escape sequence through unchanged"
    end
  end
end
