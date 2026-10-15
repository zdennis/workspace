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

    # The layers a key may live in for each `resolve` mode, as the readers consult them today.
    LEGACY_LAYERS = {
      global: [:global].freeze,
      parent: [:project].freeze,
      own_then_parent: [:project, :worktree].freeze,
      own: [:project, :worktree].freeze,
      merge: [:project, :worktree].freeze,
      none: [].freeze
    }.freeze
    private_constant :LEGACY_LAYERS

    # The values a key of that type accepts, when the type is a closed set.
    DEFAULT_CHOICES = {enum: CONTEXT_SOURCES, boolean: %w[true false].freeze}.freeze
    private_constant :DEFAULT_CHOICES

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
    #   worktree), :own (the workspace's own file), :own_then_parent (a worktree's own file and never the project's,
    #   where a main checkout reads the project's file), :merge (global, then the workspace's own), :global (the global
    #   file) or :none (no reader reads it). Defaults to :global for a global key, else :parent.
    # @!attribute applies [Symbol] when a change takes effect: :next_call, :next_event or :daemon_restart.
    #   Defaults to :daemon_restart for a restart key, else :next_call.
    # @!attribute sensitive [Boolean] true when the value is a command or other text `config show --json` must not print
    # @!attribute type [Symbol] :command, :duration, :percent, :text, :path, :enum, :regex, :boolean or :mapping.
    #   A :path value is a file system location a person may have typed with shell escapes, which `config validate` checks for.
    # @!attribute overridable_in [Array<Symbol>] the layers (:global, :project, :worktree) that may hold the key, lowest
    #   precedence first. Defaults from `resolve` to what the readers consult today: :global is [:global], :parent is
    #   [:project], :own_then_parent is [:project, :worktree]; :own and :merge are [:project, :worktree] for information
    #   (their readers are unchanged) and :none is [].
    # @!attribute choices [Array<String>, nil] the accepted values of a closed set; defaults to {CONTEXT_SOURCES} for an
    #   :enum key and "true"/"false" for a :boolean one
    # @!attribute min [Numeric, nil] smallest accepted value, in `unit`
    # @!attribute max [Numeric, nil] largest accepted value, in `unit`
    # @!attribute unit [String, nil] "seconds" for every :duration key
    Key = Struct.new(:name, :scope, :doc, :default, :restart, :settable, :parser, :resolve, :applies, :sensitive, :type,
      :overridable_in, :choices, :min, :max, :unit, keyword_init: true) do
      def initialize(scope:, restart: nil, resolve: nil, applies: nil, sensitive: false, type: :text,
        overridable_in: nil, choices: nil, unit: nil, **rest)
        resolve ||= (scope == :global) ? :global : :parent
        applies ||= restart ? :daemon_restart : :next_call
        overridable_in ||= LEGACY_LAYERS.fetch(resolve)
        choices ||= DEFAULT_CHOICES[type]
        unit ||= "seconds" if type == :duration
        super
      end

      # @param layer [Symbol, String] :global, :project or :worktree
      # @return [Boolean] whether the key may be set in that layer
      def overridable_in?(layer) = overridable_in.include?(layer.to_sym)

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

    # The save-state prompt `handoff check` sends when it names a doc. `%{usage}`,
    # `%{doc}` and `%{new_cmd}` are filled in by the command.
    HANDOFF_CHECK_PROMPT = <<~PROMPT.strip.freeze
      %{usage} Update %{doc} now with
      everything needed to continue this work: current state, next steps, and the
      process/workflow for picking it back up in a fresh session (a "Start here" section
      with a single paste-able prompt). Commit it if appropriate. Then run this exact
      command yourself: %{new_cmd}
    PROMPT

    # The prompt `handoff new` resumes a fresh conversation with. `%{doc}` is the doc's path.
    HANDOFF_RESUME_PROMPT = <<~PROMPT.strip.freeze
      Read %{doc} and follow its "Start here" instructions. Act strictly
      as an orchestrator: delegate the actual work to sub-agents rather than doing it
      yourself.
    PROMPT

    ABSOLUTE_PATH = lambda do |value|
      path = value.to_s
      raise ArgumentError, "must not be blank" if path.strip.empty?
      raise ArgumentError, "has leading or trailing whitespace; remove it" unless path == path.strip
      raise ArgumentError, "must not contain a newline or other control character" if path.match?(/[[:cntrl:]]/)
      raise ArgumentError, "must be an absolute path starting with \"/\"; a literal \"~\" is not expanded, so write out the home directory" unless path.start_with?("/")
      path
    end
    private_constant :ABSOLUTE_PATH

    # Placeholders `notes.default_dir` fills in for each workspace.
    NOTES_PLACEHOLDERS = %w[workspace branch].freeze

    NOTES_DEFAULT_DIR = lambda do |value|
      path = value.to_s
      raise ArgumentError, "must not be blank" if path.strip.empty?
      raise ArgumentError, "has leading or trailing whitespace; remove it" unless path == path.strip
      raise ArgumentError, "must not contain a newline or other control character" if path.match?(/[[:cntrl:]]/)
      raise ArgumentError, "has an unbalanced brace; write placeholders as {workspace} or {branch}" if path.count("{") != path.count("}") || path.gsub(/\{[^{}]*\}/, "").match?(/[{}]/)
      raise ArgumentError, "must name a directory for notes, not the worktree root, the home directory or \"/\"" if %w[. ./ ~/ /].include?(path)
      unknown = path.scan(/{([^{}]*)}/).flatten.reject { |name| NOTES_PLACEHOLDERS.include?(name) }
      raise ArgumentError, "has an unknown placeholder {#{unknown.first}}; use {workspace} or {branch}" if unknown.any?
      if path.start_with?("~") && !path.start_with?("~/")
        raise ArgumentError, "must start with \"~/\" to mean the home directory; \"~user\" and a bare \"~\" are not expanded"
      end
      if !path.start_with?("/", "~/") && path.split("/").include?("..")
        raise ArgumentError, "a path relative to the worktree must not contain \"..\"; use an absolute path to leave the worktree"
      end
      path
    end
    private_constant :NOTES_DEFAULT_DIR

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

    BOOLEAN = lambda do |value|
      return value.to_s if %w[true false].include?(value.to_s)
      raise ArgumentError, "must be \"true\" or \"false\""
    end
    private_constant :BOOLEAN

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
      Key.new(name: "dev.kill_grace", scope: :project, type: :duration, settable: true, default: 2, max: MAX_KILL_GRACE,
        parser: ->(value) { Duration.parse_capped(value, max: MAX_KILL_GRACE) },
        doc: "How long `lock clear devenv`, `dev down` and `dev up --force` wait for a SIGKILLed dev environment's process group to disappear before keeping its lock (default `2s`, capped at `60s`)"),
      Key.new(name: "dev.release_on_session_end", scope: :project, type: :boolean, settable: true, default: true, parser: BOOLEAN,
        doc: "`true` or `false`: whether the dev environment a coding agent started with `dev up` is stopped when that agent's session ends (default `true`). A `/clear` never stops it. `false` leaves it running until `dev down`"),
      Key.new(name: "dev.instructions", scope: :project, type: :boolean, settable: true, default: true, parser: BOOLEAN,
        doc: "`true` or `false`: whether `start` and `launch` send the agent the built-in `dev` pack (queue for the shared dev environment before testing, release it when done) when the project sets `dev.up` (default `true`); `--no-packs` skips it for one run. A workflow step that declares `uses: [devenv]` never gets it"),
      Key.new(name: "locks.idle_grace", scope: :project, type: :duration, settable: true, default: 300, parser: POSITIVE_DURATION,
        doc: "How long an idle agent keeps a lock before the first waiter may take it over (default `5m`; see [`workspace lock`](README.lock.md))"),
      Key.new(name: "locks.ps_timeout", scope: :project, type: :duration, settable: true, default: 5, restart: true, min: MIN_PS_TIMEOUT, max: MAX_PS_TIMEOUT,
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
      Key.new(name: "handoff.threshold", scope: :project, type: :percent, settable: true, default: 11, min: 1, max: 100, parser: PERCENT,
        doc: "Context-usage percent, 1 to 100, that triggers a handoff in [`workspace handoff check`](README.handoff.md) (default `11`)"),
      Key.new(name: "handoff.check_prompt", scope: :project, settable: true, default: HANDOFF_CHECK_PROMPT, parser: PROMPT,
        doc: "Overrides the built-in save-state prompt `handoff check` sends when it names a doc (the default is that text); must not be blank (see [`workspace handoff`](README.handoff.md))"),
      Key.new(name: "handoff.resume_prompt", scope: :project, settable: true, default: HANDOFF_RESUME_PROMPT, parser: PROMPT,
        doc: "Overrides the built-in resume prompt `handoff new` sends (the default is that text); must not be blank (see [`workspace handoff`](README.handoff.md))"),
      Key.new(name: "handoff.auto", scope: :project, type: :boolean, settable: true, default: false, parser: BOOLEAN,
        doc: "`true` or `false`: whether `start` and `launch` send a Claude Code agent the built-in `handoff` pack, which makes it run [`workspace handoff check`](README.handoff.md) after every task and hand off to a fresh conversation itself (default `false`); `--handoff` and `--no-handoff` override it for one run"),
      Key.new(name: "commands.test", scope: :project, type: :command, sensitive: true, settable: true, parser: COMMAND,
        doc: "Command that runs the project's tests, e.g. `bundle exec rspec`; [`workspace instructions compose`](README.instructions.md) names it in the `commits` pack"),
      Key.new(name: "commands.lint", scope: :project, type: :command, sensitive: true, settable: true, parser: COMMAND,
        doc: "Command that lints the project, e.g. `bundle exec standardrb lib/ spec/`; named in the `commits` pack beside `commands.test`"),
      Key.new(name: "notes.dir", scope: :project, type: :path, settable: true, parser: ABSOLUTE_PATH, resolve: :own_then_parent,
        doc: "Directory where one workspace's notes are kept, as an absolute path; other tools read it to know where to store notes. A worktree reads only its own value (set it with `--name`), never the project's; the main checkout reads the project's (unset: the directory `notes.default_dir` gives it)"),
      Key.new(name: "notes.default_dir", scope: :project, type: :path, settable: true, parser: NOTES_DEFAULT_DIR,
        doc: "The rule that gives each workspace its notes directory when it has no `notes.dir`: an absolute path, `~/…`, or a path relative to the worktree with no `..`; `{workspace}` and `{branch}` are filled in per workspace, so give an outside-the-repo path one or the other (unset: `tmp/workspace-notes` inside the worktree)"),
      Key.new(name: "notes.instructions", scope: :project, type: :boolean, settable: true, default: true, parser: BOOLEAN,
        doc: "`true` or `false`: whether `start` and `launch` send the agent the built-in `notes` pack (where working notes go) with its first prompt (default `true`); `--no-packs` skips it for one run"),
      Key.new(name: "plan.stall_seconds", scope: :project, type: :duration, settable: true, default: 300, parser: POSITIVE_DURATION,
        doc: "How long the agent pane that owns a workspace's plan may sit idle before [`workspace plan status`](README.plan.md) reads the plan as `stalled` (default `5m`)"),
      Key.new(name: "statusline.command", scope: :global, type: :command, sensitive: true, settable: true,
        doc: "Delegates [`workspace statusline`](README.statusline.md) rendering to another command instead of the built-in renderer"),
      Key.new(name: "context.source", scope: :global, type: :enum, settable: true, parser: CONTEXT_SOURCE,
        doc: "`statusline` (default) or `scrape` — where `workspace sessions` reads a pane's context usage; see [`workspace statusline`](README.statusline.md)"),
      Key.new(name: "context.pattern", scope: :global, type: :regex, settable: true, parser: ONE_GROUP_REGEX,
        doc: "Regex with exactly one capture group, used when `context.source` is `scrape`"),
      Key.new(name: "context.patterns", scope: :global, type: :mapping, settable: false,
        doc: "Edited in the file by hand: a mapping of agent kind (`claude`, `codex`, ...) to a regex with exactly one capture group that reads the percent of the context window used from that agent's pane. A kind listed here is read from its pane whatever `context.source` says; Codex has a built-in reading of its \"N% context left\" line. `context.pattern` stays the fallback in `scrape` mode for a kind with neither. See [`handoff`](README.handoff.md#codex)"),
      Key.new(name: "launch.headless", scope: :global, type: :boolean, settable: true, parser: HEADLESS,
        doc: "`true` or `false`: whether `launch`, `start` and `doctor` run [headless](README.launch.md#headless) on this machine when no `--headless`/`--no-headless` flag is given. Unset, they pick headless off macOS, without `osascript`, or when `CI` is set"),
      Key.new(name: "workflows.defaults.include", scope: :global, type: :text, settable: true, default: DEFAULT_PACKS, parser: PACK_LIST,
        doc: "Instruction packs every workflow step and [`workspace instructions compose`](README.instructions.md) start with, " \
          "as names separated by commas (default `binding, orchestrator, commits`)"),
      Key.new(name: "hooks", scope: :global, type: :mapping, sensitive: true, resolve: :none, settable: false, doc: "Global hooks applied to all projects"),
      Key.new(name: "layouts", scope: :global, type: :mapping, resolve: :merge, settable: false, doc: "Default tmux pane layouts"),
      Key.new(name: "event_log_compact_threshold", scope: :global, type: :text, settable: false,
        doc: "Size warning threshold (e.g., \"10kb\", \"1mb\"). Default: 1mb"),
      Key.new(name: "dev.configured", scope: :project, type: :boolean, default: false, resolve: :none, settable: false,
        doc: "Read-only, shown by `config show --json` only: `effective` is `true` when the project's `dev.up` is set, which is what makes `start` and `launch` send the `dev` pack. Not a key to write"),
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
