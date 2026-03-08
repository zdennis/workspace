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

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.before(:suite) do
    Workspace::CLI.exit_handler = FakeExitHandler
  end

  config.after(:suite) do
    Workspace::CLI.exit_handler = Kernel
  end
end
