require "tmpdir"
require "fileutils"
require "open3"

# A temp world for the skills specs: a fake HOME, a fake checkout that holds the
# four skills (with bin/workspace and a .git directory) and a state directory.
# Nothing outside the temp directory is read or written.
module SkillsFixture
  NAMES = %w[workspace workspace-agent-run workspace-inbox workspace-lifecycle].freeze

  def self.included(base)
    base.around do |example|
      Dir.mktmpdir("skills-spec") do |dir|
        @tmp = File.realpath(dir)
        example.run
      end
    end
    base.let(:home) { File.join(@tmp, "home") }
    base.let(:checkout) { File.join(@tmp, "checkout") }
    base.let(:state_dir) { File.join(@tmp, "state") }
    base.let(:root) { File.join(checkout, "lib", "skills") }
    base.before do
      FileUtils.mkdir_p(home)
      build_checkout(checkout)
    end
  end

  def build_checkout(dir)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "workspace"), "#!/usr/bin/env ruby\n")
    FileUtils.mkdir_p(File.join(dir, ".git"))
    NAMES.each do |name|
      FileUtils.mkdir_p(File.join(dir, "lib", "skills", name))
      File.write(File.join(dir, "lib", "skills", name, "SKILL.md"), "---\nname: #{name}\n---\n")
    end
    FileUtils.mkdir_p(File.join(dir, "lib", "skills", "workspace", "references"))
    File.write(File.join(dir, "lib", "skills", "workspace", "references", "machine-contract.md"), "contract\n")
  end

  def git_in(dir, *args)
    out, status = Open3.capture2e({"GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL}, "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", *args)
    raise out unless status.success?
  end
end
