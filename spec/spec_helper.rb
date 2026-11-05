# Under parallel_tests (script/parallel-spec) each process gets its own short
# HOME and XDG directories, so processes do not share state. The path stays
# short because socket paths have a 100-byte limit. Must run before anything
# reads HOME. A git template dir holding only an empty hooks/ makes
# `git init` write no info/exclude, as with a developer HOME that sets
# init.templateDir. Absent TEST_ENV_NUMBER (the serial default), nothing
# changes. parallel_tests sets TEST_ENV_NUMBER to "" for the first process,
# so test for the key, not its value.
if ENV.key?("TEST_ENV_NUMBER")
  require "fileutils"

  parallel_home = File.join(File.realpath("/tmp"), "wsh#{ENV["TEST_ENV_NUMBER"]}-#{Process.pid}")
  FileUtils.mkdir_p(parallel_home)
  git_template = File.join(parallel_home, "git-template")
  FileUtils.mkdir_p(File.join(git_template, "hooks"))
  File.write(File.join(parallel_home, ".gitconfig"), "[user]\n\tname = Spec\n\temail = spec@example.com\n[init]\n\ttemplateDir = #{git_template}\n")
  ENV["HOME"] = parallel_home
  ENV["XDG_CONFIG_HOME"] = File.join(parallel_home, ".config")
  ENV["XDG_STATE_HOME"] = File.join(parallel_home, ".local", "state")
  ENV["XDG_DATA_HOME"] = File.join(parallel_home, ".local", "share")
  ENV["XDG_CACHE_HOME"] = File.join(parallel_home, ".cache")
  at_exit { FileUtils.rm_rf(parallel_home) }
end

unless ENV["SKIP_SIMPLECOV"]
  require "simplecov"

  SimpleCov.start do
    if ENV.key?("TEST_ENV_NUMBER")
      command_name "rspec-#{ENV["TEST_ENV_NUMBER"]}"
      merge_timeout 3600
    end
  end
end

PROJECT_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(PROJECT_ROOT, "lib")
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

  # The directory a spec sits in is its tier; a type: written on a group wins.
  %i[unit integration system].each do |tier|
    config.define_derived_metadata(file_path: %r{/spec/#{tier}/}) { |meta| meta[:type] ||= tier }
  end

  SpawnGuard.install
  config.around { |example| SpawnGuard.guard(example) }

  config.around do |example|
    Dir.mktmpdir("workspace-spec-codex-home") do |dir|
      ENV["CODEX_HOME"] = dir
      example.run
    end
  end
end
