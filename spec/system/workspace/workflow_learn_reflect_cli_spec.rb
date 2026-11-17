require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe "workspace workflow learn reflect through bin/workspace" do
  def workspace(*args)
    Dir.mktmpdir("wf-learn-cli") do |home|
      env = {"HOME" => File.realpath(home), "PATH" => ENV.fetch("PATH"), "XDG_CONFIG_HOME" => nil, "XDG_STATE_HOME" => nil, "XDG_DATA_HOME" => nil}
      out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(PROJECT_ROOT, "bin", "workspace"), *args)
      return [out, err, status]
    end
  end

  it "gives unknown_run in the JSON envelope and exits 1" do
    out, _err, status = workspace("workflow", "learn", "reflect", "wr_nope", "--json")

    expect(JSON.parse(out)).to include("ok" => false, "code" => "unknown_run")
    expect(status.exitstatus).to eq(1)
  end

  it "prints the usage error and exits 1 for a missing verb" do
    _out, err, status = workspace("workflow", "learn")

    expect(err).to include("workflow learn needs a verb: reflect")
    expect(status.exitstatus).to eq(1)
  end

  it "shows the page for `learn --help`" do
    out, _err, status = workspace("workflow", "learn", "--help")

    expect(out).to start_with("Usage: workspace workflow learn reflect RUN [--agent KIND] [--json]")
    expect(status.exitstatus).to eq(0)
  end
end
