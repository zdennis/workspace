require "spec_helper"
require File.join(PROJECT_ROOT, "script/demo_calculator/eval_checks")

RSpec.describe DemoCalculator::EvalChecks, ".clean_ruby_env" do
  it "drops the bundle's gem settings and restores the ones `bundle exec` replaced" do
    env = {"GEM_HOME" => "/app/vendor/bundle", "GEM_PATH" => "/app/vendor/bundle",
           "BUNDLER_ORIG_GEM_HOME" => "/home/me/.gem", "BUNDLER_ORIG_GEM_PATH" => "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL"}
    expect(described_class.clean_ruby_env(env)).to include(
      "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil, "RUBYGEMS_GEMDEPS" => nil,
      "GEM_HOME" => "/home/me/.gem", "GEM_PATH" => nil
    )
  end

  it "keeps gem settings as they are when no bundle changed them" do
    expect(described_class.clean_ruby_env({"GEM_HOME" => "/h"})).to include("GEM_HOME" => "/h", "GEM_PATH" => nil)
  end
end
