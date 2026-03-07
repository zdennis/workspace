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

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "workspace"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
