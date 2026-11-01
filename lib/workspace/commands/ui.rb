require "erb"
require "open3"

module Workspace
  module Commands
    # Builds a `workspace-ui://` deep link and hands it to the system's `open`,
    # so a script, an agent or a notification can send you to a screen of the
    # workspace UI. A link only opens a view; it never starts an agent or runs
    # a command, and the UI validates its target again when it receives one.
    class Ui
      # The views a link can name, each with whether it takes a workspace.
      VIEWS = {"task" => true, "review" => true, "notes" => true, "plan" => true, "pane" => true, "inbox" => false}.freeze

      # The one view that also names a tmux pane: `pane WORKSPACE PANE`.
      PANE_VIEW = "pane"

      # The one view that also takes a note path: `notes WORKSPACE --path REL`.
      NOTES_VIEW = "notes"

      # A tmux pane id such as `%19`.
      PANE_ID = /\A%\d{1,9}\z/

      # URL scheme the UI registers.
      SCHEME = "workspace-ui"

      # Longest workspace name accepted.
      MAX_NAME_LENGTH = 255

      # What `open` did. `outcome` is "opened", "printed" or "failed"; a
      # failure carries a `reason` ("open_failed", "open_unavailable") and a `message`.
      Result = Struct.new(:outcome, :view, :url, :reason, :message) do
        # @return [Boolean] whether the link was opened or printed
        def ok?
          outcome != "failed"
        end
      end

      # @param notes [Workspace::Commands::Notes, nil] resolves a workspace's notes directory for `notes --path`
      # @param app_probe [#call, nil] a {Workspace::UiAppProbe}; only `status` needs it
      # @param opener [#call] `(argv)` runs the command and returns `[stdout, stderr, status]`;
      #   raises SystemCallError when the executable is missing
      # @param output [IO]
      def initialize(notes:, opener: ->(argv) { Open3.capture3(*argv) }, output: $stdout, app_probe: nil)
        @notes = notes
        @app_probe = app_probe
        @opener = opener
        @output = output
      end

      # @param view [String] one of {VIEWS}
      # @param workspace [String, nil] required for every view but inbox, which refuses it
      # @param pane [String, nil] tmux pane id (`%19`): required for pane, refused for the others
      # @param path [String, nil] note path relative to the notes directory: only the notes view takes one,
      #   and the file must exist (checked by {Workspace::NotePath})
      # @return [String] the deep link, with the workspace and pane percent-encoded
      # @raise [Workspace::UsageError] for an unknown view, a workspace or pane that doesn't fit the view,
      #   or a pane that is not a tmux pane id
      # @raise [Workspace::Error] `invalid_note_path` when the note path is refused
      def url_for(view:, workspace: nil, pane: nil, path: nil)
        raise UsageError, "Unknown view '#{view}': one of #{VIEWS.keys.join(", ")}. Run 'workspace ui --help'." unless VIEWS.key?(view)

        raise UsageError, "#{view} takes no --path: only the notes view takes one. Run 'workspace ui --help'." if path && view != NOTES_VIEW

        if VIEWS.fetch(view)
          raise UsageError, "#{view} needs a workspace." if workspace.to_s.strip.empty?
          unless valid_name?(workspace)
            raise UsageError, "'#{workspace.to_s[0, 40].inspect[1..-2]}' is not a valid workspace name."
          end
          link = "#{SCHEME}://#{view}/#{ERB::Util.url_encode(workspace)}"
          if view == PANE_VIEW
            raise UsageError, "pane needs a pane id such as %19: workspace ui open pane [WORKSPACE] PANE. Run 'workspace ui --help'." if pane.to_s.strip.empty?
            unless pane.match?(PANE_ID)
              raise UsageError, "'#{pane.to_s[0, 40].inspect[1..-2]}' is not a tmux pane id: use the form %19 (see $TMUX_PANE or `tmux display -p '\#{pane_id}'`). Usage: workspace ui open pane [WORKSPACE] PANE."
            end
            link = "#{link}/#{ERB::Util.url_encode(pane)}"
          elsif pane
            raise UsageError, "#{view} takes no pane: only the pane view takes one."
          elsif path
            link = "#{link}/#{NotePath.url_path(checked_note(workspace, path))}"
          end
          link
        else
          raise UsageError, "#{view} takes no workspace." if workspace
          raise UsageError, "#{view} takes no pane." if pane
          "#{SCHEME}://#{view}"
        end
      end

      # Opens the link with `open`, or only prints it.
      #
      # @param view [String] one of {VIEWS}
      # @param workspace [String, nil]
      # @param pane [String, nil] see {#url_for}
      # @param path [String, nil] see {#url_for}
      # @param print_only [Boolean] print the link and open nothing
      # @return [Result]
      # @raise [Workspace::UsageError] see {#url_for}
      # @raise [Workspace::Error] see {#url_for}
      def open(view:, workspace: nil, pane: nil, path: nil, print_only: false)
        url = url_for(view: view, workspace: workspace, pane: pane, path: path)
        if print_only
          @output.puts url
          return Result.new("printed", view, url)
        end

        _out, err, status = @opener.call(["open", url])
        if status.success?
          @output.puts "Opened #{url}"
          Result.new("opened", view, url)
        else
          detail = err.to_s.strip.lines.first&.strip
          detail ||= "open exited #{status.exitstatus} for #{url}"
          Result.new("failed", view, url, "open_failed", "#{detail} (Is the workspace UI app installed? Use --print to see the link.)")
        end
      rescue SystemCallError => e
        Result.new("failed", view, url, "open_unavailable", "Could not run open: #{e.message}")
      end

      # Asks macOS, read-only, which app would take a link and which copies run.
      # Opens nothing and runs no `open`; no answer is a fact, not an error.
      #
      # @return [Hash] `running`, `pids`, `handler` (`path`, `id`, `version`), `links` (`revision`, `reason`),
      #   `probe` and `warnings`; `running`, `pids` and `handler` are nil and `probe` names the problem
      #   (`timed_out`, `unavailable`, `bad_answer`) when the probe cannot answer
      def status
        answer = @app_probe.call
        handler = answer.handler
        running = answer.running
        {
          "running" => answer.problem ? nil : running.any?,
          "pids" => answer.problem ? nil : running.map(&:pid),
          "handler" => handler && {"path" => handler.path, "id" => handler.id, "version" => handler.version},
          "links" => links(answer),
          "probe" => answer.problem&.to_s,
          "warnings" => []
        }
      end

      # The three plain lines of `ui status`, values read from macOS escaped.
      #
      # @param doc [Hash] the answer of {#status}
      # @return [Array<String>]
      def status_lines(doc)
        pids = doc["pids"]
        handler = doc["handler"]
        links = doc["links"]
        running = if pids.nil? then "unknown (#{safe(doc["probe"])})"
        elsif pids.empty? then "no"
        else "yes (pid #{pids.join(", ")})"
        end
        handler_line = if doc["probe"] then "unknown"
        elsif handler.nil? then "none (no app takes workspace-ui:// links)"
        else [safe(handler["path"] || "unknown path"), "(#{[handler["id"], handler["version"]].compact.map { |v| safe(v) }.join(" ")})"].join(" ")
        end
        links_line = links["revision"] ? "revision #{links["revision"]}" : "no revision (#{links["reason"]})"
        ["running: #{running}", "handler: #{handler_line}", "links: #{links_line}"]
      end

      private

      def checked_note(workspace, path)
        NotePath.resolve(path, @notes.info(name: workspace)["dir"])
        NotePath.segments(path)
      rescue NotePath::Refused => e
        raise Error.new("Invalid note path: #{e.reason}. Paths are relative to the notes directory; run 'workspace notes dir --name #{workspace}' to see it.", code: "invalid_note_path",
          details: {"workspace" => workspace, "path" => path.to_s[0, 200], "reason" => e.reason})
      end

      def safe(value)
        TerminalText.escape(value)
      end

      def links(answer)
        reason = link_reason(answer)
        {"revision" => reason ? nil : answer.handler.link_revision, "reason" => reason}
      end

      def link_reason(answer)
        handler = answer.handler
        return "probe_failed" if answer.problem
        return "no_handler" unless handler
        return "foreign_handler" unless handler.id == UiAppProbe::BUNDLE_ID
        bundle = real_path(handler.path)
        plist = bundle && plist_mtime(handler.path)
        return "handler_unreadable" unless plist
        running = answer.running
        return "handler_differs" if running.any? { |copy| real_path(copy.path) != bundle }
        return "launch_unknown" if running.any? { |copy| copy.launched_at.nil? }
        return "app_older_than_bundle" if running.any? { |copy| copy.launched_at < plist }
        "not_declared" unless handler.link_revision
      end

      def real_path(path)
        File.realpath(path) if path
      rescue SystemCallError
        nil
      end

      def plist_mtime(bundle_path)
        File.mtime(File.join(bundle_path, "Contents", "Info.plist"))
      rescue SystemCallError
        nil
      end

      def valid_name?(name)
        name.length <= MAX_NAME_LENGTH && !name.match?(/[[:cntrl:]]/)
      end
    end
  end
end
