module Workspace
  # Finds the identifiers a sentence names: GitHub pull request and issue URLs,
  # Atlassian ticket URLs and bare JIRA keys. Pure text work, no collaborators.
  # Each hit carries a +token+ that {StartRef#call} reads on its own, so the
  # sentence itself never reaches `start`.
  module RefInText
    # One identifier found in text.
    #
    # @!attribute token [String] canonical URL or uppercase JIRA key, ready for {StartRef#call}
    # @!attribute id [String] what decides sameness: kind and `o/r#N` lowercased, or the key
    # @!attribute repo [String, nil] "o/r" for a GitHub URL, nil for JIRA
    # @!attribute link [Boolean] true for a URL, false for a bare key
    Found = Struct.new(:token, :id, :repo, :link, keyword_init: true)

    # Prefixes that look like keys but are not tickets. Applies to bare keys and {.word_key}, never to an Atlassian URL.
    NOT_TICKETS = %w[UTF SHA MD AES RSA ISO RFC HTTP TLS SSL GPT CVE PR ISSUE PEP IPV ES].freeze

    # A URL starts at the text's start, after whitespace or after opening punctuation.
    URL_START = "(?<![^[:space:](\\[{<\"'`])"

    GITHUB_URL = %r{#{URL_START}https?://github\.com/([\w.-]+)/([\w.-]+)/(pull|issues)/(\d+)(?!\w|\.\d)}
    ATLASSIAN_URL = %r{#{URL_START}https?://[A-Za-z0-9-]+\.atlassian\.net/browse/([A-Za-z]+)-(\d+)(?!\w)}
    ANY_URL = %r{\S*://\S*}
    BARE_KEY = /(?<![\w\/.\-=?&#])([A-Z]{2,})-(\d+)(?!\w|-|\.\w)/
    MAX_DIGITS = 9
    WORD_KEY = /\A([A-Za-z]{2,})-(\d+)\z/

    # @param text [String]
    # @return [Array<Found>] one per distinct identifier, in order of appearance
    def self.scan(text)
      text = clean(text)
      hits = []
      text.scan(GITHUB_URL) do |owner, name, kind, digits|
        at = Regexp.last_match.begin(0)
        number = digits.sub(/\A0+/, "")
        next if number.empty? || number.length > MAX_DIGITS || !repo_part?(owner) || !repo_part?(name) || name.end_with?(".")

        hits << [at, github(owner, name, kind, number)]
      end
      text.scan(ATLASSIAN_URL) do |letters, number|
        next if number.length > MAX_DIGITS

        hits << [Regexp.last_match.begin(0), jira("#{letters}-#{number}".upcase, link: true)]
      end
      blanked = text.gsub(ANY_URL) { |url| " " * url.length }
      blanked.scan(BARE_KEY) do |letters, number|
        next if NOT_TICKETS.include?(letters) || number.length > MAX_DIGITS

        hits << [Regexp.last_match.begin(0), jira("#{letters}-#{number}", link: false)]
      end
      hits.sort_by(&:first).map(&:last).group_by(&:id).values.map do |same|
        same.first.tap { |first| first.link = same.any?(&:link) }
      end
    end

    # @param word [String] one whole word
    # @return [String, nil] the uppercase key, nil when the word is not key-shaped or its prefix is not a ticket's
    def self.word_key(word)
      match = WORD_KEY.match(clean(word))
      return unless match
      return if match[2].length > MAX_DIGITS
      return if NOT_TICKETS.include?(match[1].upcase)

      "#{match[1]}-#{match[2]}".upcase
    end

    def self.clean(text)
      text = text.to_s
      text = text.encode("UTF-8", invalid: :replace, undef: :replace, replace: " ") unless text.encoding == Encoding::UTF_8
      text.scrub(" ")
    end

    def self.repo_part?(part)
      part != "." && part != ".."
    end

    def self.github(owner, name, kind, number)
      path = (kind == "pull") ? "pull" : "issues"
      Found.new(token: "https://github.com/#{owner}/#{name}/#{path}/#{number}",
        id: "github_#{(kind == "pull") ? "pr" : "issue"}:#{owner}/#{name}##{number}".downcase,
        repo: "#{owner}/#{name}", link: true)
    end

    def self.jira(key, link:)
      Found.new(token: key, id: key, repo: nil, link: link)
    end

    private_class_method :github, :jira, :clean, :repo_part?
  end
end
