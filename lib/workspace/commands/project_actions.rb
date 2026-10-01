require "json"

module Workspace
  module Commands
    # Project-wide actions: one verb applied to every workspace in a project
    # (a repository's main checkout plus its linked worktrees).
    #
    # Currently `stop`. The result schema, exit codes and own-session
    # ordering are shared plumbing for the verbs that follow: results are
    # `{workspace, path, kind, outcome, reason}` rows under a top-level
    # `status`, and the caller's own workspace is always handled last because
    # ending its tmux session ends this process.
    class ProjectActions
      # Bumped whenever the `--json` payload's shape changes in a
      # backward-incompatible way. Shared with {Projects}.
      JSON_SCHEMA_VERSION = Projects::JSON_SCHEMA_VERSION

      # Exit code for each result `status`. A partial run (some members
      # changed, some failed) is 3; `refused` means nothing changed.
      STATUS_EXIT_CODES = {"ok" => 0, "cancelled" => 0, "dry_run" => 0, "refused" => 1, "partial" => 3}.freeze

      # @param catalog [Workspace::ProjectCatalog] groups workspaces into projects and resolves NAME
      # @param stop_command [Workspace::Commands::Stop] the existing stop command, called once for all targets
      # @param state [Workspace::State] decides which members are active
      # @param tmux [Workspace::Tmux] lists sessions and maps workspaces and panes to session names
      # @param hook_runner [Workspace::HookRunner] runs `post_stop`; its output goes to stdout
      # @param json_hook_runner [Workspace::HookRunner] runs `post_stop` in `--json` mode; its output
      #   must go to stderr so it never lands in the JSON on stdout
      # @param output [IO] stream for the text summary or JSON
      # @param error_output [IO] stream for notes
      # @param own_pane [String, nil] the tmux pane this process runs in (+ENV["TMUX_PANE"]+)
      def initialize(catalog:, stop_command:, state:, tmux:, hook_runner:, json_hook_runner: hook_runner, output: $stdout, error_output: $stderr, own_pane: ENV["TMUX_PANE"])
        @catalog = catalog
        @stop_command = stop_command
        @state = state
        @tmux = tmux
        @hook_runner = hook_runner
        @json_hook_runner = json_hook_runner
        @output = output
        @error_output = error_output
        @own_pane = own_pane
      end

      # Stops every running workspace of a project in one step.
      #
      # Targets are the members that are active in the state file, whether or
      # not their checkout still exists. There is no unsaved-work check and no
      # prompt, as with `workspace stop`. The existing stop command runs once
      # for everyone except the caller's own workspace (so its launcher-window
      # logic is unchanged), `post_stop` runs for each workspace it stopped,
      # and one `tmux list-sessions` afterwards flags any session that
      # survived as `failed`. The result is written before the caller's own
      # session is stopped, as the very last step; its `post_stop` does not
      # run, and its outcome is reported as `stopped`.
      #
      # Outcomes: `stopped`, `would_stop` (dry run), `not_running`, `failed`.
      # Status: `ok`, `dry_run`, `partial` (some stopped, some failed) or
      # `refused` (every target failed). Exit code: 0, 0, 3, 1.
      #
      # @param name [String, nil] a project name, a member workspace name or a
      #   path; nil means the project containing +cwd+
      # @param dry_run [Boolean] report the targets without stopping anything
      # @param json [Boolean] print the schema-versioned JSON result instead of text
      # @param cwd [String] directory used when +name+ is nil
      # @return [Hash] `{exit_code:}`
      # @raise [Workspace::Error] if the project can't be found, unless +json+ is set
      # @raise [Workspace::UsageError] if +name+ matches several projects, unless +json+ is set
      def stop(name: nil, dry_run: false, json: false, cwd: Dir.pwd)
        project = name ? @catalog.find(name) : @catalog.for_cwd(cwd)
        @state.load
        members = ordered_members(project)
        running = members.select { |m| active?(m) }
        own = own_member(running)
        others = running - [own].compact

        return report_stop_dry_run(project, members, running, json: json) if dry_run

        outcomes = members.to_h { |m| [m, running.include?(m) ? "stopped" : "not_running"] }
        failed = {}
        stopped_names = others.empty? ? [] : @stop_command.call(others.map(&:workspace), quiet: json)
        runner = json ? @json_hook_runner : @hook_runner
        stopped_names.each { |ws| runner.run(ws, "post_stop") }
        unless others.empty?
          live = @tmux.sessions
          others.each do |m|
            session = @tmux.session_name_for(m.workspace)
            next unless live.include?(session)
            outcomes[m] = "failed"
            failed[m] = "tmux session '#{session}' is still running after stop"
          end
        end

        stopped = outcomes.values.count("stopped")
        status = if failed.empty? then "ok"
        elsif stopped.positive? then "partial"
        else
          "refused"
        end
        results = members.map { |m| result_row(m, outcomes[m], failed[m]) }
        emit_result("stop", project, results, status: status, dry_run: false, json: json) do
          print_stop_text(project, results)
        end
        # Last: stopping our own session ends this process, so buffered
        # output has to reach the reader first.
        flush_outputs
        @stop_command.call([own.workspace], quiet: json) if own
        {exit_code: STATUS_EXIT_CODES.fetch(status)}
      rescue => e
        raise unless json
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message.lines.first.to_s.strip})
        {exit_code: 1}
      end

      private

      # Catalog order, with the caller's own workspace moved to the end.
      def ordered_members(project)
        own = own_member(project.members)
        project.members.reject { |m| m.equal?(own) } + [own].compact
      end

      def own_member(members)
        return nil unless @own_pane
        own_session = @tmux.session_name_for_pane(@own_pane)
        return nil unless own_session
        members.find { |m| @tmux.session_name_for(m.workspace) == own_session }
      end

      def active?(member)
        !!@state[member.workspace]
      end

      def result_row(member, outcome, message = nil)
        row = {"workspace" => member.workspace, "path" => member.path, "kind" => member.kind,
               "outcome" => outcome, "reason" => message ? "error" : nil}
        row["message"] = message if message
        row
      end

      def report_stop_dry_run(project, members, running, json:)
        results = members.map { |m| result_row(m, running.include?(m) ? "would_stop" : "not_running") }
        emit_result("stop", project, results, status: "dry_run", dry_run: true, json: json) do
          if running.empty?
            @output.puts "Nothing running in project '#{project.name}'."
          else
            @output.puts "Would stop #{running.size} workspace(s) of project '#{project.name}':"
            running.each { |m| @output.puts "  #{m.workspace}" }
          end
        end
        {exit_code: 0}
      end

      def print_stop_text(project, results)
        stopped = results.select { |r| r["outcome"] == "stopped" }
        failed = results.select { |r| r["outcome"] == "failed" }
        if stopped.empty? && failed.empty?
          @output.puts "Nothing running in project '#{project.name}'."
          return
        end
        @output.puts "Stopped #{stopped.size} workspace(s) of project '#{project.name}'." if stopped.any?
        failed.each { |r| @output.puts "Failed to stop #{r["workspace"]}: #{r["message"]}" }
      end

      # Writes the JSON result, or yields to print the text form.
      def emit_result(action, project, results, status:, dry_run:, json:)
        unless json
          yield
          return
        end
        summary = results.each_with_object(Hash.new(0)) { |r, counts| counts[r["outcome"]] += 1 }
        @output.puts JSON.generate({
          "schema_version" => JSON_SCHEMA_VERSION,
          "action" => action,
          "dry_run" => dry_run,
          "status" => status,
          "project" => {"name" => project.name, "id" => project.id, "path" => project.path},
          "results" => results,
          "warnings" => [],
          "summary" => summary
        })
      end

      def flush_outputs
        [@output, @error_output].each { |io| io.flush if io.respond_to?(:flush) }
      end
    end
  end
end
