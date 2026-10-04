require "fileutils"
require "time"

module Workspace
  # The files of one library scope: a directory holding `<kind>/<name>.md`
  # entries and `skill/<name>/` directories, each a copy or a symlink to its
  # source. There is no index; the directory is the store. Writes go through
  # a temp file or directory and a rename, so a reader never sees a
  # half-written entry.
  class LibraryStore
    # The kinds an entry can have. An agent is a Claude Code subagent file; a
    # play is a document an agent reads and follows; a prompt is short text
    # sent as typed; a skill is a directory holding `SKILL.md`.
    KINDS = %w[agent play prompt skill].freeze

    # Kinds stored as a directory, and the file inside it that holds the body.
    DIRECTORY_KINDS = {"skill" => "SKILL.md"}.freeze

    # Entry names: lowercase letters, digits and hyphens.
    NAME = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

    # @param dir [String] the scope's directory
    # @param scope [String] "global" or "project"
    # @param project [String, nil] the project name for a project scope
    def initialize(dir:, scope:, project: nil)
      @dir = dir
      @scope = scope
      @project = project
    end

    # @return [String] the scope's directory
    attr_reader :dir

    # @return [String] "global" or "project"
    attr_reader :scope

    # @return [String, nil]
    attr_reader :project

    # @param kind [String]
    # @param name [String]
    # @return [String] where the entry lives, whether or not it exists: the
    #   file, or a skill's directory
    def path_for(kind, name)
      DIRECTORY_KINDS.key?(kind) ? File.join(@dir, kind, name) : File.join(@dir, kind, "#{name}.md")
    end

    # @param kind [String]
    # @param name [String]
    # @return [String] the file holding the entry's body: the entry itself, or a skill's `SKILL.md`
    def body_path(kind, name)
      DIRECTORY_KINDS.key?(kind) ? File.join(path_for(kind, name), DIRECTORY_KINDS[kind]) : path_for(kind, name)
    end

    # @param kind [String, nil] only this kind
    # @return [Array<Hash>] the entries, sorted by kind then name
    def entries(kind: nil)
      kinds = kind ? [kind] : KINDS
      kinds.flat_map do |k|
        ext = DIRECTORY_KINDS.key?(k) ? "" : ".md"
        Dir.glob(File.join(@dir, k, "*#{ext}")).map { |path| File.basename(path, ext) }
          .select { |name| name.match?(NAME) }.sort
          .map { |name| entry(k, name) }
      end
    end

    # @param kind [String]
    # @param name [String]
    # @return [Hash, nil] the entry, or nil when the store has none
    def find(kind, name)
      path = path_for(kind, name)
      (File.exist?(path) || File.symlink?(path)) ? entry(kind, name) : nil
    end

    # @param kind [String]
    # @param name [String]
    # @return [String] the entry's body (a skill's `SKILL.md`)
    # @raise [Workspace::Error] code `library_source_missing` when the file (or a link's target) can't be read
    def read(kind, name)
      File.read(body_path(kind, name))
    rescue SystemCallError => e
      raise Error.new("Can't read #{kind}/#{name}: #{e.message}", code: "library_source_missing",
        details: {"ref" => "#{kind}/#{name}", "path" => path_for(kind, name)})
    end

    # Stores `body` as the entry, replacing a copy or a link. A skill becomes
    # a directory holding only `SKILL.md`.
    #
    # @param kind [String]
    # @param name [String]
    # @param body [String]
    # @return [void]
    def write(kind, name, body)
      replace(kind, name) do |tmp|
        if DIRECTORY_KINDS.key?(kind)
          FileUtils.mkdir_p(tmp)
          File.write(File.join(tmp, DIRECTORY_KINDS[kind]), body)
        else
          File.write(tmp, body)
        end
      end
    end

    # Stores a copy of the directory `source`, replacing a copy or a link.
    #
    # @param kind [String] a directory kind
    # @param name [String]
    # @param source [String] a directory; a link to one is followed
    # @return [void]
    def copy_tree(kind, name, source)
      replace(kind, name) { |tmp| FileUtils.cp_r(File.realpath(source), tmp) }
    end

    # Stores a symlink to `target` as the entry, replacing a copy or a link.
    #
    # @param kind [String]
    # @param name [String]
    # @param target [String] an absolute path: a file, or a skill's directory
    # @return [void]
    def link(kind, name, target)
      replace(kind, name) { |tmp| File.symlink(target, tmp) }
    end

    # Deletes the entry, or the symlink; a link's target is never touched.
    #
    # @param kind [String]
    # @param name [String]
    # @return [void]
    def delete(kind, name)
      self.class.remove(path_for(kind, name))
    end

    # What a file or a directory holds, to tell whether two are the same: a
    # file's bytes, or a directory's files by relative path. Links are followed.
    #
    # @param path [String]
    # @return [String, Hash{String=>String}]
    def self.snapshot(path)
      return File.binread(path) unless File.directory?(path)
      root = File.realpath(path)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort
        .select { |rel| File.file?(File.join(root, rel)) }
        .to_h { |rel| [rel, File.binread(File.join(root, rel))] }
    end

    # Removes a file, a symlink (never its target) or a directory tree.
    #
    # @param path [String]
    # @return [void]
    def self.remove(path)
      if File.directory?(path) && !File.symlink?(path)
        FileUtils.rm_rf(path)
      else
        File.unlink(path)
      end
    end

    private

    # Builds the new entry at a temp path, then renames it into place. A
    # directory can't be renamed over a link or a directory, so whatever is there
    # is moved aside first, and put back if the rename fails.
    def replace(kind, name)
      path = path_for(kind, name)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp-#{Process.pid}"
      yield tmp
      if File.exist?(path) || File.symlink?(path)
        old = "#{path}.old-#{Process.pid}"
        File.rename(path, old)
      end
      begin
        File.rename(tmp, path)
      rescue SystemCallError
        File.rename(old, path) if old
        old = nil
        raise
      end
      self.class.remove(old) if old
    ensure
      self.class.remove(tmp) if tmp && (File.symlink?(tmp) || File.exist?(tmp))
    end

    def entry(kind, name)
      path = path_for(kind, name)
      link = File.symlink?(path) ? File.readlink(path) : nil
      body = body_path(kind, name)
      readable = File.file?(body) && File.readable?(body)
      stat = begin
        File.stat(path)
      rescue SystemCallError
        File.lstat(path)
      end
      {
        "kind" => kind, "name" => name, "ref" => "#{kind}/#{name}",
        "scope" => @scope, "project" => @project,
        "path" => path, "link" => link, "readable" => readable,
        "description" => readable ? description(File.read(body)) : nil,
        "updated_at" => stat.mtime.utc.iso8601
      }
    end

    # The `description:` frontmatter key when the file has one, else its first heading.
    def description(body)
      if body.start_with?("---\n") && (front = body.split(/^---\s*$\n?/, 3)[1])
        if (m = front.match(/^description:\s*(.+?)\s*$/))
          return m[1].sub(/\A(["'])(.*)\1\z/, '\2')
        end
      end
      body.lines.find { |line| line.start_with?("#") }&.sub(/\A#+\s*/, "")&.strip
    end
  end
end
