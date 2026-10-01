require "fileutils"

# Builds on-disk checkout layouts (a main checkout, linked worktrees,
# submodules) by writing the same `.git` files git itself writes, so specs can
# exercise the no-subprocess readers against real directory trees.
module FakeCheckouts
  def make_main_checkout(path)
    FileUtils.mkdir_p(File.join(path, ".git"))
    path
  end

  def make_linked_worktree(main, path, name = File.basename(path))
    gitdir = File.join(main, ".git", "worktrees", name)
    FileUtils.mkdir_p(gitdir)
    File.write(File.join(gitdir, "commondir"), "../..\n")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, ".git"), "gitdir: #{gitdir}\n")
    path
  end

  def make_submodule(superproject, path, name = File.basename(path))
    gitdir = File.join(superproject, ".git", "modules", name)
    FileUtils.mkdir_p(gitdir)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, ".git"), "gitdir: #{gitdir}\n")
    path
  end
end
