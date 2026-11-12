require "time"

module Workspace
  # What {SessionMonitor#snapshot} shows of each pane: the row `workspace
  # sessions --json` prints, its `display_label`, the project's task, and
  # the context and label caches the scan refreshes so a request answers
  # from them. A pane is the symbol-keyed Hash {PaneEvents.new_pane} builds;
  # the fields {PaneScanner#refresh} and {PaneEvents.apply} write are what
  # a row is made from.
  #
  # The class methods are the rules: they take a pane and plain values and
  # build new Hashes, so a row shares nothing with the pane it came from.
  # The instance holds the readers. It takes no lock: the monitor calls
  # {#present} and {#refresh} while it holds its own, and they write only
  # the pane's caches. {#task} is read outside the lock.
  class PaneView
    # How many poll intervals a scan-time cache stays fresh for a request.
    # The scan refreshes it every interval, so this only matters when a scan
    # is late or the scan thread has died — then requests fall back to
    # reading for themselves rather than serving data gone stale.
    CACHE_GRACE_INTERVALS = 3

    # Longest task title or prompt kept as a label.
    LABEL_PROMPT_LENGTH = TranscriptLabel::MAX_LENGTH

    # The snapshot document: the panes ordered by index.
    #
    # @param workspace [String] the tmux session watched
    # @param now [Time]
    # @param features [Array<String>] what this daemon can do
    # @param task [Hash, nil] the project's active task record
    # @param panes [Array<Hash>] the rows {#present} built
    # @return [Hash]
    def self.document(workspace:, now:, features:, task:, panes:)
      {
        "workspace" => workspace,
        "updated_at" => now.utc.iso8601,
        "features" => features,
        "task" => task_row(task, panes),
        "panes" => panes.sort_by { |p| p["index"] || 0 }
      }
    end

    # One pane's row. A shell pane carries no context, tool status or hook
    # mode fields; +context+ nil leaves the context fields off too.
    #
    # @param pane [Hash]
    # @param now [Time]
    # @param idle_after [Numeric] seconds of unchanged output before idle
    # @param providers [Array<AgentProvider>] the agents recognized
    # @param label [String, nil] the `display_label`
    # @param context [Hash, nil] `:pct`, `:error` and `:updated_at`
    # @return [Hash]
    def self.row(pane, now, idle_after:, providers:, label:, context:)
      idle_for = now - (pane[:last_activity_at] || now)
      wait = PaneStates.oldest_wait(pane)
      waiting_since = wait&.dig(:since)
      state = PaneStates.reported_state(pane, idle_for, idle_after)
      state_since = (state == pane[:logged_state]) ? pane[:state_since] : PaneStates.since_for(pane, state, now, idle_after)
      result = {
        "pane_id" => pane[:pane_id],
        "index" => pane[:index],
        "kind" => pane[:kind],
        "label" => pane[:label],
        "title" => pane[:title],
        "cwd" => pane[:cwd],
        "state" => state,
        "state_since" => state_since&.utc&.iso8601,
        "activity_state" => PaneStates.state_of(pane, idle_for, idle_after),
        "main_turn_over_since" => PaneStates.main_turn_missing(pane) ? nil : pane[:main_stopped_at].utc.iso8601(3),
        "transcript_path" => pane[:transcript_path],
        "open_tools" => pane[:open_tools].to_h.values.map { |tool| tool[:tool] },
        "idle_seconds" => idle_for.round,
        "waiting_since" => waiting_since&.utc&.iso8601,
        "waiting_seconds" => waiting_since && (now - waiting_since).round,
        "waiting_message" => wait&.dig(:message),
        "waiting_tool" => wait&.dig(:tool),
        "waiting_input" => wait&.dig(:input),
        "waits" => pane[:waits].map { |agent_id, w|
          {"agent_id" => agent_id, "tool" => w[:tool], "input" => w[:input], "since" => w[:since]&.utc&.iso8601}
        },
        "stop_reason" => pane[:done]&.dig(:stop_reason),
        "turn_failed" => !pane[:turn_failed].nil?,
        "session_id" => pane[:session_id],
        "display_label" => label,
        "agents" => pane[:agents].map { |agent|
          {"name" => agent[:name], "state" => agent[:state],
           "started_at" => agent[:started_at]&.utc&.iso8601,
           "ended_at" => agent[:ended_at]&.utc&.iso8601}
        }
      }
      return result if pane[:kind] == "shell"

      if context
        result["context_pct"] = context[:pct]
        result["context_error"] = context[:error]
        result["context_updated_at"] = context[:updated_at]
      end
      tool_status(result, pane)
      hook_mode(result, pane, providers)
      result
    end

    # `last_event_at`, `current_tool` (the name of the main agent's most
    # recently started tool still running, else nil), `current_tool_since`
    # and the running `subagents`. A coding-agent pane no hook has reached
    # reports nulls and an empty list.
    def self.tool_status(result, pane)
      current = pane[:open_tools]&.values&.last
      result["last_event_at"] = pane[:last_event_at]&.utc&.iso8601
      result["current_tool"] = current&.dig(:tool)
      result["current_tool_since"] = current&.dig(:since)&.utc&.iso8601
      result["subagents"] = pane[:agents].select { |a| a[:state] == "running" }.map { |agent|
        {"agent_id" => agent[:agent_id], "description" => agent[:description] || agent[:name],
         "since" => agent[:started_at]&.utc&.iso8601}
      }
    end
    private_class_method :tool_status

    # `hook_mode`: "hooks" once the daemon has had a hook event from the
    # pane's current kind of agent, "scrape" for a recognized agent it has
    # not (no hooks installed, not trusted yet, or none since a daemon
    # restart), "none" for a pane not yet identified. `hook_events`: the event
    # types that kind of agent's hooks can report, whatever the mode.
    def self.hook_mode(result, pane, providers)
      provider = providers.find { |p| p.key == pane[:kind] }
      result["hook_mode"] = if provider.nil?
        "none"
      else
        (pane[:hook_kind] == pane[:kind]) ? "hooks" : "scrape"
      end
      result["hook_events"] = provider ? provider.hook_events.dup : []
    end
    private_class_method :hook_mode

    # The task's identity plus a status derived from the coding-agent rows
    # when read, never stored: blocked when any agent waits, else working when
    # any works, else done when any has ended its turn, else idle.
    #
    # @param task [Hash, nil] the active task record
    # @param panes [Array<Hash>] the rows
    # @return [Hash, nil] nil without a task
    def self.task_row(task, panes)
      return nil unless task

      states = panes.reject { |p| p["kind"] == "shell" }.map { |p| p["state"] }
      status = %w[waiting working done].find { |s| states.include?(s) }
      {
        "id" => task["id"], "title" => task["title"], "ref" => task["ref"], "branch" => task["branch"],
        "status" => (status == "waiting") ? "blocked" : (status || "idle")
      }
    end

    # @param task [Hash, nil] the active task record
    # @return [String, nil] its title, cleaned and cut to a label's length;
    #   nil when it has no String title
    def self.task_title(task)
      title = task&.dig("title")
      title.is_a?(String) ? SessionMonitor.clean_message(title)&.slice(0, LABEL_PROMPT_LENGTH) : nil
    end

    # @param context_reader [ContextReader, nil] each coding-agent pane's
    #   context use; nil leaves the context fields off every row
    # @param label_reader [TranscriptLabel, nil] a transcript's title and last
    #   prompt; nil labels by the last prompt the daemon saw
    # @param task_reader [#call, nil] given +project+, the active task record or nil
    # @param providers [Array<AgentProvider>] the agents recognized
    # @param idle_after [Numeric] seconds of unchanged output before idle
    # @param poll_interval [Numeric] seconds between the monitor's scans
    # @param project [String] the name the task is read by
    # @param logger [Logger] where a failed read is noted
    def initialize(context_reader:, label_reader:, task_reader:, providers:, idle_after:, poll_interval:, project:, logger:)
      @context_reader = context_reader
      @label_reader = label_reader
      @task_reader = task_reader
      @providers = providers
      @idle_after = idle_after
      @poll_interval = poll_interval
      @project = project
      @logger = logger
    end

    # The project's active task, or nil. A failing reader reads as no task: the
    # snapshot must never fail over a task file.
    #
    # @return [Hash, nil]
    def task
      @task_reader&.call(@project)
    rescue => e
      @logger.debug { "session monitor: task read failed (#{e.class}: #{e.message})" }
      nil
    end

    # One pane's row, its label and context served from the caches while
    # they are fresh and read (and cached) otherwise. Called inside the
    # monitor's lock.
    #
    # @param pane [Hash]
    # @param now [Time]
    # @param task [Hash, nil] from {#task}
    # @param scanned_at [Time, nil] when the last scan ran; nil trusts no cache
    # @return [Hash] {.row}
    def present(pane, now, task, scanned_at:)
      label = display_label(pane, task, now, scanned_at)
      context = (@context_reader && pane[:kind] != "shell") ? context_reading(pane, now, scanned_at) : nil
      self.class.row(pane, now, idle_after: @idle_after, providers: @providers, label: label, context: context)
    end

    # What the scan thread calls per pane to refresh what requests read.
    # Runs under the monitor's lock like the rest of the scan, so a request
    # during a scan waits for it rather than interleaving its own captures.
    #
    # @param pane [Hash]
    # @param now [Time]
    # @return [void]
    def refresh(pane, now)
      return if pane[:kind] == "shell"

      pane[:context_cache] = {reading: read_context(pane), session_id: pane[:session_id], at: now} if @context_reader
      pane[:label_cache] = {label: read_label(pane), key: label_cache_key(pane), at: now}
    end

    private

    # What a person would call this pane: the task's title, else the transcript's
    # AI title, else the last prompt, else nil. A shell pane has none.
    #
    # The task's title is cheap to read, so it is read per request; the
    # transcript read is not, so it is served from the cache the scan thread
    # refreshes, read here only when the cache is missing, keyed to something
    # that changed (a new session, prompt or task), or past its freshness
    # grace because the scan is late.
    def display_label(pane, task, now, scanned_at)
      return nil if pane[:kind] == "shell"

      title = self.class.task_title(task)
      return title if title

      cached = pane[:label_cache]
      key = label_cache_key(pane)
      if cached && cached[:key] == key && cache_fresh?(cached, now, scanned_at)
        cached[:label]
      else
        transcript = pane[:transcript_path] && @label_reader&.read(pane[:transcript_path])
        label = transcript&.dig(:title) || pane[:last_prompt] || transcript&.dig(:last_prompt)
        pane[:label_cache] = {label: label, key: key, at: now}
        label
      end
    end

    # Everything the cached label depends on: another value for any of these
    # means the cached label describes a different session or prompt. The
    # task's title never enters it — it is read per request and comes ahead
    # of the cache.
    def label_cache_key(pane)
      [pane[:session_id], pane[:transcript_path], pane[:last_prompt]]
    end

    # A cache is fresh while the scan thread is refreshing it on schedule,
    # and no cache is trusted before the first scan. Once it goes past this
    # grace, requests read for themselves again, so a dead or stalled scan
    # thread degrades to the old per-request reads rather than serving
    # ever-staler data.
    def cache_fresh?(cached, now, scanned_at)
      scanned_at && (now - cached[:at]) <= @poll_interval * CACHE_GRACE_INTERVALS
    end

    # Reads the label uncached, for the scan thread's refresh. A failure
    # reads as no transcript label — falling back to the last prompt — so a
    # bad transcript file never ends the scan thread, which would stop all
    # monitoring.
    def read_label(pane)
      transcript = pane[:transcript_path] && @label_reader&.read(pane[:transcript_path])
      transcript&.dig(:title) || pane[:last_prompt] || transcript&.dig(:last_prompt)
    rescue => e
      @logger.debug { "session monitor: label read failed (#{e.class}: #{e.message})" }
      pane[:last_prompt]
    end

    # The pane's context reading, from the cache when fresh, read and cached
    # otherwise. A reading for another session of the same pane is stale even
    # when fresh: the reading describes that session's context window. In
    # scrape mode a read is a tmux capture of the pane, which a burst of
    # requests would otherwise multiply.
    def context_reading(pane, now, scanned_at)
      cached = pane[:context_cache]
      if cached && cached[:session_id] == pane[:session_id] && cache_fresh?(cached, now, scanned_at)
        return cached[:reading]
      end
      reading = read_context(pane)
      pane[:context_cache] = {reading: reading, session_id: pane[:session_id], at: now}
      reading
    end

    # Reads the context uncached. A failure reads as no reading, so neither a
    # scan nor a request ever fails over it.
    def read_context(pane)
      @context_reader.read(pane_id: pane[:pane_id], agent_pid: pane[:agent_pid], current_session_id: pane[:session_id], kind: pane[:kind])
    rescue => e
      @logger.debug { "session monitor: context read failed (#{e.class}: #{e.message})" }
      {pct: nil, error: ContextReasons::NO_READING, updated_at: nil}
    end
  end
end
