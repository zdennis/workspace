require "json"
require "fileutils"

module Workspace
  module Commands
    # `workflow learn reflect RUN`: asks an agent in a new split pane to look back at one finished run and write
    # `reflection.md` in the run's evidence directory. It reads the run and never changes it: no run lock, no
    # {WorkflowRunStore#change}, nothing written to the run's file or events. The only pane it types into is the one
    # it spawned; the run's own pane is never used. The pane is bound with kind `reflection` (see
    # {Workspace::PaneBindings}), which {Workspace::ReflectionWriteGuard} holds to the one file and ends when the
    # agent's turn ends with it written. Nothing reads `reflection.md` into a prompt. Two invocations at the same
    # time are not serialized: the second is refused (`reflection_in_progress`) only once the first has bound its pane.
    class WorkflowReflect
      # The schema_version of the `--json` documents.
      JSON_SCHEMA_VERSION = 1

      # The most bytes of an existing `reflection.md` printed.
      MAX_TEXT_BYTES = 200_000

      # @param store [Workspace::WorkflowRunStore] read only: {WorkflowRunStore#run}
      # @param reflection [Workspace::WorkflowReflection] composes the agent's instructions
      # @param panes [Workspace::PaneDispatch] spawns the pane, types into it and closes it again
      # @param binder [Workspace::Commands::Binding] binds the pane and says whether a binding is live
      # @param bindings [Workspace::PaneBindings] finds the panes bound to the run and removes a binding
      # @param main_agent [Workspace::MainAgent] names the workspace's agent kind when `agent` is not given
      # @param evidence_dir [String] {Workspace::Config#workflow_evidence_dir}
      # @param output [IO]
      def initialize(store:, reflection:, panes:, binder:, bindings:, main_agent:, evidence_dir:, output: $stdout)
        @store = store
        @reflection = reflection
        @panes = panes
        @binder = binder
        @bindings = bindings
        @main_agent = main_agent
        @evidence_dir = evidence_dir
        @output = output
      end

      # Prints an existing `reflection.md` (and launches nothing), or starts the reflection pane.
      #
      # @param run [String] a run id
      # @param agent [String, nil] one of {PaneDispatch::AGENT_KINDS}; nil is the workspace's main agent kind
      # @param json [Boolean] print one JSON document instead of text
      # @return [Hash] the document: `schema_version`, `ok`, `run`, `path` and, with `exists: true`, `text`, else
      #   `pane` and `instructions`; with `exists: true` also `truncated`, true when the text was cut at {MAX_TEXT_BYTES}
      # @raise [Workspace::Error] `unknown_run`, `run_not_finished`, `evidence_dir_linked`, `reflection_path_not_file`, `reflection_in_progress`,
      #   `pane_bound_to_run` (the new pane is the run's own, closed again, nothing typed), `agent_not_ready`, and
      #   the codes of {Workspace::PaneDispatch#spawn} and {Workspace::PaneDispatch#deliver}
      # @raise [Workspace::UsageError] for an agent kind that is not one of {PaneDispatch::AGENT_KINDS}
      def call(run:, agent: nil, json: false)
        found = @store.run(run)
        id = found.id
        raise unknown(run) unless id.is_a?(String) && RunLiveness::ID_PATTERN.match?(id)
        unless RunLiveness::TERMINAL_STATES.include?(found.state)
          state = TerminalText.escape(found.state.to_s)[0, 40]
          raise Workspace::Error.new("Run #{id} is #{state}, not finished, so there is nothing to reflect on yet. Run it to the end or cancel it first.",
            code: "run_not_finished", details: {"run_id" => id, "state" => state})
        end
        dir = File.join(@evidence_dir, id)
        path = File.join(dir, "reflection.md")
        prepare_dir(dir, id)
        kind_at_path = entry_kind(path)
        raise not_a_file(id, path) if kind_at_path == :other
        return show_existing(id, path, json) if kind_at_path == :file
        refuse_if_running(id)
        kind = agent_kind(agent, found.workspace)
        instructions = File.join(dir, "reflection.prompt.md")
        AtomicFile.write(instructions, @reflection.compose(found, evidence_dir: @evidence_dir))
        pane = start(found, kind, id, dir, instructions)
        document = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "run" => id, "pane" => pane, "path" => path,
                    "instructions" => instructions, "exists" => false}
        print_started(document, json)
        document
      end

      private

      def unknown(run)
        Workspace::Error.new("No workflow run has the id #{TerminalText.escape(run.to_s)[0, 80]}.", code: "unknown_run", details: {"run_id" => run.to_s[0, 80]})
      end

      def prepare_dir(dir, id)
        if File.symlink?(@evidence_dir) || File.symlink?(dir)
          raise Workspace::Error.new("The evidence directory of run #{id} is reached through a link, so nothing was written.",
            code: "evidence_dir_linked", details: {"run_id" => id})
        end
        FileUtils.mkdir_p(dir)
      end

      # :none when nothing is at the path, :file for a regular file, :other for anything else (a link, a directory, a FIFO).
      def entry_kind(path)
        File.lstat(path).file? ? :file : :other
      rescue Errno::ENOENT
        :none
      rescue SystemCallError
        :other
      end

      def not_a_file(id, path)
        Workspace::Error.new("#{TerminalText.escape(path)} is not a regular file, so nothing was started. Remove it, then run the command again.",
          code: "reflection_path_not_file", details: {"run_id" => id, "path" => path})
      end

      # Opens without following a link and checks the opened file, so a swap since the lstat is not followed.
      def read_text(id, path)
        File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK, binmode: true) do |file|
          raise not_a_file(id, path) unless file.stat.file?
          body = file.read(MAX_TEXT_BYTES + 1).to_s
          [body.byteslice(0, MAX_TEXT_BYTES).force_encoding(Encoding::UTF_8).scrub, body.bytesize > MAX_TEXT_BYTES]
        end
      rescue Errno::ELOOP, Errno::ENOENT
        raise not_a_file(id, path)
      end

      def show_existing(id, path, json)
        text, truncated = read_text(id, path)
        document = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "run" => id, "path" => path, "exists" => true, "text" => text, "truncated" => truncated}
        if json
          @output.puts JSON.generate(document)
        else
          @output.puts "Run #{TerminalText.escape(id)} already has a reflection: #{TerminalText.escape(path)}"
          @output.puts "To reflect again, delete that file first."
          @output.puts
          text.each_line { |line| @output.puts TerminalText.escape(line.chomp, keep_tabs: true) }
          @output.puts "(cut at #{MAX_TEXT_BYTES} bytes)" if truncated
        end
        document
      end

      def refuse_if_running(id)
        pane = @bindings.pane_for("reflection", id)
        return unless pane
        if @binder.reflecting(pane: pane)
          raise Workspace::Error.new("Pane #{pane} is already reflecting on run #{id}. Wait for it to write reflection.md, or end it with `workspace binding clear --pane #{pane}`, or close the pane.",
            code: "reflection_in_progress", details: {"run_id" => id, "pane" => pane, "use" => "workspace binding clear --pane #{pane}, or close the pane"})
        end
        @bindings.unbind(pane)
      end

      def agent_kind(agent, workspace)
        kind = agent || @main_agent.kind(workspace)
        return kind if PaneDispatch::AGENT_KINDS.include?(kind)
        raise UsageError, "Workspace #{TerminalText.escape(workspace.to_s)} has no agent pane to take the agent kind from: pass --agent KIND (one of #{PaneDispatch::AGENT_KINDS.join(", ")})." if agent.nil? && kind == "none"
        raise UsageError, "Unknown agent #{TerminalText.escape(kind.to_s)[0, 40].inspect}: one of #{PaneDispatch::AGENT_KINDS.join(", ")}."
      end

      # Spawns, binds and types. A failure after the split closes the new pane again, unbound.
      def start(found, kind, id, dir, instructions)
        workspace = found.workspace
        spawned = @panes.spawn(workspace, kind)
        unless spawned.ready?
          raise Workspace::Error.new(@panes.not_ready_message(spawned, "reflection"), code: "agent_not_ready", details: @panes.not_ready_details(spawned))
        end
        pane = spawned.pane
        refuse_run_pane(found, id, pane, workspace)
        begin
          @binder.bind(workspace: workspace, pane: pane, kind: "reflection", id: id, artifacts: dir, instructions: instructions)
          @panes.deliver(workspace, pane, body: prompt_line(id, instructions))
        rescue Workspace::Error, SystemCallError
          @bindings.unbind(pane)
          @panes.close_unused(workspace, pane)
          raise
        end
        pane
      end

      def refuse_run_pane(found, id, pane, workspace)
        parked = found.parked
        bound = [found.pane, parked.is_a?(Hash) ? parked["pane"] : nil, @bindings.pane_for("run", id)].compact
        return unless bound.include?(pane)
        closed = @panes.close_unused(workspace, pane)
        raise Workspace::Error.new("The new pane #{pane} is the pane run #{id} is bound to, so nothing was typed into it#{" and it was closed" if closed}.",
          code: "pane_bound_to_run", details: {"workspace" => workspace, "pane" => pane, "run_id" => id, "pane_closed" => closed})
      end

      def prompt_line(id, instructions)
        "Reflect on workflow run #{id}. Read the instructions in #{instructions} and follow them: write only the reflection.md they name, then end your turn."
      end

      def print_started(document, json)
        if json
          @output.puts JSON.generate(document)
          return
        end
        @output.puts "Started a reflection on run #{TerminalText.escape(document["run"])} in pane #{TerminalText.escape(document["pane"])}."
        @output.puts "The agent writes #{TerminalText.escape(document["path"])}; read it there, or run this command again to print it."
        @output.puts "The pane is held to that one file and is released when its turn ends with the file written. " \
          "End it sooner with `workspace binding clear --pane #{TerminalText.escape(document["pane"])}`, or close the pane."
      end
    end
  end
end
