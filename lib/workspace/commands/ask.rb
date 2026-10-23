require "json"

module Workspace
  module Commands
    # Records a question an unattended agent hits, along with the default it
    # took, so the agent can keep going instead of blocking on a person.
    # `ask` never reads stdin and returns once the question is on disk and
    # any notify command has finished (or been stopped at its timeout); a
    # human reviews and resolves open questions later with
    # `ask list`/`ask answer`.
    class Ask
      # Bumped whenever the `--json` payload's shape changes in a
      # backward-incompatible way; matches the convention in
      # {Workspace::Commands::Lock} and {Workspace::Commands::Sessions}.
      JSON_SCHEMA_VERSION = 1

      # @param config [Workspace::Config] question-store path lookups
      # @param project_detector [Workspace::ProjectDetector] resolves the workspace from cwd
      # @param alert_config [Workspace::AlertConfig, nil] reads a project's
      #   `alerts.notify`; nil records questions without ever notifying
      # @param notifier_factory [#call] builds a {Workspace::Notifier} for a notify command string
      # @param pane_sender [Workspace::Commands::Send, nil] types an answer into the
      #   asking pane for `answer --deliver`; nil refuses `--deliver`
      # @param event_log [Workspace::EventLog, nil] records `ask_created`, `ask_answered` and `ask_withdrawn`
      #   (ids and pane only, never the text); nil records nothing
      # @param env [Hash] process environment, for `TMUX_PANE`
      # @param output [IO] stream for the recorded/listed/answered question
      # @param error_output [IO]
      def initialize(config:, project_detector:, alert_config: nil, notifier_factory: nil,
        pane_sender: nil, event_log: nil, env: ENV, output: $stdout, error_output: $stderr)
        @config = config
        @project_detector = project_detector
        @alert_config = alert_config
        @notifier_factory = notifier_factory ||
          ->(command) { Notifier.new(command: command, error_output: error_output, label: "workspace ask") }
        @pane_sender = pane_sender
        @event_log = event_log
        @env = env
        @output = output
        @error_output = error_output
      end

      # Records a new open question. Returns at once unless the project has a
      # notify command, in which case it waits for that command, which the
      # notifier stops at its own timeout.
      #
      # @param question [String]
      # @param default [String] the default the agent took
      # @param context [String, nil] free-text pointer to the code in question
      # @param working_dir [String] directory to detect the workspace from
      # @param json [Boolean] emit the documented JSON schema instead of a message
      # @return [Hash] {exit_code:}
      def call(question:, default:, context: nil, working_dir: Dir.pwd, json: false)
        raise Workspace::Error, "The question can't be blank." if question.strip.empty?
        raise Workspace::Error, "The default can't be blank." if default.strip.empty?
        name = workspace_for(working_dir)
        record = store_for(name).add(question: question, default: default, context: context,
          pane: @env["TMUX_PANE"], worktree: working_dir, tmux_server: tmux_server_pid)
        record_event("ask_created", name, record)
        notifier = notify(name, record)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "question" => record})
        else
          @output.puts "Recorded question #{record["id"]} for #{name} (took default: #{default})"
        end
        # This process exits as soon as `call` returns, which would kill the
        # notifier thread before it spawns the command.
        notifier&.wait
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e))
        {exit_code: 1}
      end

      # @param working_dir [String] directory to detect the workspace from
      # @param json [Boolean] emit the documented JSON schema instead of a table
      # @param all [Boolean] also list answered and withdrawn questions
      # @return [Hash] {exit_code:}
      def list(working_dir: Dir.pwd, json: false, all: false)
        name = workspace_for(working_dir)
        records = store_for(name).list(open_only: !all)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name, "questions" => records})
        elsif records.empty?
          @output.puts all ? "No questions for #{name}" : "No open questions for #{name}"
        elsif all
          @output.puts "ID      STATUS     PANE   QUESTION"
          records.each { |r| @output.puts format("%-8s%-11s%-7s%s", r["id"], r["status"], r["pane"] || "-", r["question"]) }
        else
          @output.puts "ID      PANE   QUESTION"
          records.each { |r| @output.puts format("%-8s%-7s%s", r["id"], r["pane"] || "-", r["question"]) }
        end
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e))
        {exit_code: 1}
      end

      # Marks a question answered, and with +deliver+ types the answer into
      # the pane that asked.
      #
      # The asking pane is checked before the question is touched, so a missing
      # or foreign pane leaves it open. Delivery then happens after the answer
      # is recorded: if typing fails the question stays answered and the error
      # says so (`details.answered`), so it is not answered twice.
      #
      # @param id [String]
      # @param answer [String]
      # @param working_dir [String] directory to detect the workspace from
      # @param json [Boolean] emit the documented JSON schema instead of a message
      # @param deliver [Boolean] type the answer, then Enter, into the asking pane
      # @return [Hash] {exit_code:}
      def answer(id, answer, working_dir: Dir.pwd, json: false, deliver: false)
        name = workspace_for(working_dir)
        store = store_for(name)
        pane = deliver ? pane_to_deliver_to(store, name, id) : nil
        record = store.answer(id, answer)
        raise not_open_error(store, name, id, "answered") unless record
        record_event("ask_answered", name, record)
        delivered = pane ? deliver_answer(name, pane, answer, id) : nil

        if json
          document = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "question" => record}
          document["delivered"] = {"pane" => delivered["pane"], "submitted" => delivered["submitted"]} if delivered
          @output.puts JSON.generate(document)
        else
          @output.puts "Answered #{id}"
          @output.puts "Typed the answer into pane #{delivered["pane"]} and pressed Enter." if delivered
        end
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e))
        {exit_code: e.is_a?(Run::NotSubmittedError) ? Run::NotSubmittedError::EXIT_CODE : 1}
      end

      # Types an already-answered question's recorded answer, then Enter, into
      # its pane again: the retry for `answer --deliver` when typing failed
      # after the answer was recorded. Nothing in the store changes.
      #
      # The pane is the question's own (checked against the workspace's
      # session and the tmux server it was asked under, as `answer --deliver`
      # does) unless +pane+ names another pane of the workspace's session.
      #
      # @param id [String]
      # @param pane [String, nil] pane id or window.pane to type into instead
      # @param working_dir [String] directory to detect the workspace from
      # @param json [Boolean] emit the documented JSON schema instead of a message
      # @return [Hash] {exit_code:}
      def deliver(id, pane: nil, working_dir: Dir.pwd, json: false)
        raise Workspace::Error, "workspace ask deliver is not available in this build" unless @pane_sender
        name = workspace_for(working_dir)
        record = store_for(name).list.find { |r| r["id"] == id }
        raise Workspace::Error, "No question '#{id}' for #{name}." unless record
        unless record["status"] == "answered"
          raise Workspace::Error.new("Question '#{id}' is #{record["status"]} for #{name}, so it has no answer to deliver. Answer it first with `workspace ask answer #{id} \"<answer>\" --deliver`.",
            code: "ask_not_answered", details: {"id" => id, "status" => record["status"]})
        end
        target = pane ? @pane_sender.locate(name, pane)[:id] : pane_of(record, name, retrying: true)
        delivered = deliver_answer(name, target, record["answer"], id, retry_of: true, explicit_pane: pane)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "question" => record,
                                      "delivered" => {"pane" => delivered["pane"], "submitted" => delivered["submitted"]}})
        else
          @output.puts "Typed the answer to #{id} into pane #{delivered["pane"]} and pressed Enter."
        end
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e))
        {exit_code: e.is_a?(Run::NotSubmittedError) ? Run::NotSubmittedError::EXIT_CODE : 1}
      end

      # Closes an open question its asker no longer needs answered. Only an
      # open question can be withdrawn; the event carries ids, never text.
      #
      # @param id [String]
      # @param working_dir [String] directory to detect the workspace from
      # @param json [Boolean] emit the documented JSON schema instead of a message
      # @return [Hash] {exit_code:}
      def withdraw(id, working_dir: Dir.pwd, json: false)
        name = workspace_for(working_dir)
        store = store_for(name)
        record = store.withdraw(id)
        raise not_open_error(store, name, id, "withdrawn") unless record
        record_event("ask_withdrawn", name, record)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "question" => record})
        else
          @output.puts "Withdrew #{id}"
        end
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e))
        {exit_code: 1}
      end

      private

      # The error for an id with no open question: a closed one is
      # `ask_not_open` (its status in `details`), an unknown one a plain error.
      # +verb+ is what the caller tried to do, for the message.
      def not_open_error(store, name, id, verb)
        record = store.list.find { |r| r["id"] == id }
        return Workspace::Error.new("No question '#{id}' for #{name}.") unless record

        status = record["status"]
        Workspace::Error.new("Question '#{id}' was already #{status} for #{name}, so it can't be #{verb}.",
          code: "ask_not_open", details: {"id" => id, "status" => status})
      end

      # The open question's asking pane, checked against the workspace's
      # session. Nil when there is no such open question, so the normal
      # not-found error follows.
      def pane_to_deliver_to(store, name, id)
        raise Workspace::Error, "workspace ask answer --deliver is not available in this build" unless @pane_sender
        record = store.list(open_only: true).find { |r| r["id"] == id }
        pane_of(record, name) if record
      end

      # A recorded question's own pane, checked against the workspace's
      # session and the tmux server it was asked under.
      def pane_of(record, name, retrying: false)
        pane = record["pane"]
        unless pane
          raise Workspace::Error.new("Question '#{record["id"]}' wasn't asked from a tmux pane, so there is nowhere to type the answer. #{retrying ? "Name the pane with --pane." : "Answer it without --deliver."}",
            code: "no_pane", details: {"question" => record["id"]})
        end
        @pane_sender.locate(name, pane)
        confirm_same_tmux_server(record, pane, retrying)
        pane
      end

      # Pane ids restart from %0 when tmux does, so a pane id recorded before
      # a restart can name a different pane now. Delivery needs the server
      # the question was asked under to still be the one running.
      def confirm_same_tmux_server(record, pane, retrying)
        recorded = record["tmux_server"]
        return if recorded && recorded == @pane_sender.server_pid(pane)

        reason = recorded ? "tmux has restarted since it was asked" : "it doesn't record which tmux server it was asked under"
        raise Workspace::Error.new("Question '#{record["id"]}' can't be delivered: #{reason}, so pane #{pane} may not be the pane that asked. #{retrying ? "Name the pane with --pane." : "Answer it without --deliver."}",
          code: "stale_pane", details: {"question" => record["id"], "pane" => pane})
      end

      # The tmux server's process id from `$TMUX` ("socket,pid,session"), when run inside tmux.
      def tmux_server_pid
        @env["TMUX"].to_s[/\A[^,]*,(\d+),/, 1]
      end

      def deliver_answer(name, pane, answer, id, retry_of: false, explicit_pane: nil)
        @pane_sender.deliver(name: name, pane: pane, body: answer)
      rescue Workspace::Error => e
        command_line = "workspace ask deliver #{id} --name #{name}#{" --pane #{explicit_pane}" if explicit_pane}"
        retry_hint = "Retry with `#{command_line}`."
        message = if retry_of
          "Typing the answer to question '#{id}' into pane #{pane} failed: #{e.message} #{retry_hint}"
        else
          "Question '#{id}' is marked answered, but typing the answer into pane #{pane} failed: #{e.message} #{retry_hint}"
        end
        raise e.class.new(message, code: e.code,
          details: e.details.merge("question" => id, "answered" => true, "retry" => command_line))
      end

      def workspace_for(working_dir)
        name = @project_detector.detect(working_dir)
        raise Workspace::Error.new("Could not detect a workspace at #{working_dir}.", code: "not_in_workspace", details: {"path" => working_dir}) unless name
        name
      end

      # Only the id and the asking pane go in the log: the question, default,
      # context and answer are the user's text and stay in the ask store.
      # EventLog#record never raises.
      def record_event(type, name, record)
        @event_log&.record(type: type, project: name, data: {"id" => record["id"], "workspace" => name, "pane_id" => record["pane"]})
      end

      def store_for(name)
        AskStore.new(path: @config.ask_state_path(name), error_output: @error_output)
      end

      # Runs the notify command, when the project has one configured, so a
      # person watching for alerts hears about the question right away. No
      # notify config means the question is recorded and nothing else
      # happens; that is not an error.
      #
      # @return [Workspace::Notifier, nil] the notifier to wait on, if one ran
      def notify(name, record)
        return unless @alert_config
        command = @alert_config.for_workspace(name)[:notify]
        return unless command

        # WORKSPACE_ALERT is the same alert-type variable session_monitor.rb
        # sets to "waiting"/"idle"; WORKSPACE_ALERT_KIND is reserved there for
        # the agent kind (e.g. "claude"), which a question has no notion of,
        # so it is left unset here rather than reused for something else.
        env = {
          "WORKSPACE_ALERT" => "question",
          "WORKSPACE_ALERT_WORKSPACE" => name,
          "WORKSPACE_ALERT_TEXT" => "#{name}: #{record["question"]} (default: #{record["default"]})",
          "WORKSPACE_ALERT_QUESTION" => record["question"],
          "WORKSPACE_ALERT_DEFAULT" => record["default"],
          "WORKSPACE_ALERT_ID" => record["id"]
        }
        env["WORKSPACE_ALERT_CONTEXT"] = record["context"] if record["context"]
        env["WORKSPACE_ALERT_PANE"] = record["pane"] if record["pane"]
        notifier = @notifier_factory.call(command)
        notifier.notify(env)
        notifier
      rescue Workspace::Error => e
        @error_output.puts "workspace ask: could not read alert settings for #{name}: #{e.message}"
        nil
      end
    end
  end
end
