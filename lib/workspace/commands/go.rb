module Workspace
  module Commands
    # `go`: the shortest way to start a workflow. Reads the argument, picks the workflow, says
    # which and why, then calls `workflow run` in this checkout or {WorkflowStart} for a
    # worktree workspace. It adds its own refusals about branches and leaves {WorkflowStart}'s
    # checks where they are: every ref goes through {WorkflowStart#call}, so `fork_pull_request`
    # holds whichever way the ref ends up running.
    #
    # Free text always makes a new worktree workspace off the default branch, even from inside a
    # linked worktree workspace; `--here` runs it in this checkout instead. A sentence that
    # names exactly one pull request, issue or ticket (a link, else a bare JIRA key whose ticket
    # reads) is that ref with the sentence as its prompt, checked like a ref typed alone; two,
    # none, or a ticket that can't be read keep it free text, with a warning when it matters.
    # With `--here` or `--text` nothing is extracted. Bare `go` and a ref for the current
    # branch run in place without `--here`. In place means only a linked worktree
    # that is the detected workspace, off the default branch ({#checkout_here}); `go` never puts
    # a run on the default branch or the main checkout's branch.
    #
    # `--here` with free text while a run is already going on the checkout adds the text to the
    # plan as a task instead ({GoTask}), and types nothing.
    class Go
      # The workflow when neither `--workflow` nor config names one.
      BUILT_IN = {"github_pr" => "pr-feedback"}.freeze
      BUILT_IN_OTHERWISE = "rpiv"

      # How a failed branch pick reads in the warning.
      PICK_REASONS = {no_agent: "no agent to ask", timeout: "timed out", output_too_large: "output too large", failed: "the call failed", empty: "no usable name"}.freeze

      # What the argument was read as.
      #
      # @!attribute kind [String] the kind the workflow is chosen for: a {StartRef::Ref} kind, or "prompt"
      # @!attribute text [String, nil] the free text; set with +ref+ when a ref was read out of it
      # @!attribute ref [Workspace::StartRef::Ref, nil] the ref typed alone or read out of the text; both it and +text+ are nil for no argument
      # @!attribute extracted [String, nil] the token read out of the text (a canonical URL or an uppercase key); nil otherwise
      # @!attribute warnings [Array<String>] why a sentence stayed free text, or which mention was dropped
      Reading = Struct.new(:kind, :text, :ref, :extracted, :warnings, keyword_init: true) do
        def initialize(warnings: [], **rest)
          super
        end
      end

      # @param workflow_start [Workspace::Commands::WorkflowStart]
      # @param workflow [Workspace::Commands::Workflow]
      # @param workflow_defaults [Workspace::WorkflowDefaults]
      # @param catalog [Workspace::WorkflowCatalog]
      # @param start_ref [Workspace::StartRef]
      # @param git [Workspace::Git]
      # @param project_detector [Workspace::ProjectDetector]
      # @param project_config [Workspace::ProjectConfig]
      # @param go_task [Workspace::Commands::GoTask] adds `--here` text to the plan of a run already going
      # @param ticket_source [Workspace::TicketSource] reads a bare key found in text, to know it is a ticket
      # @param protected_branch [Workspace::ProtectedBranch]
      # @param branch_name_picker [Workspace::BranchNamePicker] names the branch for free text that starts a new workspace
      # @param output [IO]
      # @param working_dir [String] the directory the command runs in
      def initialize(workflow_start:, workflow:, workflow_defaults:, catalog:, start_ref:, git:, project_detector:, project_config:, go_task:, ticket_source:, protected_branch:, branch_name_picker:, output: $stdout, working_dir: Dir.pwd)
        @workflow_start = workflow_start
        @workflow = workflow
        @workflow_defaults = workflow_defaults
        @catalog = catalog
        @start_ref = start_ref
        @git = git
        @project_detector = project_detector
        @project_config = project_config
        @go_task = go_task
        @ticket_source = ticket_source
        @protected_branch = protected_branch
        @branch_name_picker = branch_name_picker
        @output = output
        @working_dir = working_dir
      end

      # @param argument [String, nil] a ticket, pull request, issue or branch; a sentence (any whitespace inside it) that is free text, or holds one pull request, issue or ticket that is then the ref; nil for none
      # @param workflow [String, nil] the workflow, from `--workflow`
      # @param inputs [Hash{String=>String}] values from `--input`
      # @param headless [Boolean]
      # @param dry_run [Boolean] check everything and create nothing
      # @param caller_pane [String, nil] the pane the command runs in (`$TMUX_PANE`)
      # @param here [Boolean] run free text in this checkout (`--here`) instead of a new workspace
      # @param base [String, nil] the ref a new branch starts from (`--base`); refused when go runs in place
      # @param text [Boolean] read the argument as plain text (`--text`): no identifier is taken out of it
      # @return [Hash{String=>Object}] the row of `workflow run` or `workflow start` (of `plan task add` on the task path, route `task`), plus "decision" (+workflow+, +source+,
      #   +kind+, +route+, +reason+, +extracted+: the token read out of the text, else nil) and "warnings"
      # @raise [Workspace::UsageError] an empty argument, no argument where `go` can't run in place, `--here` with a ref for another branch, or free text with no letters or digits for a new branch, or `--text` with no argument or one holding no whitespace
      # @raise [Workspace::Error] outside a git repository; code `go_here_unavailable` (`--here` where this checkout can't run in place), `unknown_ref`, `unknown_base`, `branch_not_allowed`, `branch_exists`, `workflow_needs_claude`, or any of {WorkflowStart#call} and {Workflow#run}
      def call(argument: nil, workflow: nil, inputs: {}, headless: false, dry_run: false, caller_pane: nil, here: false, base: nil, text: false)
        argument = argument&.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
        raise Workspace::UsageError, "go was given an empty argument. Name a ref, or quote free text." if argument == ""
        if text && (argument.nil? || !argument.match?(/[[:space:]]/))
          raise Workspace::UsageError, argument ? "--text needs a quoted sentence with a space in it (got #{argument.inspect}). Quote the sentence, or drop --text." : "--text needs a quoted sentence; none was given."
        end

        root = @git.root
        project = root && @start_ref.project(root)
        checkout = checkout_here(root, project, caller_pane)
        if argument.nil? && checkout.nil? && !here
          raise Workspace::UsageError, "go needs a ref or free text here: it runs in place only in a linked worktree workspace off the default branch."
        end
        raise Workspace::Error, "go must run inside a git repository." unless root
        if here && checkout.nil?
          raise Workspace::Error.new("--here runs go in place, and that works only in a linked worktree workspace off the default branch. This directory is not one, so nothing was started. Drop --here to make a new worktree workspace.",
            code: "go_here_unavailable", details: {"path" => root})
        end

        reading = classify(argument, root, workflow, here || text)
        if reading.ref
          naming(reading.extracted) do
            refuse_protected!(reading.ref.branch, project)
            refuse_other_branch!(reading.ref.branch, project)
          end
        end

        same_branch = reading.ref && checkout && @protected_branch.same?(reading.ref.branch, @git.worktree_branch(root), project)
        if here && reading.ref && !same_branch
          raise Workspace::UsageError, "--here runs in this checkout, and #{reading.ref.input} is another branch. Drop --here to make or reuse its worktree workspace."
        end
        in_place = checkout && (reading.ref ? same_branch : (reading.text.nil? || here))
        if reading.text && here && (run = @go_task.run_for(checkout))
          return @go_task.add(run, reading.text, checkout, flags: {workflow: workflow, inputs: inputs, base: base}, dry_run: dry_run)
        end
        check_base!(base, root, in_place)
        # In place the worktree is known, so its own setting counts; a new checkout has none yet.
        project_workspace = @workflow_start.locate_project[:project_workspace]
        # A project's keys count only where the user's config ties it to this checkout, as for `workflow start`.
        tied = @workflow_start.catalog_project
        id, source, definition = choose(workflow, reading.kind, tied && (in_place ? checkout.workspace : tied), tied)
        # Only free text that starts a new workspace asks for a name, and only once every cheap
        # refusal has had its say: the slug of the text is checked first, so text that could never
        # name a branch never pays the namer's latency.
        derived_branch, pick_warnings = nil, []
        if reading.text && !reading.ref && !in_place
          @workflow_start.check_agent_kind!(nil, project_workspace: project_workspace)
          refuse_slug!(StartRef.slug(reading.text), project)
          derived_branch, pick_warnings = pick_branch(reading.text, project, project_workspace, root)
          refuse_slug!(derived_branch || StartRef.slug(reading.text), project)
        end
        route = in_place ? "run" : "start"
        reason = reason_for(source, reading.kind)
        warnings = reading.warnings + unused_text_warnings(reading, definition, inputs, id, route)
        @output.puts "go: #{id} (#{reason}), #{route_words(route, reading)}."
        warnings.each { |warning| @output.puts "Warning: #{warning}" }

        shared = {id: id, inputs: inputs, dry_run: dry_run}
        shared[:base] = base if base
        shared[:prompt] = reading.text if reading.ref && reading.text
        row = if reading.ref
          naming(reading.extracted) { @workflow_start.call(ref: reading.ref.input, headless: headless, here: in_place ? checkout : nil, **shared) }
        elsif in_place
          run_here(reading.text, definition, checkout, project_workspace, **shared)
        else
          start_from_text(reading.text, project, definition, headless: headless, derived_branch: derived_branch, **shared)
        end
        decision = {"workflow" => id, "source" => source, "kind" => reading.kind, "route" => route, "reason" => reason, "extracted" => reading.extracted}
        row.merge("decision" => decision, "warnings" => Array(row["warnings"]) + warnings + pick_warnings)
      end

      private

      # A run in place starts from where the checkout is, so a base would be ignored. A value
      # starting with `-` would be read by git as an option, so it is refused before any lookup.
      # The value is read in the checkout go runs in, because `git worktree add` runs there too.
      def check_base!(base, root, in_place)
        return unless base

        raise Workspace::UsageError, "--base would be ignored: go runs in this checkout, which starts from where it is now. Drop --base, or drop --here to make a new workspace." if in_place

        return if !base.start_with?("-") && @git.commit_exists?(root, base)

        raise Workspace::Error.new("--base #{base.inspect} is not a branch, tag or commit of this repository, so nothing was started. A branch on origin may need `git fetch`.",
          code: "unknown_base", details: {"base" => base})
      end

      # The one test for running in place and the one source of the checkout. The detected
      # workspace must be this very checkout, a linked worktree on a branch other than the
      # default: a main checkout, a linked worktree with no marker of its own (which detects as
      # the main workspace), a detached HEAD and a rebase in progress all answer nil.
      def checkout_here(root, project, caller_pane)
        return nil unless project&.from_worktree

        workspace = @project_detector.detect(@working_dir)
        return nil unless workspace

        configured = @project_config.project_root_for(workspace)
        return nil unless configured && File.realpath(File.expand_path(configured)) == File.realpath(root)

        branch = @git.worktree_branch(root)
        return nil if branch.nil? || @protected_branch.call(branch, project)

        WorkflowStart::Here.new(workspace: workspace, path: root, caller_pane: caller_pane)
      rescue SystemCallError
        nil
      end

      # A refusal of a ref read out of a sentence names the way out. The refusal is a copy of the
      # same error (class, code, details, retry and any attributes kept) with the sentence added to its
      # message. One that already names a next command is left alone: the workspace exists, and --text
      # would make a second. A nil token (a ref the person typed) changes nothing.
      def naming(token)
        yield
      rescue Workspace::Error => e
        raise if token.nil? || (e.details.is_a?(Hash) && e.details["next"])

        message = "#{e.message} The text contains #{token}, which go read as a ref. Pass --text to treat the whole text as plain text."
        copy = e.dup
        copy.define_singleton_method(:to_s) { message }
        raise copy
      end

      # The whitespace test comes first, so a lone word is never read as a sentence. A sentence
      # is read for an identifier unless `--here` or `--text` says it is the task as written.
      def classify(argument, root, workflow, here)
        return Reading.new(kind: "prompt") if argument.nil?
        return read_text(argument, root, workflow) if argument.match?(/[[:space:]]/) && !here
        return Reading.new(kind: "prompt", text: argument) if argument.match?(/[[:space:]]/)

        ref = @start_ref.call(argument, root: root)
        ref = ticket_for_word(argument, ref, root, workflow) || ref
        check_name!(ref, root, workflow)
        Reading.new(kind: ref.kind, ref: ref)
      end

      # A lone lowercase key is a ticket only once its ticket is found, so an input refused today
      # stays refused: an exact branch of that name, a name for a workflow and any miss leave the word as it was.
      def ticket_for_word(word, ref, root, workflow)
        return nil unless ref.kind == "branch" && workflow.nil?
        return nil if @git.branch_names(root).include?(word)

        key = RefInText.word_key(word) or return nil
        ticket = @start_ref.call(key, root: root)
        begin
          @ticket_source.fetch(ticket, chdir: root)
        rescue Workspace::Error => e
          raise unless %w[ticket_not_found ticket_source_unavailable].include?(e.code)

          failed = e.code == "ticket_source_unavailable" && e.details["reason"] != "missing"
          @output.puts "Warning: #{key} could not be read as a ticket: #{TerminalText.escape(e.message)}" if failed
          return nil
        end
        ticket
      end

      # Looks for the one pull request, issue or ticket a sentence names. A mention of another
      # repository is dropped; links beat bare keys; more than one identifier, or none, is free
      # text. A link is proof enough, a bare key needs its ticket to read.
      def read_text(text, root, workflow)
        warnings = []
        found = RefInText.scan(text).reject do |hit|
          next false if hit.repo.nil? || @workflow_start.tracks_repository?(root, hit.repo)

          warnings << "#{hit.token} is a repository this project does not track, so it is read as a mention."
          true
        end
        links = found.select(&:link)
        found = links unless links.empty?
        if found.size > 1
          warnings << "The text names #{found.map(&:token).join(" and ")}, so it is read as free text. To use one, run `workspace go ID --input task=TEXT`."
          return Reading.new(kind: "prompt", text: text, warnings: warnings)
        end
        return Reading.new(kind: "prompt", text: text, warnings: warnings) if found.empty?

        hit = found.first
        ref = @start_ref.call(hit.token, root: root)
        unless hit.link
          begin
            @ticket_source.fetch(ref, chdir: root)
          rescue Workspace::Error => e
            raise unless %w[ticket_not_found ticket_source_unavailable].include?(e.code)

            warnings << "#{hit.token} in the text was not read as a ticket, so the text is free text: #{TerminalText.escape(e.message)}"
            return Reading.new(kind: "prompt", text: text, warnings: warnings)
          end
        end
        naming(hit.token) { check_name!(ref, root, workflow) }
        Reading.new(kind: ref.kind, text: text, ref: ref, extracted: hit.token, warnings: warnings)
      end

      # `Git#branch_exists?` asks the filesystem, where on macOS `MAIN` opens `main`, so names are
      # looked up exactly. The branch a ticket or pull request names counts too: `PR-12` would open
      # `pr-12` and pass the fork check under a name git config knows nothing of. Local names decide
      # first, because `git worktree add` opens a local branch that differs only in case from an
      # origin name. A ticket with no such branch stays a ticket. `origin/main` is no branch either:
      # `start` would make a local branch of that name.
      def check_name!(ref, root, workflow)
        match = case_clash(ref.branch, root)
        refuse_case_variant(ref, match, workflow) if match
        return unless ref.kind == "branch"

        names = @git.branch_names(root)
        return if names.include?(ref.branch)

        remote = case_variant(names, ref.branch.delete_prefix("origin/")) if ref.branch.start_with?("origin/")
        refuse_remote_name(ref, remote) if remote
        refuse_unknown_word(ref) unless workflow
      end

      # The real branch this name differs from only in case, local names first; nil for an exact name or no match.
      def case_clash(branch, root)
        locals = @git.local_branch_names(root)
        return nil if locals.include?(branch)

        match = case_variant(locals, branch)
        return match if match

        names = @git.branch_names(root)
        names.include?(branch) ? nil : case_variant(names, branch)
      end

      def case_variant(names, branch)
        names.find { |name| name.casecmp?(branch) }
      end

      def refuse_case_variant(ref, match, workflow)
        message = if ref.kind == "branch"
          advice = workflow ? "Free text needs a space." : "A word naming a workflow needs --workflow, and free text needs a space."
          "#{ref.input.inspect} differs only in case from the branch #{match}. Use that name. #{advice}"
        else
          "#{ref.input} names the branch #{ref.branch}, which differs only in case from the branch #{match}."
        end
        raise_unknown_ref(message, ref, "did_you_mean" => match)
      end

      def refuse_remote_name(ref, match)
        raise_unknown_ref("#{ref.input} is origin's name for the branch #{match}. Use #{match}.", ref, "did_you_mean" => match)
      end

      def refuse_unknown_word(ref)
        raise_unknown_ref("#{ref.input.inspect} is not a branch of this repository. A word naming a workflow needs --workflow, " \
          "free text needs a space, and a branch on origin may need `git fetch`.", ref)
      end

      def raise_unknown_ref(message, ref, extra = {})
        raise Workspace::Error.new(message, code: "unknown_ref", details: {"ref" => ref.input, "known" => @catalog.known_ids(project: @workflow_start.catalog_project)}.merge(extra))
      end

      # `start` would adopt the main checkout, or put the run on the default branch in a worktree.
      def refuse_protected!(branch, project, advice: "Name a new branch, or use free text.")
        protection = protection_of(branch, project) or return

        raise Workspace::Error.new("go does not run on #{protection[:branch]} (#{protection[:reason].tr("_", " ")})#{" at #{protection[:path]}" if protection[:path]}. #{advice}",
          code: "branch_not_allowed", details: {"branch" => protection[:branch], "path" => protection[:path], "reason" => protection[:reason]})
      end

      # `start` and `WorkflowStart#plan` reuse this checkout whatever it holds now, so the fork
      # check would have read the ref's branch and the run land on another (or on a detached HEAD).
      def refuse_other_branch!(branch, project)
        path, held = other_checkout(branch, project)
        return unless path

        raise Workspace::Error.new("The checkout at #{path} holds #{held || "no branch"}, not #{branch}. Switch it back, or name another ref.",
          code: "branch_exists", details: {"branch" => branch, "path" => path, "worktree" => true, "held" => held})
      end

      # @return [Array, nil] the path and what it holds, when the reused checkout holds anything but the branch
      def other_checkout(branch, project)
        path = reused_checkout(branch, project) or return
        held = @git.worktree_branch(path)
        # Exact on purpose: the fork check reads the name given, so even a symref to what the checkout holds is another branch.
        [path, held] unless held == branch
      end

      # The branch's own protection, else that of what the checkout `start` would reuse holds,
      # because `WorkflowStart#plan` trusts that path.
      def protection_of(branch, project)
        own = @protected_branch.call(branch, project)
        return own.merge(branch: branch) if own

        path = reused_checkout(branch, project) or return
        held = @git.worktree_branch(path)
        reused = @protected_branch.call(held, project)
        reused&.merge(branch: held, path: path)
      end

      # `.worktrees/<sanitized>` when it is a worktree, the first place `plan` and `start` look.
      # A branch checked out anywhere else is adopted at its own path, holding that branch.
      def reused_checkout(branch, project)
        path = worktree_path(branch, project)
        path if @git.worktree_exists?(path)
      end

      def worktree_path(branch, project)
        File.join(project.root, ".worktrees", @git.sanitize_for_filesystem(branch))
      end

      # Asks the branch namer for a name and answers it with the warnings a failed pick earns.
      #
      # @return [Array(String, nil, Array<String>)] the agent's pick (nil: the slug of the text is used) and the
      #   warnings for a pick that failed; those are also printed
      def pick_branch(text, project, project_workspace, root)
        picked = @branch_name_picker.call(text: text, project: project_workspace, root: root)
        return [picked.name, []] if picked.ok?
        return [nil, []] if picked.reason == :disabled

        fallback = StartRef.slug(text)

        message = "The branch namer failed (#{PICK_REASONS.fetch(picked.reason, picked.reason)}); using #{TerminalText.escape(fallback)} from the text instead."
        Warn.puts(@output, "Warning: #{message}")
        [nil, [message]]
      end

      # Free text never passes through a ref's checks, and `WorkflowStart` asks the filesystem,
      # which sees nothing of a packed branch, so the new branch could be a case alias of one.
      def refuse_slug!(slug, project)
        raise Workspace::UsageError, "The text has no letters or digits to name a branch from. Run `workspace workflow start ID --prompt TEXT --branch NAME`." if slug.empty?

        refuse_protected!(slug, project, advice: "Reword the text.")
        match = case_clash(slug, project.root) or return

        path = worktree_path(match, project)
        raise Workspace::Error.new("The text makes the branch name #{slug}, which differs only in case from the branch #{match}. Reword the text.",
          code: "branch_exists", details: {"branch" => match, "path" => path, "worktree" => @git.worktree_exists?(path)})
      end

      # @return [Array] the id, its source and the definition; `Catalog#find` refuses before anything prints
      def choose(flag, kind, workspace, tied)
        found = @workflow_defaults.lookup(kind, workspace: workspace, project: tied) unless flag
        id = flag || found&.fetch(:id) || BUILT_IN.fetch(kind, BUILT_IN_OTHERWISE)
        source = flag ? "flag" : found&.fetch(:key) || "built_in"
        [id, source, @catalog.find(id, project: tied)]
      end

      def reason_for(source, kind)
        case source
        when "flag" then "named with --workflow"
        when "built_in" then "built in for #{kind}"
        else "set by #{source}"
        end
      end

      def route_words(route, reading)
        return "runs in this worktree#{" (from #{reading.extracted} in the text)" if reading.extracted}" if route == "run"

        words = reading.ref ? "makes or reuses the worktree workspace for #{reading.ref.branch}" : "makes a new worktree workspace"
        reading.extracted ? "#{words} (from #{reading.extracted} in the text)" : words
      end

      def unused_text_warnings(reading, definition, inputs, id, route)
        return [] unless reading.text

        why = if inputs.key?("task")
          "--input task was given"
        elsif !declares_task?(definition)
          "#{id} declares no task input"
        end
        return [] unless why

        ["The text is not the task: #{why}.#{" The text still names the new branch." if route == "start" && !reading.ref}"]
      end

      def declares_task?(definition)
        definition.to_h["inputs"].key?("task")
      end

      def run_here(text, definition, here, project_workspace, id:, inputs:, dry_run:)
        @workflow_start.check_agent!(here.workspace, project: project_workspace)
        inputs = inputs.merge("task" => text) if text && declares_task?(definition) && !inputs.key?("task")
        @workflow.run(id: id, workspace: here.workspace, worktree: here.path, inputs: inputs, dry_run: dry_run, caller_pane: here.caller_pane, project: @workflow_start.catalog_project)
      end

      def start_from_text(text, project, definition, derived_branch: nil, **options)
        @workflow_start.call(prompt: text, derived_branch: derived_branch, **options)
      rescue Workspace::Error => e
        raise unless e.code == "branch_exists"

        raise Workspace::Error.new(existing_message(e.details, project, options[:id], definition), code: e.code, details: e.details, retry_with: e.retry)
      end

      # `go BRANCH` only helps when that command would work: not when the checkout for it holds
      # another branch, and not when no branch has that name, where it would be `unknown_ref`.
      def existing_message(details, project, id, definition)
        name, path = details.values_at("branch", "path")
        if (other = other_checkout(name, project))
          "The text makes the branch name #{name}, but the checkout at #{other[0]} holds #{other[1] || "no branch"}. Reword the text."
        elsif @git.branch_names(project.root).include?(name)
          "The text makes the branch name #{name}, which already exists. To work on it, run `#{go_command(name, id, definition)}`; for a new branch, reword the text."
        else
          "The text makes the branch name #{name}, but #{path} is already there with no such branch. Reword the text, or move that path."
        end
      end

      def go_command(name, id, definition)
        parts = ["workspace go", name, "--workflow", id]
        parts.push("--input", "task=TEXT") if declares_task?(definition)
        parts.join(" ")
      end
    end
  end
end
