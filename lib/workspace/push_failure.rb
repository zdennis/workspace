module Workspace
  # Turns the stderr of a failed `git push` into a {Workspace::Error} with a
  # stable code, `details.permanent`, and, for a temporary failure, a `retry`
  # hint. The patterns live here and nowhere else; `push`, `pr create` and
  # {Git#push} (for a timeout) all raise through it.
  #
  # Only git's own lines are read (see {GIT_LINE}), so text from a local
  # pre-push hook never picks the code. Git runs with `LC_ALL=C` for the push, so
  # the patterns are English.
  #
  # Codes: `no_remote`, `push_auth_failed`, `protected_branch` and
  # `push_rejected` are permanent; `push_network` is temporary (`retry` is the
  # same command again); `push_timeout` is temporary but the push may have
  # landed (`details.state_unknown`, no `retry`); `push_failed` is anything else
  # and counts as permanent, since retrying blind is the riskier choice.
  module PushFailure
    # The lines of git's stderr that may pick a code: git's own prefixes and the
    # lines ssh prints on its own.
    GIT_LINE = /\A\s*(remote:|fatal:|error:|hint:|!|ssh:|kex_|send-pack:|pack-objects:|client_loop:|Connection to \S+ closed|To |LFS:|Host key verification|@+ |Permission denied \(|Connection (closed by|timed out|refused|reset)|\S+@\S+: Permission denied)/

    REJECTED_BRACKET = /\[rejected\]/
    REJECTED_REASON = /non-fast-forward|fetch first|stale info|tip .* behind|remote contains work/i
    REMOTE_REJECTED_REASON = /\[remote rejected\].*\((non-fast-forward|stale info)/i
    NON_FAST_FORWARD = ->(text) { (text.match?(REJECTED_BRACKET) && text.match?(REJECTED_REASON)) || text.match?(REMOTE_REJECTED_REASON) }

    # Any other HTTP 4xx (413, say) is permanent and not a login problem; it must not read as a network failure.
    OTHER_HTTP_4XX = /(returned error: |HTTP )4(?!01|03|04|07|08|29)\d\d/

    # Checked in order; the first match wins. Overlaps that fix the order:
    # protection wording and 404/auth lines can share a stderr with
    # "Could not read from remote repository", which names nothing by itself;
    # `[remote rejected]` lines carry protection, workflow-scope and
    # non-fast-forward reasons, so protection and auth are read before
    # rejection; "Repository not found" is no_remote only after auth has had its
    # say (a refused login can say it too); and a 4xx other than 401, 403, 404,
    # 407 and 429 is checked before network because curl's "RPC failed" lines
    # sit beside it.
    PATTERNS = [
      ["push_auth_failed", /Permission denied \(publickey|Authentication failed|returned error: 40[137]|HTTP (code )?40[137]|Permission to .+ denied|could not read (Username|Password)|Invalid username or password|Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|not allowed to push code to this project|HTTP Basic: Access denied|Proxy Authentication|LFS: .*(Authentication|Authorization|(Client error|error).*: 40[13]\b)|Git credentials .* not found|without .workflow. scope/i],
      ["protected_branch", /protected branch|GH006|GH013|Repository rule violations|not allowed to push code to protected branches|Branch .* is protected/i],
      ["push_rejected", NON_FAST_FORWARD],
      ["no_remote", /No configured push destination|No such remote|does not appear to be a git repository|Repository not found|repository '.*' not found|returned error: 404/i],
      ["push_failed", OTHER_HTTP_4XX],
      ["push_network", /Could not resolve (host|proxy)|Failed to connect|Connection (timed out|refused|reset|closed by)|Operation timed out|Network is unreachable|Temporary failure in name resolution|SSL_ERROR_SYSCALL|kex_exchange_identification|returned error: (408|429|50\d)|HTTP (408|429|50\d)|remote end hung up unexpectedly|client_loop: send disconnect|Connection to \S+ closed|RPC failed.*(HTTP 5\d\d|curl 5[56])|unexpected disconnect|cannot lock ref .* but expected/i]
    ].freeze

    # Codes whose failure may pass on its own, so the same command is worth running again.
    TEMPORARY = %w[push_network].freeze

    # The retry hint of a temporary failure: run the same command again, no flag, nothing destructive.
    RETRY = {"flags" => [], "destructive" => false}.freeze

    CODES = (PATTERNS.map(&:first) + ["push_timeout"]).uniq.freeze

    # @param stderr [String, nil] git's stderr
    # @return [String] a code from {CODES}
    def self.classify(stderr)
      text = git_text(stderr)
      PATTERNS.each { |code, matcher| return code if matcher === text } # rubocop:disable Style/CaseEquality
      "push_failed"
    end

    # @param branch [String]
    # @param stderr [String, nil] git's stderr
    # @return [Workspace::Error] with `details` branch, detail, permanent (and stderr, for `push_failed`)
    def self.error(branch, stderr)
      code = classify(stderr)
      text = scrubbed(stderr)
      detail = detail_line(text, code)
      details = {"branch" => branch, "detail" => detail, "permanent" => !TEMPORARY.include?(code)}
      if code == "push_rejected"
        details["upstream"] = nil
        details["reason"] = "origin_refused"
      end
      details["stderr"] = text.strip[0, 2000] if code == "push_failed"
      message = (code == "push_rejected") ? "Push of '#{branch}' was rejected: #{detail}" : "Could not push '#{branch}': #{detail}"
      Workspace::Error.new(message, code: code, details: details, retry_with: TEMPORARY.include?(code) ? RETRY : nil)
    end

    # The push ran past its time limit: origin may or may not have taken it, so no plain retry.
    #
    # @param branch [String]
    # @param seconds [Numeric]
    # @return [Workspace::Error]
    def self.timeout_error(branch, seconds)
      Workspace::Error.new("git push of '#{branch}' did not finish within #{seconds} seconds; origin may already have it. Check the remote (git ls-remote origin #{branch}) before pushing again.",
        code: "push_timeout", details: {"branch" => branch, "seconds" => seconds, "permanent" => false, "state_unknown" => true})
    end

    def self.scrubbed(stderr)
      stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end
    private_class_method :scrubbed

    def self.git_text(stderr)
      scrubbed(stderr).lines.grep(GIT_LINE).join
    end
    private_class_method :git_text

    def self.detail_line(text, code)
      lines = text.lines.map(&:strip)
      pick = (code == "push_rejected") ? lines.find { |l| l.start_with?("!") } : nil
      pick ||= lines.find { |l| l.match?(/\A(fatal|error|remote):/) } || lines.find { |l| l.match?(GIT_LINE) } || lines.first
      pick.to_s[0, 300]
    end
    private_class_method :detail_line
  end
end
