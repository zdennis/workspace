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
      # @param event_log [Workspace::EventLog, nil] records `ask_created` and `ask_answered`
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
      # @return [Hash] {exit_code:}
      def list(working_dir: Dir.pwd, json: false)
        name = workspace_for(working_dir)
        records = store_for(name).list(open_only: true)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name, "questions" => records})
        elsif records.empty?
          @output.puts "No open questions for #{name}"
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
        unless record
          already_answered = store.list.any? { |r| r["id"] == id }
          message = already_answered ? "Question '#{id}' was already answered for #{name}." : "No question '#{id}' for #{name}."
          raise Workspace::Error, message
        end
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

      private

      # The open question's asking pane, checked against the workspace's
      # session. Nil when there is no such open question, so the normal
      # not-found error follows.
      def pane_to_deliver_to(store, name, id)
        raise Workspace::Error, "workspace ask answer --deliver is not available in this build" unless @pane_sender
        record = store.list(open_only: true).find { |r| r["id"] == id }
        return unless record

        pane = record["pane"]
        unless pane
          raise Workspace::Error.new("Question '#{id}' wasn't asked from a tmux pane, so there is nowhere to type the answer. Answer it without --deliver.",
            code: "no_pane", details: {"question" => id})
        end
        @pane_sender.locate(name, pane)
        confirm_same_tmux_server(record, pane)
        pane
      end

      # Pane ids restart from %0 when tmux does, so a pane id recorded before
      # a restart can name a different pane now. Delivery needs the server
      # the question was asked under to still be the one running.
      def confirm_same_tmux_server(record, pane)
        recorded = record["tmux_server"]
        return if recorded && recorded == @pane_sender.server_pid(pane)

        reason = recorded ? "tmux has restarted since it was asked" : "it doesn't record which tmux server it was asked under"
        raise Workspace::Error.new("Question '#{record["id"]}' can't be delivered: #{reason}, so pane #{pane} may not be the pane that asked. Answer it without --deliver.",
          code: "stale_pane", details: {"question" => record["id"], "pane" => pane})
      end

      # The tmux server's process id from `$TMUX` ("socket,pid,session"), when run inside tmux.
      def tmux_server_pid
        @env["TMUX"].to_s[/\A[^,]*,(\d+),/, 1]
      end

      def deliver_answer(name, pane, answer, id)
        @pane_sender.deliver(name: name, pane: pane, body: answer)
      rescue Workspace::Error => e
        raise e.class.new("Question '#{id}' is marked answered, but typing the answer into pane #{pane} failed: #{e.message}",
          code: e.code, details: e.details.merge("question" => id, "answered" => true))
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
