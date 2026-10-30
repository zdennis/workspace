require "json"

module Workspace
  module Commands
    # `pr feedback`: what reviewers and CI said about a workspace's pull request,
    # read through {PullRequestFeedback}. It is read-only and writes no events.
    # Bodies are cut at {BODY_LIMIT} characters, and resolved threads are left
    # out unless asked for.
    class PrFeedback
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # Most characters of one comment or review body.
      BODY_LIMIT = 4_000

      # C0 and C1 controls, line separators, bidi overrides and isolates, and zero-width characters.
      UNSAFE = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u061c\u2060-\u2064\u2066-\u2069\ufeff]/
      private_constant :UNSAFE

      # @param feedback [Workspace::PullRequestFeedback]
      # @param checkout [Workspace::WorkspaceCheckout]
      # @param output [IO]
      def initialize(feedback:, checkout:, output: $stdout)
        @feedback = feedback
        @checkout = checkout
        @output = output
      end

      # @param name [String, nil] the workspace; nil means the one the working directory is in
      # @param all [Boolean] keep resolved threads
      # @param json [Boolean] print the document documented in docs/README.pr.md
      # @param working_dir [String]
      # @return [void]
      # @raise [Workspace::Error] `not_in_workspace`, `unknown_workspace`, `no_pull_request`, `gh_unavailable`,
      #   `pr_feedback_failed`, or an uncoded error for a detached HEAD
      def call(name: nil, all: false, json: false, working_dir: Dir.pwd)
        target = @checkout.resolve(name, working_dir: working_dir)
        read = @feedback.call(target["path"], branch: target["branch"])
        document = build(target, read, all)
        if json
          @output.puts JSON.generate(document)
        else
          render(document)
        end
      end

      private

      def build(target, read, all)
        fetched = read["threads"]
        shown = fetched.reject { |thread| thread["resolved"] && !all }.reject { |thread| thread["comments"].empty? }
        reviews = read["reviews"].map { |review| cut(review) }
        comments = read["comments"].map { |comment| cut(comment) }
        failed = read["checks"]["failed"]
        {
          "schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => target["workspace"], "branch" => target["branch"],
          "pull_request" => read["pull_request"].except("author_kind"),
          "threads" => shown.map { |thread| thread.merge("comments" => thread["comments"].map { |comment| cut(comment) }) },
          "reviews" => reviews, "comments" => comments, "checks" => {"failed" => failed},
          "counts" => {
            "threads" => read["totals"]["threads"], "unresolved" => fetched.count { |t| !t["resolved"] },
            "resolved" => fetched.count { |t| t["resolved"] }, "outdated" => fetched.count { |t| t["outdated"] },
            "reviews" => reviews.size, "comments" => comments.size, "failing_checks" => failed.size
          },
          "truncated" => read["truncated"]
        }
      end

      def cut(item)
        body = item["body"].to_s
        item.merge("body" => body[0, BODY_LIMIT], "body_truncated" => body.length > BODY_LIMIT)
      end

      def render(document)
        pull = document["pull_request"]
        counts = document["counts"]
        @output.puts "PR ##{pull["number"]} #{escape(pull["title"])}: #{counts["unresolved"]} unresolved threads " \
          "(#{counts["outdated"]} outdated), #{counts["reviews"]} reviews with comments, #{counts["comments"]} comments, " \
          "#{counts["failing_checks"]} failing checks"
        document["threads"].each { |thread| @output.puts thread_line(thread) }
        document["checks"]["failed"].each { |check| @output.puts "  failing check: #{escape(check["name"])}" }
      end

      def thread_line(thread)
        first = thread["comments"].first
        every = thread["comments"]
        place = thread["line"] ? "#{thread["path"]}:#{thread["line"]}" : thread["path"].to_s
        tags = []
        tags << "[resolved]" if thread["resolved"]
        tags << "[untrusted]" unless every.all? { |c| c["trusted"] }
        tags << "[hidden html]" if every.any? { |c| c["hidden_html"] }
        text = first["body"].to_s.lines.first.to_s.strip
        ["  #{escape(place)}  #{escape(first["author"] || "unknown")}: #{escape(text)}", *tags].join(" ")
      end

      def escape(text)
        text.to_s.scrub.gsub(UNSAFE) do |char|
          case char
          when "\e" then "\\e"
          when "\n" then "\\n"
          when "\r" then "\\r"
          when "\t" then "\\t"
          else format("\\u%04X", char.ord)
          end
        end
      end
    end
  end
end
