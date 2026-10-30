require "simplecov_json_formatter"

SimpleCov.configure do
  add_filter "/spec/"
  add_filter "/bin/"

  enable_coverage :branch

  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::JSONFormatter
  ])
end
