require "fileutils"
require "time"

module Workspace
  # The files of one library scope: a directory holding `<kind>/<name>.md`
  # entries, each a copied file or a symlink to its source. There is no
  # index; the directory is the store. Writes go through a temp file and a
  # rename, so a reader never sees a half-written entry.
  class LibraryStore
    # The kinds an entry can have. A play is a document an agent reads and
    # follows; a prompt is short text sent as typed.
    KINDS = %w[play prompt].freeze

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
    # @return [String] where the entry lives, whether or not it exists
    def path_for(kind, name)
      File.join(@dir, kind, "#{name}.md")
    end

    # @param kind [String, nil] only this kind
    # @return [Array<Hash>] the entries, sorted by kind then name
    def entries(kind: nil)
      kinds = kind ? [kind] : KINDS
      kinds.flat_map do |k|
        Dir.glob(File.join(@dir, k, "*.md")).map { |path| File.basename(path, ".md") }
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
    # @return [String] the entry's body
    # @raise [Workspace::Error] code `library_source_missing` when the file (or a link's target) can't be read
    def read(kind, name)
      File.read(path_for(kind, name))
    rescue SystemCallError => e
      raise Error.new("Can't read #{kind}/#{name}: #{e.message}", code: "library_source_missing",
        details: {"ref" => "#{kind}/#{name}", "path" => path_for(kind, name)})
    end

    # Stores `body` as the entry, replacing a copy or a link.
    #
    # @param kind [String]
    # @param name [String]
    # @param body [String]
    # @return [void]
    def write(kind, name, body)
      replace(kind, name) { |tmp| File.write(tmp, body) }
    end

    # Stores a symlink to `target` as the entry, replacing a copy or a link.
    #
    # @param kind [String]
    # @param name [String]
    # @param target [String] an absolute path
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
      File.unlink(path_for(kind, name))
    end

    private

    def replace(kind, name)
      path = path_for(kind, name)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp-#{Process.pid}"
      yield tmp
      File.rename(tmp, path)
    ensure
      File.unlink(tmp) if tmp && (File.symlink?(tmp) || File.exist?(tmp))
    end

    def entry(kind, name)
      path = path_for(kind, name)
      link = File.symlink?(path) ? File.readlink(path) : nil
      readable = File.file?(path) && File.readable?(path)
      stat = begin
        File.stat(path)
      rescue SystemCallError
        File.lstat(path)
      end
      {
        "kind" => kind, "name" => name, "ref" => "#{kind}/#{name}",
        "scope" => @scope, "project" => @project,
        "path" => path, "link" => link, "readable" => readable,
        "description" => readable ? description(File.read(path)) : nil,
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
