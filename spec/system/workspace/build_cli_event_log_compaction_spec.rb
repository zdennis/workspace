require "spec_helper"
require "stringio"
require "tmpdir"

# build_cli resolves the working directory's project through git, so this runs in the system tier.
RSpec.describe "build_cli's event log compaction" do
  around do |example|
    Dir.mktmpdir("wsb", "/tmp") do |dir|
      @home = File.realpath(dir)
      saved = %w[HOME XDG_CONFIG_HOME XDG_STATE_HOME].to_h { |key| [key, ENV[key]] }
      ENV["HOME"] = @home
      ENV["XDG_CONFIG_HOME"] = File.join(@home, ".config")
      ENV["XDG_STATE_HOME"] = File.join(@home, "state")
      example.run
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end

  def built_event_log(threshold)
    FileUtils.mkdir_p(File.join(@home, ".config", "workspace"))
    File.write(File.join(@home, ".config", "workspace", "config.yml"), "event_log:\n  compact_threshold: #{threshold}\n")
    given = nil
    allow(Workspace::EventLog).to receive(:new) do |**kwargs|
      given = kwargs
      double("event_log").as_null_object
    end
    Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, tmux: FakeTmux.new)
    RSpec::Mocks.space.proxy_for(Workspace::EventLog).reset
    Workspace::EventLog.new(**given)
  end

  def append_past_16kb(event_log)
    150.times { |i| event_log.append(type: "state_set", project: "p#{i}", data: {"pad" => "x" * 200}) }
  end

  it "compacts the log past a configured event_log.compact_threshold" do
    event_log = built_event_log("16KB")

    append_past_16kb(event_log)

    expect(File.exist?("#{Workspace::Config.new.event_log_file}.1")).to be(true)
  end

  it "never compacts the log when event_log.compact_threshold is off" do
    event_log = built_event_log("off")

    append_past_16kb(event_log)

    expect(File.exist?("#{Workspace::Config.new.event_log_file}.1")).to be(false)
  end
end
