module Workspace
  # The one table of config keys: where each lives (project or global file),
  # whether `workspace config set` may write it, its default, how its value is
  # parsed and checked, and the description the docs are generated from.
  #
  # The readers ({DevConfig}, {LockConfig}, {AlertConfig}, {HandoffConfig},
  # {LaunchMode}), `workspace config set/get/unset` and the generated tables in
  # docs/README.config.md (see {ConfigSchemaDocs}) all take their key list,
  # defaults and value checks from here, so they can't disagree. Readers keep
  # their own handling of a bad stored value (warn and use the default, or
  # raise); the schema only says what a valid value is.
  module ConfigSchema
    # Largest accepted `dev.kill_grace`, in seconds.
    MAX_KILL_GRACE = 60

    # Smallest and largest accepted `locks.ps_timeout`, in seconds. Below the
    # minimum, `ps` times out on nearly every call, so liveness checks come
    # back unknown (treated as alive) and a lock queue can stall behind a
    # clearing marker that never gets to show dead.
    MIN_PS_TIMEOUT = 1
    MAX_PS_TIMEOUT = 60

    # Values the `context.source` key accepts.
    CONTEXT_SOURCES = %w[statusline scrape].freeze

    # Values the `launch.headless` key accepts.
    LAUNCH_HEADLESS_VALUES = %w[true false].freeze

    # One config key.
    #
    # @!attribute name [String] dotted key, e.g. "dev.ready_timeout"
    # @!attribute scope [Symbol] :project or :global, the file the key lives in
    # @!attribute doc [String] one-line description, rendered into the docs
    # @!attribute default [Object, nil] what a reader uses when the key is unset
    # @!attribute restart [Boolean] true when a running session-monitor daemon only reads it at startup
    # @!attribute settable [Boolean] true when `config set/get/unset` accept it
    # @!attribute parser [#call, nil] returns the parsed value or raises ArgumentError/RegexpError
    # @!attribute resolve [Symbol] whose file the readers consult: :parent (the parent project's file, even from a
    #   worktree), :own (the workspace's own file), :merge (global, then the workspace's own), :global (the global
    #   file) or :none (no reader reads it). Defaults to :global for a global key, else :parent.
    # @!attribute applies [Symbol] when a change takes effect: :next_call, :next_event or :daemon_restart.
    #   Defaults to :daemon_restart for a restart key, else :next_call.
    # @!attribute sensitive [Boolean] true when the value is a command or other text `config show --json` must not print
    # @!attribute type [Symbol] :command, :duration, :percent, :text, :enum, :regex, :boolean or :mapping
    Key = Struct.new(:name, :scope, :doc, :default, :restart, :settable, :parser, :resolve, :applies, :sensitive, :type, keyword_init: true) do
      def initialize(scope:, restart: nil, resolve: nil, applies: nil, sensitive: false, type: :text, **rest)
        resolve ||= (scope == :global) ? :global : :parent
        applies ||= restart ? :daemon_restart : :next_call
        super
      end

      # @return [Boolean]
      def settable? = settable

      # @return [Boolean]
      def global? = scope == :global

      # @return [Boolean]
      def restart_required? = restart

      # @param value [Object] a stored or user-supplied value
      # @return [Object] the parsed value; the value itself for a free-text key
      # @raise [ArgumentError, RegexpError] if the value isn't valid for this key
      def parse(value)
        parser ? parser.call(value) : value
      end
    end

    # Counts capturing groups (named and unnamed) in a regex source by
    # walking it character by character, skipping escaped characters and
    # character-class bodies (`[(]` isn't a group), and recognizing named
    # groups (`(?<name>`, `(?'name'`) while excluding lookaround
    # (`(?=`, `(?!`, `(?<=`, `(?<!`) and non-capturing groups (`(?:`).
    # Good enough for validating a config value; not a full regex parser.
    #
    # @param pattern [String] regex source
    # @return [Integer]
    def self.capture_group_count(pattern)
      count = 0
      in_class = false
      i = 0
      chars = pattern.chars
      while i < chars.size
        c = chars[i]
        if c == "\\"
          i += 2
          next
        end
        if in_class
          in_class = false if c == "]"
          i += 1
          next
        end
        case c
        when "["
          in_class = true
        when "("
          if chars[i + 1] == "?"
            nxt = chars[i + 2]
            if nxt == "<" && !["=", "!"].include?(chars[i + 3])
              count += 1 # named group (?<name>...)
            elsif nxt == "'"
              count += 1 # named group (?'name'...)
            end
            # else: non-capturing (?:...) or lookaround (?=/?!/?<=/?<!), not counted
          else
            count += 1 # unnamed capturing group
          end
        end
        i += 1
      end
      count
    end

    DURATION = ->(value) { Duration.parse(value) }
    POSITIVE_DURATION = ->(value) { Duration.parse_positive(value) }
    private_constant :DURATION, :POSITIVE_DURATION

    COMMAND = lambda do |value|
      command = value.to_s.strip
      raise ArgumentError, "must not be blank" if command.empty?
      command
    end
    private_constant :COMMAND

    PROMPT = lambda do |value|
      text = value.to_s
      raise ArgumentError, "must not be blank" if text.strip.empty?
      text
    end
    private_constant :PROMPT

    PERCENT = lambda do |value|
      pct = Integer(value)
      raise ArgumentError, "must be between 1 and 100" unless pct.between?(1, 100)
      pct
    rescue ArgumentError, TypeError
      raise ArgumentError, "must be an integer between 1 and 100"
    end
    private_constant :PERCENT

    CONTEXT_SOURCE = lambda do |value|
      raise ArgumentError, "must be \"statusline\" or \"scrape\"" unless CONTEXT_SOURCES.include?(value)
      value
    end
    private_constant :CONTEXT_SOURCE

    ONE_GROUP_REGEX = lambda do |value|
      Regexp.new(value)
      raise ArgumentError, "must have exactly one capture group" unless capture_group_count(value) == 1
      value
    end
    private_constant :ONE_GROUP_REGEX

    HEADLESS = lambda do |value|
      return value if LAUNCH_HEADLESS_VALUES.include?(value.to_s)
      raise ArgumentError, "must be \"true\" or \"false\""
    end
    private_constant :HEADLESS

    # The instruction packs every composed set of instructions starts with, unless `workflows.defaults.include` names others.
    DEFAULT_PACKS = %w[binding orchestrator commits].freeze

    PACK_LIST = lambda do |value|
      names = value.is_a?(Array) ? value : value.to_s.split(/[\s,]+/).reject(&:empty?)
      unless names.any? && names.all? { |name| name.is_a?(String) && name.match?(%r{\A(?:play/)?[a-z0-9][a-z0-9-]*\z}) }
        raise ArgumentError, "must be one or more pack names separated by commas, e.g. \"binding, commits\""
      end
      names
    end
    private_constant :PACK_LIST

    # Every key, settable ones first in the order `config set` lists them,
    # then keys that are documented but edited by hand.
    KEYS = [
      Key.new(name: "dev.up", scope: :project, type: :command, sensitive: true, settable: true, doc: "Command that starts the project's dev environment"),
      Key.new(name: "dev.ready", scope: :project, type: :command, sensitive: true, settable: true, doc: "Readiness probe for the dev environment"),
      Key.new(name: "dev.stop_timeout", scope: :project, type: :duration, settable: true, default: 20, parser: DURATION,
        doc: "Grace period before force-stopping the dev environment, e.g. `20s` or `20`"),
      Key.new(name: "dev.startup_timeout", scope: :project, type: :duration, settable: true, default: 30, parser: POSITIVE_DURATION,
        doc: "How long `dev up` waits for the wrapper to take a free lock, e.g. `30s` (default `30s`)"),
      Key.new(name: "dev.ready_timeout", scope: :project, type: :duration, settable: true, default: 120, parser: POSITIVE_DURATION,
        doc: "How long `dev up` waits for the `dev.ready` check to pass, e.g. `2m` (default `120s`)"),
      Key.new(name: "dev.kill_grace", scope: :project, type: :duration, settable: true, default: 2,
        parser: ->(value) { Duration.parse_capped(value, max: MAX_KILL_GRACE) },
        doc: "How long `lock clear devenv`, `dev down` and `dev up --force` wait for a SIGKILLed dev environment's process group to disappear before keeping its lock (default `2s`, capped at `60s`)"),
      Key.new(name: "locks.idle_grace", scope: :project, type: :duration, settable: true, default: 300, parser: POSITIVE_DURATION,
        doc: "How long an idle agent keeps a lock before the first waiter may take it over (default `5m`; see [`workspace lock`](README.lock.md))"),
      Key.new(name: "locks.ps_timeout", scope: :project, type: :duration, settable: true, default: 5, restart: true,
        parser: ->(value) { Duration.parse_ranged(value, min: MIN_PS_TIMEOUT, max: MAX_PS_TIMEOUT) },
        doc: "How long to wait for `ps` when reading the process table for lock/session checks, before giving up (default `5s`, must be between `1s` and `60s`)"),
      Key.new(name: "locks.reap_interval", scope: :project, type: :duration, settable: true, default: 30, restart: true, parser: POSITIVE_DURATION,
        doc: "How often the session-monitor daemon sweeps for stale lock holders and waiters (default `30s`)"),
      Key.new(name: "alerts.notify", scope: :project, type: :command, sensitive: true, settable: true, restart: true, parser: COMMAND,
        doc: "Command the session-monitor daemon runs when an agent pane starts waiting on a person or stays idle past `alerts.idle_after` (unset: no alerts; see [`workspace sessions`](README.sessions.md#alerts))"),
      Key.new(name: "alerts.idle_after", scope: :project, type: :duration, settable: true, default: 600, restart: true, parser: POSITIVE_DURATION,
        doc: "How long an agent pane may sit idle before `alerts.notify` runs (default `10m`)"),
      Key.new(name: "agentd.poll_interval", scope: :project, type: :duration, settable: true, default: 10, restart: true, parser: POSITIVE_DURATION,
        doc: "How often the session-monitor daemon scans panes for agent state, alerts and stale locks (default `10s`)"),
      Key.new(name: "handoff.threshold", scope: :project, type: :percent, settable: true, default: 11, parser: PERCENT,
        doc: "Context-usage percent, 1 to 100, that triggers a handoff in [`workspace handoff check`](README.handoff.md) (default `11`)"),
      Key.new(name: "handoff.check_prompt", scope: :project, settable: true, parser: PROMPT,
        doc: "Overrides the built-in save-state prompt `handoff check --handoff-doc` sends; must not be blank (see [`workspace handoff`](README.handoff.md))"),
      Key.new(name: "handoff.resume_prompt", scope: :project, settable: true, parser: PROMPT,
        doc: "Overrides the built-in resume prompt `handoff new` sends; must not be blank (see [`workspace handoff`](README.handoff.md))"),
      Key.new(name: "commands.test", scope: :project, type: :command, sensitive: true, settable: true, parser: COMMAND,
        doc: "Command that runs the project's tests, e.g. `bundle exec rspec`; [`workspace instructions compose`](README.instructions.md) names it in the `commits` pack"),
      Key.new(name: "commands.lint", scope: :project, type: :command, sensitive: true, settable: true, parser: COMMAND,
        doc: "Command that lints the project, e.g. `bundle exec standardrb lib/ spec/`; named in the `commits` pack beside `commands.test`"),
      Key.new(name: "statusline.command", scope: :global, type: :command, sensitive: true, settable: true,
        doc: "Delegates [`workspace statusline`](README.statusline.md) rendering to another command instead of the built-in renderer"),
      Key.new(name: "context.source", scope: :global, type: :enum, settable: true, parser: CONTEXT_SOURCE,
        doc: "`statusline` (default) or `scrape` — where `workspace sessions` reads a pane's context usage; see [`workspace statusline`](README.statusline.md)"),
      Key.new(name: "context.pattern", scope: :global, type: :regex, settable: true, parser: ONE_GROUP_REGEX,
        doc: "Regex with exactly one capture group, used when `context.source` is `scrape`"),
      Key.new(name: "launch.headless", scope: :global, type: :boolean, settable: true, parser: HEADLESS,
        doc: "`true` or `false`: whether `launch`, `start` and `doctor` run [headless](README.launch.md#headless) on this machine when no `--headless`/`--no-headless` flag is given. Unset, they pick headless off macOS, without `osascript`, or when `CI` is set"),
      Key.new(name: "workflows.defaults.include", scope: :global, type: :text, settable: true, default: DEFAULT_PACKS, parser: PACK_LIST,
        doc: "Instruction packs every workflow step and [`workspace instructions compose`](README.instructions.md) start with, " \
          "as names separated by commas (default `binding, orchestrator, commits`)"),
      Key.new(name: "hooks", scope: :global, type: :mapping, sensitive: true, resolve: :none, settable: false, doc: "Global hooks applied to all projects"),
      Key.new(name: "layouts", scope: :global, type: :mapping, resolve: :merge, settable: false, doc: "Default tmux pane layouts"),
      Key.new(name: "event_log_compact_threshold", scope: :global, type: :text, settable: false,
        doc: "Size warning threshold (e.g., \"10kb\", \"1mb\"). Default: 1mb"),
      Key.new(name: "hooks", scope: :project, type: :mapping, sensitive: true, resolve: :own, applies: :next_event, settable: false, doc: "Project-specific hooks (e.g., `post_launch`)"),
      Key.new(name: "layouts", scope: :project, type: :mapping, resolve: :merge, settable: false, doc: "Project-specific tmux pane layouts"),
      Key.new(name: "worktree_hooks", scope: :project, type: :mapping, sensitive: true, settable: false, doc: "Hooks seeded into new worktrees created from this project"),
      Key.new(name: "pipeline", scope: :project, settable: false, type: :mapping, sensitive: true, resolve: :own, applies: :daemon_restart,
        doc: "Deprecated (use [`workspace workflow`](README.workflow.md)): pipeline stages (`pipeline.panes`: role, timeout) the agent daemon dispatches work through")
    ].each(&:freeze).freeze

    # @return [Array<Key>] every key
    def self.all = KEYS

    # @return [Array<Key>] keys `config set/get/unset` accept
    def self.settable = KEYS.select(&:settable?)

    # @return [Array<Key>] settable keys written to a project's config
    def self.project_keys = settable.reject(&:global?)

    # @return [Array<Key>] settable keys written to the global config
    def self.global_keys = settable.select(&:global?)

    # @return [Array<String>] settable key names, project keys first
    def self.settable_names = settable.map(&:name)

    # @return [Array<String>] settable keys a running daemon only reads at startup
    def self.restart_required_names = settable.select(&:restart_required?).map(&:name)

    # `hooks` and `layouts` are declared under both scopes, so a caller that
    # knows which file it is reading passes the scope.
    #
    # @param name [String] dotted key
    # @param scope [Symbol, nil] :project or :global to pick that scope's key; nil for either
    # @return [Key, nil] the key, preferring a settable one
    def self.key(name, scope: nil)
      candidates = KEYS.select { |key| key.name == name && (scope.nil? || key.scope == scope) }
      candidates.find(&:settable?) || candidates.first
    end

    # @param name [String] dotted key
    # @return [Boolean] true when `config set/get/unset` accept it
    def self.settable?(name) = settable.any? { |key| key.name == name }

    # @param name [String] a declared key
    # @return [Object, nil] its default
    def self.default(name) = fetch(name).default

    # @param name [String] a declared key
    # @param value [Object] a stored or user-supplied value
    # @return [Object] the parsed value
    # @raise [ArgumentError, RegexpError] if the value isn't valid for the key
    def self.parse(name, value) = fetch(name).parse(value)

    def self.fetch(name)
      key(name) or raise KeyError, "undeclared config key #{name.inspect}"
    end
    private_class_method :fetch
  end
end
