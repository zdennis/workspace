require "shellwords"

module Workspace
  module Commands
    # `workspace promote [BRANCH]`: moves the work in a main checkout (its changes and the commits of its
    # branch) into a new worktree at `.worktrees/<branch>` through {Workspace::CheckoutMove}, makes that
    # worktree a workspace through `start` (no launch, no plan, no spine), carries the plan, the spine and
    # the named notes into its notes directory through {Workspace::NotesCarry}, and only then makes the
    # spine and the plan that were asked for and not carried. `--launch` starts its agent last.
    #
    # Refuses while an agent pane of the main checkout's workspace works or waits (`agent_working`), the
    # caller's own pane (`$TMUX_PANE`) aside; `force: true` moves anyway. Once the move is done it is never
    # undone: a `start` failure after it is an error carrying `details.moved` and the `start` command that
    # finishes the job, and every later step is a warning.
    class Promote
      JSON_SCHEMA_VERSION = 1

      # Pane states that mean an agent is in the middle of something.
      BUSY_STATES = %w[working waiting].freeze

      # The error codes this command raises itself; {Workspace::CheckoutMove::CODES} are the move's.
      AGENT_WORKING = "agent_working"

      # The notes directory `dry_run` hands {Workspace::NotesCarry} when there is no worktree yet: a path
      # that does not exist, so nothing in it clashes.
      DRY_RUN_NOTES = ".promote-dry-run"

      # @param checkout_move [Workspace::CheckoutMove] the git half
      # @param notes_carry [Workspace::NotesCarry] carries the plan, the spine and the named notes
      # @param start [Workspace::Commands::Start] makes the moved worktree a workspace ({Start#payload})
      # @param notes [Workspace::Commands::Notes] the main checkout's notes directory
      # @param project_config [Workspace::ProjectConfig] the checkout of `--name`, and the workspace names
      # @param panes [Workspace::PaneDispatch] whether the main workspace's session runs, and its panes' states
      #   from the agent daemon (through {Workspace::AgentSnapshotClient})
      # @param spine_init [Workspace::Commands::SpineInit, nil] makes a spine that was asked for and not carried
      # @param spine_config [Workspace::SpineConfig, nil] reads `spine.auto`
      # @param plan_command [Workspace::Commands::Plan, nil] makes a plan (`plan init`) that was asked for and not carried
      # @param plan_dispatch [Workspace::Commands::PlanDispatch, nil] starts the plan for `launch:` when there is one
      # @param workspace_at [#call] `(checkout_path)` to the name of the workspace whose checkout that is, or nil; names the
      #   main checkout's workspace when no `--name` is given (else its config is looked up by the directory's name)
      # @param locks [#call] `(checkout_path)` to `{names:, own:}`, the live locks in that repository (only the caller's
      #   when `own`); for the `locks_held` warning (see {Workspace::HeldLocks})
      # @param event_log [Workspace::EventLog, nil] gets the `workspace_promoted` line
      # @param env [#[]] reads `TMUX_PANE`, the caller's own pane
      # @param output [IO] the human summary
      # @param error_output [IO] the human warnings
      def initialize(checkout_move:, notes_carry:, start:, notes:, project_config:, panes:, spine_init: nil, spine_config: nil,
        plan_command: nil, plan_dispatch: nil, workspace_at: ->(_path) {}, locks: ->(_path) { {names: [], own: true} }, event_log: nil, env: ENV, output: $stdout, error_output: $stderr)
        @checkout_move = checkout_move
        @notes_carry = notes_carry
        @start = start
        @notes = notes
        @project_config = project_config
        @panes = panes
        @spine_init = spine_init
        @spine_config = spine_config
        @plan_command = plan_command
        @plan_dispatch = plan_dispatch
        @workspace_at = workspace_at
        @locks = locks
        @event_log = event_log
        @env = env
        @output = output
        @error_output = error_output
      end

      # @param working_dir [String] the top of the main checkout, when +name+ is nil
      # @param branch [String, nil] the branch to move the work to; nil moves the current branch
      # @param name [String, nil] the main checkout's workspace, from any directory
      # @param title [String, nil] the new workspace's task title
      # @param spine [String, Boolean, nil] a template name or true makes a spine when none was carried; false never;
      #   nil follows `spine.auto`
      # @param plan [String, Boolean, nil] a title or true makes a plan when none was carried
      # @param carry_notes [Array<String>] notes to copy, relative to the main notes directory
      # @param launch [#call, nil] `(workspace, prompt:, play:)` launches the new workspace and returns
      #   `{ok:, started:, reason:, message:, pane:, packs:}`; nil does not launch
      # @param prompt [String, nil] text for the launched agent (after the plan's line, when there is a plan)
      # @param headless [Boolean] reported as `headless`; the launch itself takes it from +launch+
      # @param agent_kind [String, nil] the new workspace's main agent
      # @param force [Boolean] move even while an agent pane works
      # @param dry_run [Boolean] report and write nothing
      # @param json [Boolean] print nothing; the caller prints the document
      # @return [Hash] `{exit_code:, json:}`, the document as `promote --json` prints it
      # @raise [Workspace::UsageError] `branch_required`, a bad branch name
      # @raise [Workspace::Error] `unknown_workspace`, `agent_working`, the {Workspace::CheckoutMove} codes, and a
      #   `start` failure after the move (its own code, with `details.moved` and `details.next`)
      def call(working_dir:, branch: nil, name: nil, title: nil, spine: nil, plan: nil, carry_notes: [], launch: nil, prompt: nil,
        headless: false, agent_kind: nil, force: false, dry_run: false, json: false)
        root, main = checkout(name, working_dir)
        main_notes, notes_warnings = main_notes_dir(main, carry_notes)
        busy, agent_warnings = busy_panes(main)
        if busy.any? && !dry_run && !force
          raise Workspace::Error.new("An agent in #{main} is #{busy.first["state"]} (pane #{busy.first["pane"]}); the move would take files out from under it. " \
            "Wait for it to finish, or pass --force.", code: AGENT_WORKING, details: {"workspace" => main, "panes" => busy},
            retry_with: {"flags" => ["--force"], "destructive" => true})
        end
        agent_warnings << working_warning(main, busy, forced: !dry_run) if busy.any?
        warnings = notes_warnings + agent_warnings
        result = if dry_run
          preview(root, branch, main_notes, carry_notes, warnings)
        else
          promote(root, branch, main_notes, warnings, title: title, spine: spine, plan: plan, carry_notes: carry_notes,
            launch: launch, prompt: prompt, headless: headless, agent_kind: agent_kind)
        end
        summarize(result[:json]) unless json
        result
      end

      private

      # @return [Array(String, String)] the checkout's path and its workspace name (nil when it has no config)
      def checkout(name, working_dir)
        unless name
          root = File.expand_path(working_dir)
          return [root, @workspace_at.call(root) || @project_config.existing_name(WorkspaceLineage.name_from_path(root))]
        end
        root = @project_config.project_root_for(name)
        raise Workspace::Error.new("Unknown workspace '#{name}'. Run 'workspace list --all' to see the names.", code: "unknown_workspace", details: {"name" => name}) unless root
        [File.expand_path(root), name]
      end

      def project_name(root)
        from_path = WorkspaceLineage.name_from_path(root)
        @project_config.existing_name(from_path) || WorkspaceName.normalize(from_path)
      end

      def main_notes_dir(main, carry_notes)
        unless main
          return [nil, carry_notes.empty? ? [] : [notes_unavailable("the main checkout has no workspace config (workspace add .)")]]
        end
        [@notes.info(name: main)["dir"], []]
      rescue Workspace::Error => e
        [nil, [notes_unavailable(e.message)]]
      end

      def notes_unavailable(reason)
        {"code" => "notes_unavailable", "message" => "The main checkout's notes directory is not known, so no notes were carried: #{reason}"}
      end

      # @return [Array(Array<Hash>, Array<Hash>)] the busy panes (`pane`, `state`) and the warnings
      def busy_panes(main)
        return [[], []] unless main
        return [[], []] if @panes.session_live?(main) == false
        own = @env["TMUX_PANE"]
        busy = @panes.panes(main).select { |row| BUSY_STATES.include?(row["state"]) && row["pane_id"] && row["pane_id"] != own }
        [busy.map { |row| {"pane" => row["pane_id"], "state" => row["state"]} }, []]
      rescue Workspace::Error => e
        [[], [{"code" => "agent_state_unknown", "message" => "Could not tell whether an agent in #{main} is working (#{e.message}); moved without checking."}]]
      end

      def working_warning(main, busy, forced:)
        list = busy.map { |pane| "#{pane["pane"]} (#{pane["state"]})" }.join(", ")
        message = forced ? "Moved with --force while agents of #{main} were busy: #{list}." : "Agents of #{main} are busy: #{list}; promote would refuse unless they finish or --force is given."
        {"code" => AGENT_WORKING, "message" => message, "panes" => busy}
      end

      def preview(root, branch, main_notes, carry_notes, warnings)
        planned = @checkout_move.plan(root, branch, notes_dir: main_notes)
        moved = planned["moved"]
        project = project_name(root)
        workspace = moved["branch"] && @project_config.worktree_config_name(project, File.basename(planned["path"]))
        to = File.join(planned["path"] || File.join(root, ".worktrees", DRY_RUN_NOTES), DRY_RUN_NOTES)
        notes, carry_warnings = carry(main_notes, to, nil, carry_notes, dry_run: true)
        doc = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "dry_run" => true, "branch_required" => planned["branch_required"],
               "project" => project, "workspace" => workspace, "path" => planned["path"], "branch" => moved["branch"], "launched" => false,
               "moved" => moved, "notes" => notes, "next" => [],
               "warnings" => warnings + planned["warnings"] + locks_warning(root) + carry_warnings}
        {exit_code: 0, json: doc}
      end

      def promote(root, branch, main_notes, warnings, title:, spine:, plan:, carry_notes:, launch:, prompt:, headless:, agent_kind:)
        done = @checkout_move.call(root, branch, notes_dir: main_notes)
        moved = done["moved"]
        warnings += done["warnings"] + locks_warning(root)
        started = start_workspace(moved, title: title, headless: headless, agent_kind: agent_kind)
        workspace = started["workspace"]
        warnings += Array(started.delete("warnings")).map { |w| w.is_a?(Hash) ? w : {"code" => "start_note", "message" => w.to_s} }
        notes, carry_warnings = carry(main_notes, started["notes_dir"], workspace, carry_notes, dry_run: false)
        warnings += carry_warnings
        spine_result = make_spine(workspace, spine, notes, warnings)
        plan_result = make_plan(workspace, plan, notes, warnings)
        record(started, moved, notes)
        doc = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "dry_run" => false, "branch_required" => false}
          .merge(started.except("schema_version", "ok", "spine", "plan"))
        doc["spine"] = spine_result if spine_result
        doc["plan"] = plan_result if plan_result
        exit_code = 0
        if launch
          launched = run_launch(workspace, started["notes_dir"], launch, prompt, warnings)
          doc["launched"] = launched[:started]
          doc["packs"] = launched[:packs] if launched[:packs]
          exit_code = 1 unless launched[:ok]
        end
        doc.merge!("moved" => moved, "notes" => notes, "next" => next_steps(doc, started["notes_dir"]), "warnings" => warnings)
        {exit_code: exit_code, json: doc}
      end

      # `start` with no launch, no plan and no spine, so nothing is written to the notes directory before the carry.
      def start_workspace(moved, title:, headless:, agent_kind:)
        options = {no_launch: true, spine: false, promoted: true, root: moved["main"]["path"], yes: true, headless: headless}
        options[:title] = title if title
        options[:agent_kind] = agent_kind if agent_kind
        @start.payload(moved["branch"], **options).fetch(:json)
      rescue Workspace::Error, SystemCallError => e
        command = "workspace start #{Shellwords.escape(moved["branch"])}"
        details = ((e.respond_to?(:details) && e.details) || {}).merge("moved" => moved, "next" => [command])
        raise Workspace::Error.new("The work moved to #{moved["branch"]}, but making it a workspace failed: #{e.message} Run `#{command}` in #{moved["main"]["path"]} to finish.",
          code: (e.respond_to?(:code) && e.code) || "error", details: details, retry_with: (e.retry if e.respond_to?(:retry)))
      end

      # @return [Array(Hash, Array<Hash>)] `notes` (`plan`, `spine`, `carried`) and the warnings
      def carry(from, to, workspace, carry_notes, dry_run:)
        nothing = {"plan" => "none", "spine" => "none", "carried" => carry_notes.uniq.map { |path| {"path" => path, "outcome" => "missing"} }}
        unless from && to
          return [nothing, from ? [notes_unavailable("the new workspace has no notes directory; the plan and spine stay in #{from}")] : []]
        end
        answer = @notes_carry.call(from: from, to: to, name: workspace, carry_notes: carry_notes, dry_run: dry_run)
        [answer.slice("plan", "spine", "carried"), answer["warnings"]]
      rescue Workspace::Error, SystemCallError => e
        [nothing.merge("plan" => "skipped", "spine" => "skipped"),
          [notes_unavailable("carrying the notes failed (#{e.message}); what was not moved stays in #{from}")]]
      end

      def make_spine(workspace, flag, notes, warnings)
        # Only where there was no spine to carry: a skipped one is still in the main checkout, and a fresh one would hide it.
        return nil if flag == false || notes["spine"] != "none" || !@spine_init
        return nil unless flag || @spine_config&.auto?(workspace)
        template = flag if flag.is_a?(String)
        answer = @spine_init.call(name: workspace, template: template, print: false)
        {"outcome" => answer["outcome"], "template" => answer["template"]}
      rescue Workspace::Error, SystemCallError => e
        warnings << {"code" => "spine_init_failed", "message" => "Could not set up the spine: #{e.message}"}
        {"outcome" => "failed", "error" => (e.respond_to?(:code) ? e.code : nil)}.compact
      end

      def make_plan(workspace, flag, notes, warnings)
        return nil if !flag || notes["plan"] != "none" || !@plan_command
        title = flag if flag.is_a?(String)
        begin
          path = @plan_command.init(name: workspace, title: title, print: false)["path"]
          outcome = "created"
        rescue Workspace::Error => e
          raise unless e.code == "plan_exists"
          path = e.details["path"]
          outcome = "exists"
        end
        {"path" => path, "outcome" => outcome, "title" => PlanFile.read(path)&.title}.compact
      rescue Workspace::Error, SystemCallError => e
        warnings << {"code" => "plan_init_failed", "message" => "Could not make the plan: #{e.message} Run `workspace plan init --name #{workspace}`."}
        {"path" => nil, "outcome" => "failed"}
      end

      def locks_warning(root)
        held = @locks.call(root)
        names = held[:names]
        return [] if names.empty?
        message = if held[:own]
          "Locks you hold in this repository were not released: #{names.join(", ")} (workspace lock status)."
        else
          "Locks are held in this repository, perhaps by other sessions (promote could not tell which are yours): #{names.join(", ")} (workspace lock status)."
        end
        [{"code" => "locks_held", "message" => message, "locks" => names, "own" => held[:own]}]
      rescue Workspace::Error, SystemCallError
        []
      end

      # Names only, never paths.
      def record(started, moved, notes)
        @event_log&.record(type: "workspace_promoted", project: started["workspace"], data: {
          "workspace" => started["workspace"], "parent" => started["project"], "branch" => moved["branch"],
          "from_branch" => moved["from_branch"], "branch_created" => moved["branch_created"], "snapshot" => moved.dig("snapshot", "id"),
          "notes" => {"plan" => notes["plan"], "spine" => notes["spine"], "carried" => notes["carried"].count { |row| row["outcome"] == "copied" }}
        })
      end

      # With a plan in the new notes directory, `plan start` (its play and line, the owner pane); else a plain launch.
      # @return [Hash] `{ok:, started:, packs:}`
      def run_launch(workspace, notes_dir, launch, prompt, warnings)
        last = nil
        plan = notes_dir && PlanFile.read(PlanFile.path_in(notes_dir))
        if @plan_dispatch && plan
          launcher = lambda do |ws, line = PlanDispatch::CONTINUE_PROMPT|
            last = launch.call(ws, prompt: [line, prompt].compact.join("\n\n"), play: PlanDispatch::PLAY)
          end
          begin
            @plan_dispatch.start(name: workspace, launch: launcher)
          rescue Workspace::Error => e
            raise unless e.code == "plan_done" && last.nil?
          end
        end
        last ||= launch.call(workspace, prompt: prompt, play: nil)
        warnings << {"code" => "launch_failed", "message" => "The workspace is made, but its agent did not get the first prompt: #{last[:message]}"} unless last[:ok]
        {ok: last[:ok], started: last[:started], packs: last[:packs]}
      rescue Workspace::Error => e
        warnings << {"code" => "launch_failed", "message" => "The workspace is made, but launching it failed: #{e.message} Run `workspace launch #{workspace}`."}
        {ok: false, started: last ? last[:started] : false, packs: last && last[:packs]}
      end

      def next_steps(doc, notes_dir)
        return [] if doc["launched"]
        plan = notes_dir && PlanFile.read(PlanFile.path_in(notes_dir))
        name = Shellwords.escape(doc["workspace"])
        [(plan && !plan.tasks.empty?) ? "workspace plan start --name #{name}" : "workspace launch #{name}"]
      end

      def summarize(doc)
        moved = doc["moved"]
        counts = %w[staged unstaged untracked].map { |kind| "#{moved["#{kind}_count"]} #{kind}" }.join(", ")
        if doc["dry_run"]
          target = doc["branch_required"] ? "a new branch (name one: workspace promote BRANCH)" : "#{doc["branch"]} at #{doc["path"]}"
          @output.puts "Would move #{counts} file(s) and #{moved["commits_ahead"]} commit(s) from #{moved["from_branch"]} to #{target}."
          @output.puts "Main would end on #{moved["main"]["branch"]}. Notes: plan #{doc["notes"]["plan"]}, spine #{doc["notes"]["spine"]}."
        else
          @output.puts "Moved #{counts} file(s) and #{moved["commits_ahead"]} commit(s) from #{moved["from_branch"]} to #{doc["branch"]} at #{doc["path"]}."
          @output.puts "Workspace #{doc["workspace"]} is ready#{"; notes at #{doc["notes_dir"]}" if doc["notes_dir"]}. Notes: plan #{doc["notes"]["plan"]}, spine #{doc["notes"]["spine"]}."
          @output.puts "Main is on #{moved["main"]["branch"]}#{" and clean" if moved["main"]["clean"]}."
        end
        doc["notes"]["carried"].each { |row| @output.puts "  #{row["path"]}: #{row["outcome"]}" }
        doc["warnings"].each { |warning| @error_output.puts "Warning: #{warning["message"]}" }
        doc["next"].each { |command| @output.puts "Next: #{command}" }
      end
    end
  end
end
