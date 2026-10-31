require "tmpdir"
require "fileutils"

# Builds a fixture repository set once per rspec process and copies it into
# each example's directory, so the git calls that make it run once, not per
# example. Each example gets its own copy (specs change hooks and config).
module RepoTemplate
  # The files git writes an absolute path into: a checkout's config, a linked
  # worktree's back-link, and the `.git` file of a linked worktree.
  PATH_FILES = %w[**/.git/config **/.git/worktrees/*/gitdir **/.git].freeze

  def self.root
    @root ||= File.realpath(Dir.mktmpdir("repo-template")).tap do |path|
      at_exit { FileUtils.remove_entry(path) if File.exist?(path) }
    end
  end

  # Copies the set named `key` into `to`, building it first with the block
  # (given its directory, `root`). The key must identify the build: the block
  # is ignored once the key has been built. The copy keeps mtimes, so git's
  # index still matches the files.
  def self.copy(key, to:)
    @built ||= {}
    template = @built[key] ||= build(key) { |root| yield root }
    FileUtils.cp_r("#{template}/.", to, preserve: true)
    rewrite_paths(template, to)
  end

  def self.build(key)
    root = File.join(self.root, key.to_s)
    FileUtils.mkdir_p(root)
    yield root
    root
  rescue Exception # standard:disable Lint/RescueException
    FileUtils.rm_rf(root)
    raise
  end

  # Replaces the template's path with `to` in the files that hold it, then
  # raises if any scanned file still names the template.
  def self.rewrite_paths(template, to)
    files = Dir.glob(PATH_FILES, File::FNM_DOTMATCH, base: to).map { |rel| File.join(to, rel) }.select { |f| File.file?(f) }
    files.each do |file|
      text = File.binread(file)
      File.binwrite(file, text.gsub(template, to)) if text.include?(template)
    end
    stale = files.select { |file| File.binread(file).include?(template) }
    raise "repo template path still in #{stale.join(", ")}" unless stale.empty?
  end
end
