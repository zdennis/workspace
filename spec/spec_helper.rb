unless ENV["SKIP_SIMPLECOV"]
  require "simplecov"
  require "simplecov_json_formatter"

  SimpleCov.start do
    add_filter "/spec/"
    add_filter "/bin/"

    enable_coverage :branch

    formatter SimpleCov::Formatter::MultiFormatter.new([
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::JSONFormatter
    ])
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "workspace"
require "tmpdir"

# Codex's hooks are user-level, so a spec that installs them without injecting
# a home would otherwise write the real ~/.codex/hooks.json. Set before any
# spec file loads, and made fresh for each example so none sees another's.
ENV["CODEX_HOME"] = Dir.mktmpdir("workspace-spec-codex-home")

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.around do |example|
    Dir.mktmpdir("workspace-spec-codex-home") do |dir|
      ENV["CODEX_HOME"] = dir
      example.run
    end
  end
end
