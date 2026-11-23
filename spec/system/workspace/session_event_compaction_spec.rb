require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"

# The fast session-event entry loads only its own closure and the EVENT_LOG_FILES on a guard's deny. The
# event log rescues a failed threshold read and then never compacts, so a missing require would show
# nowhere but here: a log already past `event_log.compact_threshold` must compact when the deny appends.
RSpec.describe "workspace session-event fast entry's event log compaction" do
  let(:entry_script) do
    <<~RUBY
      require "workspace/cli/session_event_entry"
      exit Workspace::CLI::SessionEventEntry.run(ARGV, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV)
    RUBY
  end

  around do |example|
    Dir.mktmpdir("wsk", "/tmp") do |dir|
      @home = File.realpath(dir)
      @work = File.join(@home, "work")
      @bin = File.join(@home, "bin")
      FileUtils.mkdir_p([@work, @bin])
      File.write(File.join(@bin, "tmux"), <<~'SH')
        #!/bin/sh
        for a in "$@"; do last="$a"; done
        case " $* " in
          *" display-message "*)
            case "$last" in
              '#{session_name}') echo proj ;;
              '#{pid}') echo 4242 ;;
              '#{session_name}:#{window_index}.#{pane_index}') echo proj:0.0 ;;
            esac ;;
          *" show-option "*) exit 1 ;;
        esac
        exit 0
      SH
      File.chmod(0o755, File.join(@bin, "tmux"))
      example.run
    end
  end

  def log_path = File.join(@home, ".workspace-events.jsonl")

  def write_config(value)
    FileUtils.mkdir_p(File.join(@home, ".config", "workspace"))
    File.write(File.join(@home, ".config", "workspace", "config.yml"), "event_log:\n  compact_threshold: #{value}\n")
  end

  def fill_log
    line = JSON.generate("timestamp" => "2026-01-01T00:00:00.000Z", "type" => "state_set", "project" => "old", "data" => {"pad" => "x" * 200}) + "\n"
    File.write(log_path, line * 100)
  end

  def review_deny
    FileUtils.mkdir_p(File.join(@home, "state", "workspace"))
    File.write(File.join(@home, "state", "workspace", "bindings.json"), JSON.generate("%1" => {"session" => "proj", "server_pid" => "4242", "workspace" => "proj", "pane_id" => "%1",
                                                                                               "kind" => "run", "id" => "wr_1", "role" => "reviewer", "step" => "fix", "attempt" => 1, "round" => 1, "artifacts" => File.join(@home, "art")}))
    env = {"PATH" => "#{@bin}:#{ENV.fetch("PATH")}", "HOME" => @home, "TMUX_PANE" => "%1", "WORKSPACE_DEBUG" => "1",
           "XDG_STATE_HOME" => File.join(@home, "state"), "XDG_CONFIG_HOME" => File.join(@home, ".config"),
           "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"], "BUNDLE_PATH" => ENV["BUNDLE_PATH"]}.compact
    payload = {"hook_event_name" => "PreToolUse", "tool_name" => "Write", "cwd" => @work, "tool_input" => {"file_path" => File.join(@work, "x.rb")}}
    Open3.capture3(env, RbConfig.ruby, "-I", File.join(PROJECT_ROOT, "lib"), "-e", entry_script, "--", "session-event",
      stdin_data: JSON.generate(payload), unsetenv_others: true, chdir: @work)
  end

  it "compacts the log on the append that passes event_log.compact_threshold" do
    write_config("16KB")
    fill_log

    _out, err, status = review_deny

    expect(status.exitstatus).to eq(2)
    expect(err).not_to match(/LoadError|NameError|uninitialized constant/)
    expect(File.exist?("#{log_path}.1")).to be(true)
  end

  it "leaves the log whole when event_log.compact_threshold is off" do
    write_config("off")
    fill_log

    _out, _err, status = review_deny

    expect(status.exitstatus).to eq(2)
    expect(File.exist?("#{log_path}.1")).to be(false)
    expect(File.readlines(log_path).size).to eq(101)
  end
end
