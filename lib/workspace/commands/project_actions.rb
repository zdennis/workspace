require "json"

module Workspace
  module Commands
    # Project-wide actions: one verb applied to every workspace in a project
    # (a repository's main checkout plus its linked worktrees).
    #
    # `stop` and `kill`. Results are `{workspace, path, kind, outcome,
    # reason}` rows under a top-level `status`, and the caller's own
    # workspace is always handled last because ending its tmux session ends
    # this process.
    class ProjectActions
      # Bumped whenever the `--json` payload's shape changes in a
      # backward-incompatible way. Shared with {Projects}.
      JSON_SCHEMA_VERSION = Projects::JSON_SCHEMA_VERSION

      # Exit code for each result `status`. A partial run (some members
      # changed, some failed) is 3; `failed` means every target failed;
      # `refused` means a safety check stopped the run before anything changed.
      STATUS_EXIT_CODES = {"ok" => 0, "cancelled" => 0, "dry_run" => 0, "failed" => 1, "refused" => 1, "partial" => 3}.freeze

      # Every outcome `stop` can report; `summary` always carries all of them.
      STOP_OUTCOMES = %w[stopped would_stop not_running failed].freeze

      # Every outcome `kill` can report; `summary` always carries all of them.
      KILL_OUTCOMES = %w[removed would_remove refused not_attempted failed kept].freeze

      # Outcomes that carry `forced`/`overridden_reason`: the ones where the
      # override was, or would be, acted on.
      FORCED_OUTCOMES = %w[removed failed would_remove].freeze
      private_constant :FORCED_OUTCOMES

      # Seconds all of `kill`'s preflight git reads may take together.
      DEFAULT_GIT_TIMEOUT = ProjectFacts::DEFAULT_GIT_TIMEOUT

      OUTCOMES = {"stop" => STOP_OUTCOMES, "kill" => KILL_OUTCOMES}.freeze
      private_constant :OUTCOMES

      # @param catalog [Workspace::ProjectCatalog] groups workspaces into projects and resolves NAME
      # @param stop_command [Workspace::Commands::Stop] the existing stop command, called once for all targets
      # @param kill_command [Workspace::Commands::Kill] the existing kill command, called once per worktree
      # @param state [Workspace::State] decides which members are active
      # @param tmux [Workspace::Tmux] lists sessions and maps workspaces and panes to session names
      # @param git [Workspace::Git] checks each worktree for unsaved work before `kill`
      # @param lock_namespace [Workspace::LockNamespace] locates the project's lock store
      # @param lock_holder [Workspace::LockHolder] tells live lock holders (a running dev env) from stale ones
      # @param hook_runner [Workspace::HookRunner] runs `post_stop`/`post_kill`; its output goes to stdout
      # @param json_hook_runner [Workspace::HookRunner] runs the hooks in `--json` mode; its output
      #   must go to stderr so it never lands in the JSON on stdout
      # @param output [IO] stream for the text summary or JSON
      # @param error_output [IO] stream for notes
      # @param input [IO] stream `kill` reads its confirmation from
      # @param own_pane [String, nil] the tmux pane this process runs in (+ENV["TMUX_PANE"]+)
      def initialize(catalog:, stop_command:, state:, tmux:, hook_runner:, kill_command: nil, git: nil, lock_namespace: nil, lock_holder: nil,
        json_hook_runner: hook_runner, output: $stdout, error_output: $stderr, input: $stdin, own_pane: ENV["TMUX_PANE"])
        @catalog = catalog
        @stop_command = stop_command
        @kill_command = kill_command
        @state = state
        @tmux = tmux
        @git = git
        @lock_namespace = lock_namespace
        @lock_holder = lock_holder
        @hook_runner = hook_runner
        @json_hook_runner = json_hook_runner
        @output = output
        @error_output = error_output
        @input = input
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
      # `failed` (every target failed). Exit code: 0, 0, 3, 1.
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
        @emitted = false
        @own_session_name = nil
        @own_session_known = false
        with_json_errors(json) do
          project = name ? @catalog.find(name) : @catalog.for_cwd(cwd)
          @state.load
          members = ordered_members(project)
          running = members.select { |m| active?(m) }
          own = own_member(running)
          others = running - [own].compact

          next report_stop_dry_run(project, members, running, json: json) if dry_run

          outcomes = members.to_h { |m| [m, running.include?(m) ? "stopped" : "not_running"] }
          failed = {}
          warnings = []
          stopped_names = others.empty? ? [] : @stop_command.call(others.map(&:workspace), quiet: json)
          unless others.empty?
            live = begin
              @tmux.sessions(strict: true)
            rescue Workspace::Error => e
              warnings << "could not verify sessions stopped: #{e.message}"
              @error_output.puts warnings.last
              nil
            end
            others.each do |m|
              session = @tmux.session_name_for(m.workspace)
              next unless live&.include?(session)
              outcomes[m] = "failed"
              failed[m] = "tmux session '#{session}' is still running after stop"
            end
          end
          runner = json ? @json_hook_runner : @hook_runner
          stopped_names.each do |ws|
            member = others.find { |m| m.workspace == ws }
            runner.run(ws, "post_stop") unless member && failed.key?(member)
          end

          stopped = outcomes.values.count("stopped")
          status = if failed.empty? then "ok"
          elsif stopped.positive? then "partial"
          else
            "failed"
          end
          results = members.map { |m| result_row(m, outcomes[m], reason: failed[m] && "error", message: failed[m]) }
          emit_result("stop", project, results, status: status, dry_run: false, json: json, warnings: warnings) do
            print_stop_text(project, results)
          end
          @emitted = true
          # Last: stopping our own session ends this process, so buffered
          # output has to reach the reader first. Quiet so text mode keeps
          # a single summary line.
          flush_outputs
          @stop_command.call([own.workspace], quiet: true) if own
          {exit_code: STATUS_EXIT_CODES.fetch(status)}
        end
      end

      # Removes every worktree workspace of a project, each through the
      # existing kill command (session, git worktree, tmuxinator config,
      # project settings, state entry). The main checkout is never removed
      # (`kept`), and worktrees without a workspace config are not touched.
      #
      # Every worktree is checked before anything is removed: its unsaved
      # work (`yes`, `no`, `missing` when the checkout is gone, `unknown` when
      # git errors or runs out of time), whether it holds the running dev
      # environment (the `devenv` lock), and other locks it holds (warnings
      # only). If any check is not overridden, nothing is removed: the
      # blocked members are `refused`, the rest `not_attempted`, and the
      # status is `refused`.
      #
      # Overrides: +force+ covers `missing` and `unknown` only;
      # +discard_unsaved+ covers unsaved work. A running dev env and an
      # unreadable lock store are never overridden. Only members covered by
      # +discard_unsaved+ are killed with `force: true`, which skips the
      # kill command's last-moment unsaved-work re-check; every other member
      # keeps it, and a member the re-check refuses is `failed` while the run
      # carries on. Any other error removing one member (including an OS
      # error) is also `failed` for that member only; when it came after the
      # member's worktree was already gone (its `post_kill` hook, its config
      # removal), the row says so with `worktree_removed: true`.
      #
      # Unless +yes+ or +dry_run+, the plan is printed and the user is asked
      # to confirm. The caller's own workspace is killed last, and the
      # result is written from inside its kill, after its worktree is gone
      # and before its session stops.
      #
      # Outcomes: `removed`, `would_remove`, `refused`, `not_attempted`,
      # `failed`, `kept`. Status: `ok`, `dry_run`, `cancelled`, `refused`,
      # `partial` or `failed`. Exit code: 0, 0, 0, 1, 3, 1.
      #
      # @param name [String] a project name, a member workspace name or a path
      # @param dry_run [Boolean] run the checks and report the plan without removing anything
      # @param yes [Boolean] don't prompt for confirmation
      # @param force [Boolean] override `missing` and `unknown` refusals
      # @param discard_unsaved [Boolean] override the refusal for unsaved work, and remove it
      # @param json [Boolean] print the schema-versioned JSON result instead of text
      # @param git_timeout [Numeric] seconds all the preflight git reads may take together
      # @return [Hash] `{exit_code:}`
      # @raise [Workspace::UsageError] if +json+ is set without +yes+ or +dry_run+
      #   (as JSON when +json+ is set), or if +name+ matches several projects
      # @raise [Workspace::Error] if the project can't be found, or the kill
      #   collaborators weren't wired, unless +json+ is set
      def kill(name:, dry_run: false, yes: false, force: false, discard_unsaved: false, json: false, git_timeout: DEFAULT_GIT_TIMEOUT)
        @emitted = false
        @own_session_name = nil
        @own_session_known = false
        with_json_errors(json) do
          unwired = {kill_command: @kill_command, git: @git, lock_namespace: @lock_namespace, lock_holder: @lock_holder}
            .select { |_, collaborator| collaborator.nil? }.keys
          raise Workspace::Error, "projects kill is not available: no #{unwired.join(", ")} was wired" if unwired.any?
          if json && !yes && !dry_run
            raise UsageError, "projects kill --json never prompts: pass --yes to remove, or --dry-run to preview."
          end
          project = @catalog.find(name)
          members = ordered_members(project)
          targets = members.select { |m| m.kind == "worktree" }
          own = own_member(targets)
          checks = preflight(project, targets, git_timeout)
          overrides = {force: force, discard_unsaved: discard_unsaved}
          open = targets.to_h { |m| [m, checks[m][:blockers].reject { |b| overridden?(b, overrides) }] }
          warnings = lock_warnings(targets, checks)

          if open.values.any?(&:any?)
            next report_kill_refused(project, members, checks, open, overrides, warnings, dry_run: dry_run, json: json)
          end
          if targets.empty?
            next emit_kill(project, members.map { |m| result_row(m, "kept") }, status: dry_run ? "dry_run" : "ok", dry_run: dry_run, json: json, warnings: warnings) do
              @output.puts "No worktrees in project '#{project.name}'."
            end
          end
          rows = ->(outcome) { members.map { |m| kill_row(m, (m.kind == "worktree") ? outcome : "kept", checks[m], overrides) } }
          if dry_run
            next emit_kill(project, rows.call("would_remove"), status: "dry_run", dry_run: true, json: json, warnings: warnings) do
              print_kill_plan(project, members, checks, overrides, warnings, heading: "Would remove #{targets.size} worktree(s) of project '#{project.name}':")
            end
          end
          unless yes
            print_kill_plan(project, members, checks, overrides, warnings, heading: "Project '#{project.name}' (#{project.path}):")
            @output.print "Remove #{targets.size} worktree(s) of '#{project.name}' and kill their sessions? [y/N] "
            unless @input.gets&.strip&.match?(/\Ay(es)?\z/i)
              @output.puts "Cancelled."
              next {exit_code: 0}
            end
          end

          execute_kill(project, members, targets, own, checks, overrides, warnings, json: json)
        end
      end

      private

      def execute_kill(project, members, targets, own, checks, overrides, warnings, json:)
        outcomes = {}
        others = targets - [own].compact
        others.each { |m| outcomes[m] = kill_member(m, checks[m], overrides, json: json, own: false) }
        finish = lambda do
          rows = members.map do |m|
            next kill_row(m, "kept", checks[m], overrides) unless m.kind == "worktree"
            outcome, reason, message, worktree_removed = outcomes.fetch(m, ["removed"])
            kill_row(m, outcome, checks[m], overrides, reason: reason, message: message, worktree_removed: worktree_removed)
          end
          removed = rows.count { |r| r["outcome"] == "removed" }
          failed = rows.count { |r| r["outcome"] == "failed" }
          status = if failed.zero? then "ok"
          elsif removed.positive? then "partial"
          else
            "failed"
          end
          emit_kill(project, rows, status: status, dry_run: false, json: json, warnings: warnings) do
            print_kill_text(project, rows)
          end
          @emitted = true
          flush_outputs
          {exit_code: STATUS_EXIT_CODES.fetch(status)}
        end
        return finish.call unless own

        # Last: our own kill ends this process when it stops the session, so
        # the result is written from inside its block, once the worktree is
        # gone and before the session stops.
        result = nil
        outcome = kill_member(own, checks[own], overrides, json: json, own: true) { result = finish.call }
        if @emitted
          @error_output.puts "error after the result was written: #{outcome[2]}" if outcome[0] == "failed"
          return result
        end
        outcomes[own] = outcome
        finish.call
      end

      # Kill yields once the worktree is gone, so reaching the block marks a
      # later failure as one that left the worktree removed.
      #
      # @return [Array] `[outcome, reason, message, worktree_removed]`
      def kill_member(member, check, overrides, json:, own:)
        overridden = overridden_reason(check, overrides)
        runner = json ? @json_hook_runner : @hook_runner
        worktree_gone = false
        @kill_command.call(member.workspace, force: overridden == "unsaved", confirm: false, quiet: json || own,
          missing_ok: overridden == "missing", warn_inactive: false) do |workspace|
          worktree_gone = true
          runner.run(workspace, "post_kill")
          yield if block_given?
        end
        ["removed", nil, nil, nil]
      rescue Workspace::UnsavedWorkError => e
        ["failed", (e.unsaved == :unknown) ? "unknown" : "unsaved", first_line(e.message), nil]
      rescue Workspace::Error, SystemCallError, IOError => e
        message = first_line(e.message)
        return ["failed", "error", message, nil] unless worktree_gone
        ["failed", "error", "#{message} (its worktree is already removed)", true]
      end

      def first_line(message)
        message.lines.first.to_s.strip
      end

      # One entry per worktree member: `{unsaved:, detail:, branch:, dev_env:, locks:, blockers:}`.
      def preflight(project, targets, git_timeout)
        return {} if targets.empty?
        unsaved = unsaved_checks(targets, git_timeout)
        status, lock_error = lock_status(project)
        targets.to_h do |m|
          check = unsaved[m].merge(dev_env: false, locks: [])
          (status || {}).each do |lock, entry|
            holder = entry["holder"]
            next unless holder && !holder["stale"]
            next unless @catalog.member_at(project, holder["worktree"]).equal?(m)
            if lock == DevRunner::LOCK_NAME
              check[:dev_env] = true
            else
              check[:locks] << lock
            end
          end
          [m, check.merge(blockers: blockers_for(m, check, lock_error))]
        end
      end

      def blockers_for(member, check, lock_error)
        list = []
        case check[:unsaved]
        when "missing"
          list << {reason: "missing", override: :force, message: "checkout is gone (#{member.path})"}
        when "unknown"
          list << {reason: "unknown", override: :force, message: "git couldn't check it for unsaved work"}
        when "yes"
          list << {reason: "unsaved", override: :discard_unsaved, message: "has unsaved work: #{Workspace::UnsavedWorkError.describe(check[:detail])}"}
        end
        if check[:dev_env]
          list << {reason: "dev_env", override: nil, message: "the dev environment is running in it; run 'workspace dev down' first"}
        end
        if lock_error
          list << {reason: "lock_store", override: nil,
                   message: "could not read the repo's locks to rule out a running dev environment (#{lock_error}); " \
                     "nothing overrides this, so remove worktrees one at a time with 'workspace kill NAME'"}
        end
        list
      end

      def overridden?(blocker, overrides)
        !!blocker[:override] && overrides[blocker[:override]]
      end

      # The reason this member's refusal was overridden ("missing",
      # "unknown" or "unsaved"), or nil when nothing about it was blocked.
      def overridden_reason(check, overrides)
        return nil unless check
        blocker = check[:blockers].find { |b| overridden?(b, overrides) }
        blocker && blocker[:reason]
      end

      # Reads every existing worktree's unsaved work and branch in parallel,
      # bounded as a whole by +timeout+; an error or timeout is "unknown".
      def unsaved_checks(targets, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        runs = targets.to_h do |m|
          next [m, nil] if !m.exists || !File.directory?(m.path)
          thread = Thread.new do
            Thread.current.report_on_exception = false
            [@git.unsaved_work(m.path), @git.worktree_branch(m.path)]
          end
          [m, thread]
        end
        runs.to_h do |m, thread|
          next [m, {unsaved: "missing", detail: nil, branch: nil}] unless thread
          unsaved, branch = await(thread, deadline)
          state = case unsaved
          when nil then "no"
          when Hash then "yes"
          else "unknown"
          end
          [m, {unsaved: state, detail: unsaved.is_a?(Hash) ? unsaved : nil, branch: unsaved.is_a?(Hash) ? unsaved[:branch] : branch}]
        end
      end

      def await(thread, deadline)
        remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
        return thread.value if thread.join(remaining)
        thread.kill
        [:unknown, nil]
      rescue
        [:unknown, nil]
      end

      # The repo-wide lock status, read once from the first checkout that
      # still exists, as `[status, error_message]`.
      def lock_status(project)
        dir = [project.path, *project.members.map(&:path)].find { |p| !p.to_s.empty? && File.directory?(p) }
        return [{}, nil] unless dir
        store = LockStore.new(dir: @lock_namespace.resolve(cwd: dir)[:dir], liveness: @lock_holder)
        [store.status, nil]
      rescue Workspace::Error, SystemCallError => e
        [nil, first_line(e.message)]
      end

      def lock_warnings(targets, checks)
        targets.flat_map do |m|
          checks[m][:locks].map { |lock| "#{m.workspace} holds lock '#{lock}'; it is released when its session ends" }
        end
      end

      def kill_row(member, outcome, check, overrides, reason: nil, message: nil, blockers: nil, worktree_removed: nil)
        return result_row(member, outcome, reason: reason, message: message) unless check
        extra = {unsaved: check[:unsaved], branch: check[:branch], dev_env: check[:dev_env]}
        if check[:detail]
          extra[:changed_files] = check[:detail][:changed_files]
          extra[:unpushed_commits] = check[:detail][:unpushed_commits]
        end
        extra[:locks] = check[:locks] if check[:locks].any?
        if FORCED_OUTCOMES.include?(outcome) && (overridden = overridden_reason(check, overrides))
          extra[:forced] = true
          extra[:overridden_reason] = overridden
        end
        extra[:worktree_removed] = true if worktree_removed
        extra[:blockers] = blockers.map { |b| {"reason" => b[:reason], "message" => b[:message]} } if blockers
        result_row(member, outcome, reason: reason, message: message, **extra)
      end

      def report_kill_refused(project, members, checks, open, overrides, warnings, dry_run:, json:)
        rows = members.map do |m|
          next kill_row(m, "kept", nil, overrides) unless m.kind == "worktree"
          blocked = open[m]
          next kill_row(m, "not_attempted", checks[m], overrides) if blocked.empty?
          kill_row(m, "refused", checks[m], overrides, reason: blocked.first[:reason],
            message: blocked.map { |b| b[:message] }.join("; "), blockers: blocked)
        end
        emit_kill(project, rows, status: "refused", dry_run: dry_run, json: json, warnings: warnings) do
          @output.puts(dry_run ? "Would refuse to kill project '#{project.name}' (dry run):" : "Not killing project '#{project.name}'; nothing was removed:")
          open.each do |m, blocked|
            blocked.each { |b| @output.puts "  #{m.workspace}: #{b[:message]}#{override_hint(b)}" }
          end
          warnings.each { |w| @output.puts "Warning: #{w}" }
        end
        {exit_code: STATUS_EXIT_CODES.fetch("refused")}
      end

      def override_hint(blocker)
        case blocker[:override]
        when :force
          (blocker[:reason] == "unknown") ? " (--force overrides this, or retry with a longer --timeout)" : " (--force overrides this)"
        when :discard_unsaved then " (--discard-unsaved removes it anyway, losing that work)"
        else ""
        end
      end

      def print_kill_plan(project, members, checks, overrides, warnings, heading:)
        @output.puts heading
        width = members.map { |m| m.workspace.to_s.size }.max
        members.each do |m|
          if m.kind != "worktree"
            @output.puts "  keep    #{m.workspace.to_s.ljust(width)}  #{m.path}  (main checkout)"
            next
          end
          check = checks[m]
          note = case overridden_reason(check, overrides)
          when "missing" then "checkout gone; removing its config and state"
          when "unknown" then "unsaved work unknown; removing anyway if git can check it now"
          when "unsaved" then "DISCARDING unsaved work: #{Workspace::UnsavedWorkError.describe(check[:detail])}"
          else check[:branch] && "branch #{check[:branch]}"
          end
          @output.puts "  remove  #{m.workspace.to_s.ljust(width)}  #{m.path}#{"  (#{note})" if note}"
        end
        warnings.each { |w| @output.puts "Warning: #{w}" }
      end

      def print_kill_text(project, rows)
        removed = rows.select { |r| r["outcome"] == "removed" }
        @output.puts "Removed #{removed.size} worktree(s) of project '#{project.name}'." if removed.any?
        rows.select { |r| r["outcome"] == "failed" }.each { |r| @output.puts "Failed to remove #{r["workspace"]}: #{r["message"]}" }
        rows.select { |r| r["outcome"] == "kept" }.each { |r| @output.puts "Kept the main checkout #{r["workspace"]}." }
      end

      def emit_kill(project, results, status:, dry_run:, json:, warnings:, &text)
        emit_result("kill", project, results, status: status, dry_run: dry_run, json: json, warnings: warnings, &text)
        {exit_code: STATUS_EXIT_CODES.fetch(status)}
      end

      # Catalog order, with the caller's own workspace moved to the end.
      def ordered_members(project)
        own = own_member(project.members)
        project.members.reject { |m| m.equal?(own) } + [own].compact
      end

      def own_member(members)
        return nil unless @own_pane
        unless @own_session_known
          @own_session_name = @tmux.session_name_for_pane(@own_pane)
          @own_session_known = true
        end
        return nil unless @own_session_name
        members.find { |m| @tmux.session_name_for(m.workspace) == @own_session_name }
      end

      # Runs the block. Under +json+ any error becomes the JSON error object
      # and exit code 1, unless the result was already written (a second JSON
      # document would corrupt stdout); then it goes to stderr.
      def with_json_errors(json)
        yield
      rescue => e
        raise unless json
        message = e.message.lines.first.to_s.strip
        if @emitted
          @error_output.puts "error after the result was written: #{message}"
        else
          @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e, message: message))
        end
        {exit_code: 1}
      end

      def active?(member)
        !!@state[member.workspace]
      end

      def result_row(member, outcome, reason: nil, message: nil, **extra)
        row = {"workspace" => member.workspace, "path" => member.path, "kind" => member.kind,
               "outcome" => outcome, "reason" => reason}
        row["message"] = message if message
        row.merge(extra.transform_keys(&:to_s))
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
      def emit_result(action, project, results, status:, dry_run:, json:, warnings: [])
        unless json
          yield
          return
        end
        summary = OUTCOMES.fetch(action).to_h { |o| [o, 0] }
        results.each { |r| summary[r["outcome"]] += 1 }
        @output.puts JSON.generate({
          "schema_version" => JSON_SCHEMA_VERSION, "ok" => true,
          "action" => action,
          "dry_run" => dry_run,
          "status" => status,
          "project" => {"name" => project.name, "id" => project.id, "path" => project.path},
          "results" => results,
          "warnings" => warnings,
          "summary" => summary
        })
      end

      def flush_outputs
        [@output, @error_output].each { |io| io.flush if io.respond_to?(:flush) }
      end
    end
  end
end
