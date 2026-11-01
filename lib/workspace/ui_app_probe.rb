require "json"

module Workspace
  # The one read-only question `ui status` puts to macOS: which app would take
  # a `workspace-ui://` link, and which copies of the app are running. It opens
  # nothing and launches nothing; the script only reads from NSWorkspace,
  # NSRunningApplication and the handler's Info.plist.
  #
  # No answer is a fact, not an error: the struct's +problem+ says why.
  class UiAppProbe
    # The bundle id of the shipped app (a dev run is Electron's and gets no links).
    BUNDLE_ID = "com.zdennis.workspace-ui"

    # The URL macOS is asked about. Never opened.
    PROBE_URL = "workspace-ui://inbox"

    # The integer Info.plist key with which an app declares the links it takes.
    LINK_REVISION_KEY = "WorkspaceUILinkRevision"

    # Launch times outside this range (epoch seconds) read as unknown.
    LAUNCH_RANGE = (1..4_102_444_800)

    # The JXA source. A frozen constant: no input is ever interpolated. Its
    # value (not console.log, which writes to stderr) is the JSON answer.
    SCRIPT = <<~JS.freeze
      ObjC.import("AppKit");
      (function () {
        var url = $.NSURL.URLWithString(#{PROBE_URL.to_json});
        var handlerUrl = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(url);
        var handler = null;
        if (handlerUrl && !handlerUrl.isNil()) {
          var bundle = $.NSBundle.bundleWithURL(handlerUrl);
          var info = function (key) {
            if (!bundle || bundle.isNil()) { return null; }
            var value = bundle.objectForInfoDictionaryKey(key);
            return (value && !value.isNil()) ? ObjC.deepUnwrap(value) : null;
          };
          handler = {
            path: ObjC.unwrap(handlerUrl.path),
            id: info("CFBundleIdentifier"),
            version: info("CFBundleShortVersionString"),
            rev: info(#{LINK_REVISION_KEY.to_json})
          };
        }
        var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(#{BUNDLE_ID.to_json});
        var running = [];
        for (var i = 0; i < apps.count; i++) {
          var app = apps.objectAtIndex(i);
          var bundleUrl = app.bundleURL;
          var launched = app.launchDate;
          running.push({
            pid: app.processIdentifier,
            path: (bundleUrl && !bundleUrl.isNil()) ? ObjC.unwrap(bundleUrl.path) : null,
            launched: (launched && !launched.isNil()) ? launched.timeIntervalSince1970 : null
          });
        }
        return JSON.stringify({handler: handler, running: running});
      })()
    JS

    # A handler app. +link_revision+ is a positive Integer or nil.
    Handler = Struct.new(:path, :id, :version, :link_revision)

    # A running copy. +launched_at+ is a Time or nil (LaunchServices did not start it).
    Running = Struct.new(:pid, :path, :launched_at)

    # +handler+ is a Handler or nil; +running+ is an Array of Running;
    # +problem+ is nil, :timed_out, :unavailable or :bad_answer. With a problem
    # +handler+ is nil and +running+ is empty.
    Answer = Struct.new(:handler, :running, :problem)

    # @param osascript [#call] an OsascriptRunner running `osascript -l JavaScript`
    def initialize(osascript:)
      @osascript = osascript
    end

    # @return [Answer]
    def call
      result = @osascript.call(SCRIPT)
      return failed(:timed_out) if result.timed_out?
      return failed(:unavailable) unless result.success?
      text = result.stdout.to_s.strip
      return failed(:unavailable) if text.empty?
      parse(text)
    end

    private

    def parse(text)
      data = JSON.parse(text)
      return failed(:bad_answer) unless data.is_a?(Hash) && data["running"].is_a?(Array)
      return failed(:bad_answer) unless data["handler"].nil? || data["handler"].is_a?(Hash)
      Answer.new(handler(data["handler"]), data["running"].filter_map { |row| running(row) }, nil)
    rescue JSON::ParserError
      failed(:bad_answer)
    end

    def handler(row)
      return nil unless row
      Handler.new(path(row["path"]), string(row["id"]), string(row["version"]), revision(row["rev"]))
    end

    def running(row)
      return nil unless row.is_a?(Hash) && row["pid"].is_a?(Integer) && row["pid"].positive?
      Running.new(row["pid"], path(row["path"]), launched_at(row["launched"]))
    end

    def string(value)
      (value.is_a?(String) && !value.empty? && !value.match?(/[[:cntrl:]]/)) ? value : nil
    end

    def path(value)
      text = string(value)
      text if text&.start_with?("/")
    end

    def revision(value)
      (value.is_a?(Integer) && value.positive?) ? value : nil
    end

    def launched_at(value)
      (value.is_a?(Numeric) && LAUNCH_RANGE.cover?(value)) ? Time.at(value) : nil
    end

    def failed(problem)
      Answer.new(nil, [], problem)
    end
  end
end
