module Workspace
  # Where the links `workspace skills install` makes point. Under Homebrew that
  # is the stable `opt` path, which `brew upgrade` re-points; in a checkout it is
  # the checkout's own `lib/skills`; a linked worktree is refused, because its
  # directory goes away with `finish`. Reads files only: no git, no PATH, no HOME.
  class SkillSource
    # The four skills that ship, the only names the install ever touches.
    NAMES = %w[workspace workspace-agent-run workspace-inbox workspace-lifecycle].freeze

    # Matches a Homebrew keg's libexec: prefix, formula.
    CELLAR = %r{\A(.+)/Cellar/([^/]+)/[^/]+/libexec\z}

    # @!attribute root
    #   @return [String] the directory holding the skill directories
    # @!attribute kind
    #   @return [String] "homebrew" or "checkout"
    Source = Struct.new(:root, :kind)

    # @param workspace_dir [String] the installation directory (`Config#workspace_dir`)
    def initialize(workspace_dir:)
      @workspace_dir = workspace_dir
    end

    # @return [Source]
    # @raise [Workspace::Error] `skill_source_worktree` from a linked worktree, `skills_source_missing` when `lib/skills` lacks a skill
    def resolve
      real = begin
        File.realpath(@workspace_dir)
      rescue SystemCallError
        raise missing(File.join(@workspace_dir, "lib", "skills"), NAMES)
      end
      brew = CELLAR.match(real)
      opt = brew && "#{brew[1]}/opt/#{brew[2]}/libexec"
      if opt && File.directory?(opt)
        source = Source.new(File.join(opt, "lib", "skills"), "homebrew")
      else
        raise worktree(real) if linked_worktree?(real)
        source = Source.new(File.join(real, "lib", "skills"), "checkout")
      end
      absent = NAMES.reject { |name| File.directory?(File.join(real, "lib", "skills", name)) }
      raise missing(File.join(real, "lib", "skills"), absent) if absent.any?
      source
    end

    private

    # A linked worktree's `.git` is a file naming a directory that holds `commondir`.
    # A `.git` file that can't be read counts as one: refusing is the safe answer.
    def linked_worktree?(dir)
      git = File.join(dir, ".git")
      return false unless File.file?(git)
      gitdir = File.read(git)[/\Agitdir:\s*(.+?)\s*$/, 1]
      return true unless gitdir
      File.exist?(File.join(File.expand_path(gitdir, dir), "commondir"))
    rescue SystemCallError
      true
    end

    def worktree(dir)
      Error.new("#{dir} is a linked git worktree, so skill links into it would dangle once it is removed. " \
        "Run 'workspace skills install' from the main checkout or from a Homebrew install.",
        code: "skill_source_worktree", details: {"path" => dir})
    end

    def missing(dir, names)
      Error.new("This install has no #{names.join(", ")} under #{dir}.",
        code: "skills_source_missing", details: {"path" => dir, "missing" => names})
    end
  end
end
