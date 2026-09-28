module Workspace
  # Decides whether `launch`, `start` and `doctor` run headless: plain tmux
  # sessions started in the background, with no iTerm2, AppleScript or
  # window-tool involved.
  #
  # The first rule that applies wins:
  #
  # 1. an explicit `--headless` / `--no-headless` flag
  # 2. the global `launch.headless` config key (`true` or `false`)
  # 3. headless when this isn't macOS, when `osascript` isn't on PATH, or
  #    when the `CI` environment variable is set to anything but `false`/`0`
  # 4. otherwise iTerm2
  class LaunchMode
    # The outcome of {#resolve}: whether to run headless, and which rule said so.
    Decision = Struct.new(:headless, :reason, keyword_init: true) do
      # @return [Boolean]
      def headless? = headless
    end

    # Values the `launch.headless` config key accepts.
    CONFIG_VALUES = %w[true false].freeze

    # @param value [String]
    # @return [String] the value, when it is "true" or "false"
    # @raise [ArgumentError] for anything else
    def self.parse_config(value)
      return value if CONFIG_VALUES.include?(value.to_s)
      raise ArgumentError, "must be \"true\" or \"false\""
    end

    # @param project_settings [Workspace::ProjectSettings] reads the global `launch.headless` key
    # @param which [#call] returns true when an executable is on PATH
    # @param platform [String] the Ruby platform string, e.g. RUBY_PLATFORM
    # @param env [Hash{String => String}] the environment to read `CI` from
    def initialize(project_settings:, which: nil, platform: RUBY_PLATFORM, env: ENV)
      @project_settings = project_settings
      @which = which || Workspace::Which
      @platform = platform
      @env = env
    end

    # @param explicit [Boolean, nil] the `--[no-]headless` flag, or nil when not given
    # @return [Decision]
    def resolve(explicit = nil)
      return Decision.new(headless: explicit, reason: explicit ? "--headless" : "--no-headless") unless explicit.nil?

      configured = @project_settings.load_global.dig("launch", "headless")
      unless configured.nil?
        return Decision.new(headless: configured.to_s == "true", reason: "launch.headless is #{configured}")
      end

      return Decision.new(headless: true, reason: "not macOS") unless @platform.to_s.include?("darwin")
      return Decision.new(headless: true, reason: "osascript not found") unless @which.call("osascript")

      ci = @env["CI"]
      if ci && !ci.empty? && !%w[false 0].include?(ci.downcase)
        return Decision.new(headless: true, reason: "CI is set")
      end

      Decision.new(headless: false, reason: "iTerm2")
    end
  end
end
