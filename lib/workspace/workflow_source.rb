module Workspace
  # The semantic parse of one `workflows.sources` entry. Pure string work: no
  # I/O, no `gh`, no `File` calls. The config schema checks an entry's shape;
  # this says what it points at. The fetcher and installer call it.
  module WorkflowSource
    # A parsed source.
    #
    # @!attribute kind [Symbol] `:github` or `:local`
    # @!attribute owner [String, nil] GitHub owner (github only)
    # @!attribute repo [String, nil] GitHub repository (github only)
    # @!attribute ref [String, nil] branch, tag or sha; nil means the default branch (github only)
    # @!attribute path [String] directory inside the repository, or the local directory with `~` expanded
    Parsed = Struct.new(:kind, :owner, :repo, :ref, :path, keyword_init: true)

    GITHUB_HOSTS = %w[github.com www.github.com].freeze
    URL = %r{\A(?<scheme>[a-z][a-z0-9+.-]*)://(?<host>[^/]+)(?<rest>/.*)?\z}i

    # @param entry [String] one `workflows.sources` entry
    # @param home [String, nil] what a leading `~` stands for; defaults to `$HOME`
    # @return [Parsed] frozen
    # @raise [UsageError] for a non-GitHub URL, a missing owner or repository, or an empty path
    def self.parse(entry, home: ENV["HOME"])
      raise UsageError, "workflow source must be a non-empty string" unless entry.is_a?(String) && !entry.strip.empty?

      text = entry.strip
      return local(text, home) if text.start_with?("/", "~/") || text == "~"

      if (m = URL.match(text))
        unless m[:scheme].downcase == "https" && GITHUB_HOSTS.include?(m[:host].downcase)
          raise UsageError, "workflow source #{text.inspect} is not a github.com URL"
        end
        return from_segments(text, segments(m[:rest].to_s), url: true)
      end

      from_segments(text, segments(text), url: false)
    end

    def self.segments(text)
      text.split("/").reject(&:empty?)
    end
    private_class_method :segments

    def self.local(text, home)
      path = text
      if text == "~" || text.start_with?("~/")
        raise UsageError, "workflow source #{text.inspect} needs HOME to expand ~" if home.to_s.empty?
        path = home.chomp("/") + text[1..]
      end
      Parsed.new(kind: :local, path: path).freeze
    end
    private_class_method :local

    def self.from_segments(text, parts, url:)
      owner, repo, *rest = parts
      raise UsageError, "workflow source #{text.inspect} needs an owner and repository (owner/repo/path)" if owner.nil? || repo.nil?

      ref = nil
      if url && rest.first == "tree"
        ref = rest[1]
        rest = rest.drop(2)
        raise UsageError, "workflow source #{text.inspect} has /tree/ but no ref" if ref.nil?
      end
      raise UsageError, "workflow source #{text.inspect} has an empty path" if rest.empty?
      raise UsageError, "workflow source #{text.inspect} must not contain .. segments" if rest.include?("..")

      Parsed.new(kind: :github, owner: owner, repo: repo, ref: ref, path: rest.join("/")).freeze
    end
    private_class_method :from_segments
  end
end
