require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "demo/calculator-acceptance", type: :system do
  acceptance = File.join(PROJECT_ROOT, "demo", "calculator-acceptance")
  reference = File.join(PROJECT_ROOT, "spec", "fixtures", "demo_calculator", "reference")
  stub = File.join(PROJECT_ROOT, "demo", "calculator")

  def run_group(file, root)
    Bundler.with_unbundled_env { Open3.capture3({"CALC_ROOT" => root}, RbConfig.ruby, file) }
  end

  groups = Dir.glob(File.join(acceptance, "group_*_test.rb")).sort

  it "has the seven groups" do
    expect(groups.map { |g| File.basename(g)[/group_(\d)/, 1] }).to eq(%w[1 2 3 4 5 6 7])
  end

  groups.each do |group|
    name = File.basename(group)

    it "#{name} passes against the reference calculator" do
      out, err, status = run_group(group, reference)
      expect(status).to be_success, "#{out}\n#{err}"
    end

    it "#{name} fails against the stub" do
      out, err, status = run_group(group, stub)
      expect(status).not_to be_success
      expect(out + err).to match(/Failure|Error:/)
      expect(out + err).not_to include("LoadError")
    end
  end
end
