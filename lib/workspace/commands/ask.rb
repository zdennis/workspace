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
      # @param env [Hash] process environment, for `TMUX_PANE`
      # @param output [IO] stream for the recorded/listed/answered question
      # @param error_output [IO]
      def initialize(config:, project_detector:, alert_config: nil, notifier_factory: nil,
        env: ENV, output: $stdout, error_output: $stderr)
        @config = config
        @project_detector = project_detector
        @alert_config = alert_config
        @notifier_factory = notifier_factory ||
          ->(command) { Notifier.new(command: command, error_output: error_output, label: "workspace ask") }
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
          pane: @env["TMUX_PANE"], worktree: working_dir)
        notifier = notify(name, record)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "question" => record})
        else
          @output.puts "Recorded question #{record["id"]} for #{name} (took default: #{default})"
        end
        # This process exits as soon as `call` returns, which would kill the
        # notifier thread before it spawns the command.
        notifier&.wait
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message})
        {exit_code: 1}
      end

      # @param working_dir [String] directory to detect the workspace from
      # @param json [Boolean] emit the documented JSON schema instead of a table
      # @return [Hash] {exit_code:}
      def list(working_dir: Dir.pwd, json: false)
        name = workspace_for(working_dir)
        records = store_for(name).list(open_only: true)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "workspace" => name, "questions" => records})
        elsif records.empty?
          @output.puts "No open questions for #{name}"
        else
          @output.puts "ID      PANE   QUESTION"
          records.each { |r| @output.puts format("%-8s%-7s%s", r["id"], r["pane"] || "-", r["question"]) }
        end
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message})
        {exit_code: 1}
      end

      # Marks a question answered.
      #
      # @param id [String]
      # @param answer [String]
      # @param working_dir [String] directory to detect the workspace from
      # @param json [Boolean] emit the documented JSON schema instead of a message
      # @return [Hash] {exit_code:}
      def answer(id, answer, working_dir: Dir.pwd, json: false)
        name = workspace_for(working_dir)
        store = store_for(name)
        record = store.answer(id, answer)
        unless record
          already_answered = store.list.any? { |r| r["id"] == id }
          message = already_answered ? "Question '#{id}' was already answered for #{name}." : "No question '#{id}' for #{name}."
          raise Workspace::Error, message
        end

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "question" => record})
        else
          @output.puts "Answered #{id}"
        end
        {exit_code: 0}
      rescue Workspace::Error => e
        raise unless json
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message})
        {exit_code: 1}
      end

      private

      def workspace_for(working_dir)
        name = @project_detector.detect(working_dir)
        raise Workspace::Error, "Could not detect a workspace at #{working_dir}." unless name
        name
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
