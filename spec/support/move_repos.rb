require "open3"
require "tmpdir"
require "fileutils"
require "digest"

# Throwaway repositories for the checkout-move specs: a bare origin and a main
# checkout (`repo`, on `main`, pushed) holding a text file, a script, a binary
# and a `.gitignore` for `*.log`. Git reads no user or system config, so a
# person's hooks path, signing or stash settings never reach the specs.
module MoveRepos
  ENV_FOR_GIT = {
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_CONFIG_COUNT" => "3",
    "GIT_CONFIG_KEY_0" => "gc.auto", "GIT_CONFIG_VALUE_0" => "0",
    "GIT_CONFIG_KEY_1" => "maintenance.auto", "GIT_CONFIG_VALUE_1" => "false",
    "GIT_CONFIG_KEY_2" => "protocol.file.allow", "GIT_CONFIG_VALUE_2" => "always"
  }.freeze

  def self.included(base)
    base.around do |example|
      saved = ENV_FOR_GIT.keys.to_h { |k| [k, ENV[k]] }
      ENV_FOR_GIT.each { |k, v| ENV[k] = v }
      begin
        Dir.mktmpdir("move-spec") do |dir|
          @dir = File.realpath(dir)
          example.run
        end
      ensure
        saved.each { |k, v| ENV[k] = v }
      end
    end
    base.let(:remote) { File.join(@dir, "remote.git") }
    base.let(:repo) { File.join(@dir, "api") }
    base.before { build_repo }
  end

  def sh(*args, dir: repo)
    out, st = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless st.success?
    out
  end

  def sh_status(*args, dir: repo)
    out, st = Open3.capture2e("git", "-C", dir, *args)
    [out, st.success?]
  end

  def write(file, content, dir: repo)
    path = File.join(dir, file)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def commit_file(file, content, message, dir: repo)
    write(file, content, dir: dir)
    sh("add", file, dir: dir)
    sh("commit", "-q", "-m", message, dir: dir)
  end

  def rev(ref, dir: repo) = sh("rev-parse", ref, dir: dir).strip

  def build_repo
    sh("init", "-q", "--bare", "-b", "main", remote, dir: @dir)
    FileUtils.mkdir_p(repo)
    sh("init", "-q", "-b", "main")
    sh("config", "user.name", "t")
    sh("config", "user.email", "t@example.com")
    write("app.rb", "one\ntwo\nthree\n")
    write("run.sh", "echo hi\n")
    write("logo.bin", "\x89PNG\x00\x01\x02\xFF".b)
    write(".gitignore", "*.log\n")
    sh("add", ".")
    sh("commit", "-q", "-m", "init")
    sh("remote", "add", "origin", remote)
    sh("push", "-q", "-u", "origin", "main")
  end

  def install_hook(name, body, dir: repo)
    hooks = File.join(sh("rev-parse", "--git-common-dir", dir: dir).strip.then { |d| File.expand_path(d, dir) }, "hooks")
    FileUtils.mkdir_p(hooks)
    File.write(File.join(hooks, name), "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, File.join(hooks, name))
  end

  def stash_shas(dir: repo) = sh("stash", "list", "--format=%H", dir: dir).split

  def promote_refs(dir: repo) = sh("for-each-ref", "--format=%(refname) %(objectname)", "refs/workspace/", dir: dir).lines.map(&:strip)

  # Everything a person could lose in a checkout: every file's bytes, mode and
  # link target (the .git directory aside), the index entries, the staged and
  # unstaged diffs, the branch, the refs and the stash list.
  def fingerprint(dir = repo, skip: [".worktrees"])
    files = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.filter_map do |rel|
      next if rel == ".git" || rel.start_with?(".git/") || rel.end_with?("/.") || rel == "."
      next if skip.any? { |s| rel == s || rel.start_with?("#{s}/") }
      full = File.join(dir, rel)
      stat = File.lstat(full)
      kind = if stat.symlink? then "link:#{File.readlink(full)}"
      elsif stat.directory? then "dir"
      else Digest::SHA256.file(full).hexdigest
      end
      [rel, format("%o", stat.mode), kind]
    end
    {files: files, index: sh("ls-files", "-s", dir: dir),
     staged: sh("diff", "--cached", "--binary", dir: dir), unstaged: sh("diff", "--binary", dir: dir),
     head: sh("symbolic-ref", "-q", "HEAD", dir: dir).strip,
     refs: sh("for-each-ref", "--format=%(refname) %(objectname)", dir: dir), stash: sh("stash", "list", "--format=%H %gs", dir: dir)}
  end

  # What moves with the work, as seen from one checkout: the staged and
  # unstaged diffs, the untracked files and the bytes and mode of each.
  def work(dir)
    untracked = sh("ls-files", "-o", "--exclude-standard", "-z", dir: dir).split("\0").sort
    {staged: sh("diff", "--cached", "--binary", dir: dir), unstaged: sh("diff", "--binary", dir: dir),
     untracked: untracked.to_h { |f| [f, Digest::SHA256.file(File.join(dir, f)).hexdigest] },
     status: sh("status", "--porcelain=v1", "--untracked-files=all", dir: dir)}
  end
end
