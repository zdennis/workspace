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
      VIEWS = {"task" => true, "review" => true, "inbox" => false}.freeze

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

      # @param opener [#call] `(argv)` runs the command and returns `[stdout, stderr, status]`;
      #   raises SystemCallError when the executable is missing
      # @param output [IO]
      def initialize(opener: ->(argv) { Open3.capture3(*argv) }, output: $stdout)
        @opener = opener
        @output = output
      end

      # @param view [String] one of {VIEWS}
      # @param workspace [String, nil] required for task and review, refused for inbox
      # @return [String] the deep link, with the workspace percent-encoded
      # @raise [Workspace::UsageError] for an unknown view or a workspace that doesn't fit the view
      def url_for(view:, workspace: nil)
        raise UsageError, "Unknown view '#{view}': one of #{VIEWS.keys.join(", ")}. Run 'workspace ui --help'." unless VIEWS.key?(view)

        if VIEWS.fetch(view)
          raise UsageError, "#{view} needs a workspace." if workspace.to_s.strip.empty?
          unless valid_name?(workspace)
            raise UsageError, "'#{workspace.to_s[0, 40].inspect[1..-2]}' is not a valid workspace name."
          end
          "#{SCHEME}://#{view}/#{ERB::Util.url_encode(workspace)}"
        else
          raise UsageError, "#{view} takes no workspace." if workspace
          "#{SCHEME}://#{view}"
        end
      end

      # Opens the link with `open`, or only prints it.
      #
      # @param view [String] one of {VIEWS}
      # @param workspace [String, nil]
      # @param print_only [Boolean] print the link and open nothing
      # @return [Result]
      # @raise [Workspace::UsageError] see {#url_for}
      def open(view:, workspace: nil, print_only: false)
        url = url_for(view: view, workspace: workspace)
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

      private

      def valid_name?(name)
        name.length <= MAX_NAME_LENGTH && !name.match?(/[[:cntrl:]]/)
      end
    end
  end
end
