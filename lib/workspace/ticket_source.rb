require "json"
require "open3"
require "timeout"
require "uri"

module Workspace
  # Reads a ticket's title, body and URL with the tool that knows it: `gh` for a
  # pull request or an issue, `jira` (jira-cli, `jira issue view KEY --raw`) for
  # a JIRA key. It only reads. A plain branch has no ticket, so nothing runs.
  # Neither tool is required: a missing tool, a timeout or a failure is
  # `ticket_source_unavailable` with the reason, and a ticket the tool says does
  # not exist is `ticket_not_found`. Credentials stay with the tools; none is
  # read, stored or printed here.
  class TicketSource
    # Seconds a tool may take.
    DEFAULT_TIMEOUT = 10.0

    # Longest body returned, in bytes.
    MAX_BODY_BYTES = 64 * 1024

    NOT_FOUND = /could not resolve to an? |http 404|issue does not exist/i
    BLOCKS = %w[paragraph heading listItem codeBlock blockquote].freeze
    private_constant :NOT_FOUND, :BLOCKS

    # Runs a command without a prompt, in its own process group that is stopped
    # when +timeout+ passes.
    #
    # @param argv [Array<String>] the command and its arguments
    # @param chdir [String] directory to run in
    # @param timeout [Numeric] seconds
    # @return [Array(String, String, Boolean)] stdout, stderr, success
    # @raise [Errno::ENOENT] if the command is not installed
    # @raise [Timeout::Error] if it ran past +timeout+
    def self.run(argv, chdir:, timeout:)
      TimedProcess.run(argv, chdir: chdir, timeout: timeout)
    end

    # @param runner [#call] `(argv, chdir:, timeout:)` returning `[stdout, stderr, success]`
    # @param which [#call] true when an executable is on the PATH
    # @param timeout [Numeric] seconds a tool may take
    def initialize(runner: self.class.method(:run), which: Workspace::Which, timeout: DEFAULT_TIMEOUT)
      @runner = runner
      @which = which
      @timeout = timeout
    end

    # @param ref [Workspace::StartRef::Ref]
    # @param chdir [String] the checkout, which `gh` uses when the ref names no repository
    # @return [Hash] `title`, `body` (at most 64 KB) and `url`, each nil when the ticket has none; all nil for a branch
    # @raise [Workspace::Error] `ticket_not_found` (`details.source`, `details.ref`) or
    #   `ticket_source_unavailable` (`details.source`, `details.reason` of `missing`, `timeout` or `error`, and `detail`)
    def fetch(ref, chdir:)
      case ref.kind
      when "github_pr" then github(ref, "pr", chdir)
      when "github_issue" then github(ref, "issue", chdir)
      when "jira" then jira(ref, chdir)
      else {"title" => nil, "body" => nil, "url" => nil}
      end
    end

    private

    def github(ref, noun, chdir)
      argv = ["gh", noun, "view", ref.parsed[:number] || ref.parsed[:value][/\d+/]]
      argv += ["--repo", ref.parsed[:repo]] if ref.parsed[:repo]
      doc = read("gh", argv + ["--json", "title,body,url"], ref, chdir)
      {"title" => doc["title"], "body" => cap(doc["body"]), "url" => doc["url"]}
    end

    def jira(ref, chdir)
      doc = read("jira", ["jira", "issue", "view", ref.key, "--raw"], ref, chdir)
      fields = doc["fields"].is_a?(Hash) ? doc["fields"] : {}
      {"title" => fields["summary"], "body" => cap(text(fields["description"])), "url" => browse_url(doc["self"], ref.key)}
    end

    def read(source, argv, ref, chdir)
      raise unavailable(source, "missing") unless @which.call(source)
      stdout, stderr, success = @runner.call(argv, chdir: chdir, timeout: @timeout)
      unless success
        raise Workspace::Error.new("No ticket #{ref.key}: #{first_line(stderr)}", code: "ticket_not_found", details: {"source" => source, "ref" => ref.input}) if stderr.to_s.match?(NOT_FOUND)
        raise unavailable(source, "error", first_line(stderr))
      end
      doc = JSON.parse(stdout)
      raise unavailable(source, "error", "unreadable reply from #{source}") unless doc.is_a?(Hash)
      doc
    rescue Errno::ENOENT
      raise unavailable(source, "missing")
    rescue Timeout::Error
      raise unavailable(source, "timeout")
    rescue JSON::ParserError
      raise unavailable(source, "error", "unreadable reply from #{source}")
    end

    def unavailable(source, reason, detail = nil)
      details = {"source" => source, "reason" => reason}
      details["detail"] = detail if detail
      message = {"missing" => "`#{source}` is not installed.", "timeout" => "`#{source}` did not answer in time."}.fetch(reason, "`#{source}` could not read the ticket: #{detail}")
      Workspace::Error.new(message, code: "ticket_source_unavailable", details: details)
    end

    def first_line(text)
      text.to_s.scrub.lines.first.to_s.strip[0, 200]
    end

    def cap(body)
      return nil if body.nil?
      return body if body.bytesize <= MAX_BODY_BYTES
      body.byteslice(0, MAX_BODY_BYTES).scrub("")
    end

    # A JIRA description is text, or Atlassian rich text (a tree of nodes).
    def text(description)
      return description unless description.is_a?(Hash)
      node_text(description).strip
    end

    def node_text(node)
      return "" unless node.is_a?(Hash)
      return node["text"].to_s if node["type"] == "text"
      return "\n" if node["type"] == "hardBreak"
      inner = Array(node["content"]).map { |child| node_text(child) }.join
      BLOCKS.include?(node["type"]) ? "#{inner}\n" : inner
    end

    # The issue's page on its site, from the host of the API address in the reply.
    def browse_url(api_url, key)
      uri = URI.parse(api_url.to_s)
      uri.host ? "#{uri.scheme}://#{uri.host}/browse/#{key}" : nil
    rescue URI::InvalidURIError
      nil
    end
  end
end
