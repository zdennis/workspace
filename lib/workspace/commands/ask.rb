require "json"

module Workspace
  module Commands
    # Records a question an unattended agent hits, along with the default it
    # took, so the agent can keep going instead of blocking on a person.
    # `ask` never reads stdin and returns as soon as the question is on
    # disk; a human reviews and resolves open questions later with
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
      def initialize(config:, project_detector:, alert_config: nil, notifier_factory: ->(command) { Notifier.new(command: command) },
        env: ENV, output: $stdout, error_output: $stderr)
        @config = config
        @project_detector = project_detector
        @alert_config = alert_config
        @notifier_factory = notifier_factory
        @env = env
        @output = output
        @error_output = error_output
      end

      # Records a new open question and returns at once.
      #
      # @param question [String]
      # @param default [String] the default the agent took
      # @param context [String, nil] free-text pointer to the code in question
      # @param working_dir [String] directory to detect the workspace from
      # @param json [Boolean] emit the documented JSON schema instead of a message
      # @return [Hash] {exit_code:}
      def call(question:, default:, context: nil, working_dir: Dir.pwd, json: false)
        name = workspace_for(working_dir)
        record = store_for(name).add(question: question, default: default, context: context,
          pane: @env["TMUX_PANE"], worktree: working_dir)
        notify(name, record)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "question" => record})
        else
          @output.puts "Recorded question #{record["id"]} for #{name} (took default: #{default})"
        end
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
        record = store_for(name).answer(id, answer)
        raise Workspace::Error, "No open question '#{id}' for #{name}." unless record

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
        AskStore.new(path: @config.ask_state_path(name))
      end

      # Runs the notify command, when the project has one configured, so a
      # person watching for alerts hears about the question right away. No
      # notify config means the question is recorded and nothing else
      # happens; that is not an error.
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
        @notifier_factory.call(command).notify(env)
      rescue Workspace::Error => e
        @error_output.puts "workspace ask: could not read alert settings for #{name}: #{e.message}"
      end
    end
  end
end
