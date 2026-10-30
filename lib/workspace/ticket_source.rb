require "json"
require "open3"
require "time"
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

    # The tools `list` can ask.
    SOURCES = %w[gh jira].freeze

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
    # @return [Hash] `title` (folded onto one line), `body` (at most 64 KB) and `url`, each nil when the ticket has none;
    #   all nil for a branch. A pull request also has `cross_repository`: what `gh` says, or nil when it says no boolean
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

    # Lists tickets from `gh` (issues and pull requests) and `jira`, newest
    # change first. Each source is asked on its own, within the time limit, at
    # the same time; one that is missing, slow or failing adds a warning and no
    # rows, and the others still answer.
    #
    # @param filter [String] `assigned` (open, assigned to the signed-in user) or `recent` (changed lately, anyone's)
    # @param limit [Integer] most rows asked of each source
    # @param chdir [String] the checkout, which `gh` uses to find the repository
    # @param sources [Array<String>] any of `gh`, `jira`
    # @return [Hash] `"rows"`: hashes with `ref` (a URL, or the JIRA key), `kind`, `source`, `title`, `url`, `state`,
    #   `updated_at`, newest first and cut to +limit+; `"warnings"`: `source`, `code` (`ticket_source_unavailable`),
    #   `reason` (`missing`, `timeout` or `error`), `detail` when the tool said something, and `message`
    def list(filter:, limit:, chdir:, sources: SOURCES)
      jobs = []
      jobs << ["gh", -> { github_list("issue", "github_issue", filter, limit, chdir) }] if sources.include?("gh")
      jobs << ["gh", -> { github_list("pr", "github_pr", filter, limit, chdir) }] if sources.include?("gh")
      jobs << ["jira", -> { jira_list(filter, limit, chdir) }] if sources.include?("jira")
      results = jobs.map { |source, job| [source, Thread.new { job.call }.tap { |t| t.report_on_exception = false }] }

      rows = []
      warnings = []
      results.each do |source, thread|
        rows.concat(thread.value)
      rescue Workspace::Error => e
        warning = e.details.slice("reason", "detail").merge("source" => source, "code" => e.code, "message" => e.message)
        warnings << warning unless warnings.include?(warning)
      end
      rows = rows.sort_by { |row| changed_at(row["updated_at"]) }.reverse.first(limit)
      {"rows" => rows, "warnings" => warnings}
    end

    private

    def github_list(noun, kind, filter, limit, chdir)
      argv = ["gh", noun, "list", "--state", "open", "--limit", limit.to_s, "--json", "number,title,url,state,updatedAt"]
      argv += (filter == "assigned") ? ["--assignee", "@me"] : ["--search", "sort:updated-desc"]
      read("gh", argv, nil, chdir, expect: Array).filter_map do |item|
        next unless item.is_a?(Hash) && item["url"]
        {"ref" => item["url"], "kind" => kind, "source" => "gh", "title" => line(item["title"]), "url" => item["url"],
         "state" => line(item["state"])&.downcase, "updated_at" => item["updatedAt"]}
      end
    end

    def jira_list(filter, limit, chdir)
      jql = (filter == "assigned") ? "assignee = currentUser() AND resolution = Unresolved" : "updated >= -14d"
      argv = ["jira", "issue", "list", "-q", jql, "--order-by", "updated", "--raw", "--paginate", "0:#{limit}"]
      doc = read("jira", argv, nil, chdir, expect: [Hash, Array])
      issues = doc.is_a?(Hash) ? Array(doc["issues"]) : doc
      issues.filter_map do |issue|
        next unless issue.is_a?(Hash) && issue["key"]
        fields = issue["fields"].is_a?(Hash) ? issue["fields"] : {}
        {"ref" => issue["key"], "kind" => "jira", "source" => "jira", "title" => line(fields["summary"]),
         "url" => browse_url(issue["self"], issue["key"]), "state" => line(fields.dig("status", "name")), "updated_at" => fields["updated"]}
      end
    end

    def github(ref, noun, chdir)
      argv = ["gh", noun, "view", ref.parsed[:number] || ref.parsed[:value][/\d+/]]
      argv += ["--repo", ref.parsed[:repo]] if ref.parsed[:repo]
      fields = (noun == "pr") ? "title,body,url,isCrossRepository" : "title,body,url"
      doc = read("gh", argv + ["--json", fields], ref, chdir)
      ticket = {"title" => line(doc["title"]), "body" => cap(doc["body"]), "url" => doc["url"]}
      # Only a boolean counts: a missing or odd field is nil, which `workflow start` refuses.
      ticket["cross_repository"] = [true, false].include?(doc["isCrossRepository"]) ? doc["isCrossRepository"] : nil if noun == "pr"
      ticket
    end

    def jira(ref, chdir)
      doc = read("jira", ["jira", "issue", "view", ref.key, "--raw"], ref, chdir)
      fields = doc["fields"].is_a?(Hash) ? doc["fields"] : {}
      {"title" => line(fields["summary"]), "body" => cap(text(fields["description"])), "url" => browse_url(doc["self"], ref.key)}
    end

    def read(source, argv, ref, chdir, expect: Hash)
      raise unavailable(source, "missing") unless @which.call(source)
      stdout, stderr, success = @runner.call(argv, chdir: chdir, timeout: @timeout)
      unless success
        raise Workspace::Error.new("No ticket #{ref.key}: #{first_line(stderr)}", code: "ticket_not_found", details: {"source" => source, "ref" => ref.input}) if ref && stderr.to_s.match?(NOT_FOUND)
        raise unavailable(source, "error", first_line(stderr))
      end
      doc = JSON.parse(stdout)
      raise unavailable(source, "error", "unreadable reply from #{source}") unless Array(expect).any? { |type| doc.is_a?(type) }
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

    # GitHub says `2026-10-17T10:00:00Z`, JIRA `2026-10-17T10:00:00.000+0200`; one that does not parse sorts last.
    def changed_at(text)
      Time.iso8601(text.to_s.sub(/([+-]\d\d)(\d\d)\z/, '\1:\2'))
    rescue ArgumentError
      Time.at(0)
    end

    # A title or state as one line of plain text: control characters and runs of whitespace become one space.
    def line(text)
      text&.to_s&.scrub&.gsub(/[[:space:][:cntrl:]]+/, " ")&.strip
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
