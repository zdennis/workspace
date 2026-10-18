require "yaml"
require "fileutils"
require "tempfile"

module Workspace
  # Groups of repositories ("multi-repository projects"), one hand-editable
  # file each at `~/.config/workspace/groups/<slug>.yml`:
  #
  #     name: Billing
  #     repositories:
  #       - id: /src/api/.git
  #         path: /src/api
  #
  # A repository is identified by the realpath of its git common dir, the
  # same key {Workspace::ProjectCatalog} uses for a project's +id+, so a moved
  # checkout keeps its group. A repository is in at most one group. A
  # repository whose directory is gone reads as +exists+ false. A file that
  # can't be parsed is left out of the listing, never an error.
  #
  # Writing (`create`, `add`) rewrites the whole file from +name+ and
  # +repositories+, so comments and other keys are not kept. A file that can't
  # be parsed is not seen by the one-group-per-repository check.
  #
  # {Workspace::ProjectCatalog} knows nothing of groups; this is a separate layer.
  class ProjectGroups
    # The prefix of a group id, so it can't be mistaken for a repository's path id.
    ID_PREFIX = "group:".freeze

    # Longest slug a name may make.
    MAX_SLUG_LENGTH = 64

    # @!attribute slug [String] the file name without `.yml`
    # @!attribute name [String] display name
    # @!attribute path [String] the group's file
    # @!attribute repositories [Array<Repository>] in the order they were added
    Group = Struct.new(:slug, :name, :path, :repositories, keyword_init: true) do
      # @return [String] `group:<slug>`
      def id = "#{ID_PREFIX}#{slug}"
    end

    # @!attribute id [String] realpath of the git common dir
    # @!attribute path [String] the main checkout
    # @!attribute name [String] display name, from the checkout directory
    # @!attribute exists [Boolean] whether the repository is still on disk
    Repository = Struct.new(:id, :path, :name, :exists, keyword_init: true)

    # @param id [String, nil] a project or group id
    # @return [Boolean] whether +id+ is a group id
    def self.group_id?(id)
      id.to_s.start_with?(ID_PREFIX)
    end

    # @param config [Workspace::Config] where the group files live
    # @param git [Workspace::Git] reads checkout layouts from `.git` files
    def initialize(config:, git:)
      @config = config
      @git = git
    end

    # @return [Array<Group>] every readable group, sorted by slug
    def all
      Dir.glob(File.join(@config.groups_dir, "*.yml")).sort.filter_map { |path| read(path) }.sort_by(&:slug)
    end

    # @param token [String] `group:<slug>`, a slug or a name (ignoring case)
    # @return [Group]
    # @raise [Workspace::Error] code `unknown_group`
    def find(token)
      token = token.to_s
      bare = token.delete_prefix(ID_PREFIX)
      groups = all
      found = groups.find { |group| group.slug == bare } ||
        groups.find { |group| group.name.casecmp?(bare) } ||
        groups.find { |group| group.slug == slugify(bare) }
      found || raise(Error.new("Unknown group '#{token}'. Run 'workspace projects group list'.", code: "unknown_group", details: {"group" => token}))
    end

    # The group a repository is in, for W13b's `group` key on project rows.
    #
    # @param project_id [String] a {Workspace::ProjectCatalog::Project} +id+
    # @return [Group, nil]
    def group_for_project(project_id)
      all.find { |group| group.repositories.any? { |repository| repository.id == project_id } }
    end

    # Makes an empty group.
    #
    # @param name [String]
    # @return [Group]
    # @raise [Workspace::Error] codes `invalid_group_name`, `group_exists`
    def create(name)
      name = name.to_s.strip
      slug = slugify(name)
      if slug.empty? || name.match?(/[[:cntrl:]]/) || slug.length > MAX_SLUG_LENGTH
        raise Error.new("Invalid group name '#{name}': use letters or digits, at most #{MAX_SLUG_LENGTH} characters once made into a slug.",
          code: "invalid_group_name", details: {"name" => name})
      end
      locked do
        path = @config.group_path(slug)
        if File.exist?(path)
          raise Error.new("A group named '#{slug}' already exists (#{path}).", code: "group_exists", details: {"group" => "#{ID_PREFIX}#{slug}", "path" => path})
        end
        write(path, name, [])
        read(path)
      end
    end

    # Adds the repository at +path+ to a group. Adding it again to the same
    # group changes nothing.
    #
    # @param token [String] the group
    # @param path [String] a directory inside a git checkout (main or worktree)
    # @return [Array(Group, Repository, Boolean)] the group, the repository and whether it was added now
    # @raise [Workspace::Error] codes `unknown_group`, `not_a_directory`,
    #   `not_a_repository`, `repository_in_group`
    def add(token, path)
      expanded = File.expand_path(path.to_s)
      unless File.directory?(expanded)
        raise Error.new("Not a directory: #{path}", code: "not_a_directory", details: {"path" => expanded})
      end
      id = repository_id(expanded)
      locked do
        group = find(token)
        broken = Dir.glob(File.join(@config.groups_dir, "*.yml")).find { |file| read(file).nil? }
        if broken
          raise Error.new("Can't read #{broken}; fix or remove it first, or the one-group-per-repository check can't be trusted.",
            code: "config_parse", details: {"path" => broken})
        end
        other = all.find { |g| g.slug != group.slug && g.repositories.any? { |r| r.id == id } }
        if other
          raise Error.new("#{id} is already in group '#{other.slug}'. A repository is in at most one group; edit #{other.path} to move it.",
            code: "repository_in_group", details: {"repository" => id, "group" => other.id, "path" => other.path})
        end
        existing = group.repositories.find { |r| r.id == id }
        next [group, existing, false] if existing

        entry = build_repository(id)
        write(group.path, group.name, group.repositories + [entry])
        [read(group.path), entry, true]
      end
    end

    private

    def repository_id(directory)
      layout = @git.checkout_layout(directory)
      if layout.nil? || layout[:broken] || layout[:common_dir].to_s.empty?
        raise Error.new("Not a git repository: #{directory}", code: "not_a_repository", details: {"path" => directory})
      end
      real(layout[:common_dir])
    end

    def build_repository(id)
      main = (File.basename(id) == ".git") ? File.dirname(id) : id
      Repository.new(id: id, path: main, name: WorkspaceLineage.name_from_path(main).delete_suffix(".git"), exists: File.directory?(id))
    end

    def slugify(name)
      name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    # Group files are read by anyone, written under one lock for the whole
    # directory (the one-group-per-repository check spans files) and renamed
    # into place, so a reader never sees a half-written file.
    def locked
      FileUtils.mkdir_p(@config.groups_dir)
      File.open(File.join(@config.groups_dir, ".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def write(path, name, repositories)
      data = {"name" => name, "repositories" => repositories.map { |r| {"id" => r.id, "path" => r.path} }}
      temp = Tempfile.create([".#{File.basename(path)}", ".tmp"], File.dirname(path))
      begin
        temp.write(YAML.dump(data))
        temp.close
        File.chmod(0o644, temp.path)
        File.rename(temp.path, path)
      ensure
        temp.close unless temp.closed?
        File.delete(temp.path) if File.exist?(temp.path)
      end
    end

    def read(path)
      data = YAML.safe_load_file(path)
      return nil unless data.is_a?(Hash)
      slug = File.basename(path, ".yml")
      name = data["name"].to_s.strip
      name = slug if name.empty?
      entries = Array(data["repositories"]).filter_map { |entry| repository_from(entry) }
      Group.new(slug: slug, name: name, path: path, repositories: entries.uniq(&:id))
    rescue Psych::Exception, SystemCallError
      nil
    end

    # An entry is `{id:, path:}`, or, written by hand, just a directory.
    def repository_from(entry)
      id = entry.is_a?(Hash) ? entry["id"].to_s : ""
      if id.empty?
        directory = entry.is_a?(Hash) ? entry["path"].to_s : entry.to_s
        return nil if directory.empty?
        directory = File.expand_path(directory)
        layout = File.directory?(directory) ? @git.checkout_layout(directory) : nil
        return nil unless layout && !layout[:broken] && layout[:common_dir]
        id = real(layout[:common_dir])
      end
      build_repository(id)
    end
  end
end
